import AVFoundation
import Foundation
import os

nonisolated
enum SoundPackLoadError: Error, LocalizedError {
    case manifestMissing
    case manifestInvalid(String)
    case audioMissing(String)
    case decodeFailed(String)
    case notAPackFolder
    case importCopyFailed(String)
    case unsupportedOggAudio(Int)

    var errorDescription: String? {
        switch self {
        case .manifestMissing: "No manifest.json or config.json was found in the pack folder."
        case .manifestInvalid(let s): "Manifest invalid: \(s)"
        case .audioMissing(let s): "Audio file missing: \(s)"
        case .decodeFailed(let s): "Audio decode failed: \(s)"
        case .notAPackFolder: "Not a sound pack folder — expected a folder containing manifest.json or config.json."
        case .importCopyFailed(let s): "Could not copy the pack into the packs folder: \(s)"
        case .unsupportedOggAudio(let count):
            "The pack references \(count) Ogg Vorbis (.ogg) sound \(count == 1 ? "file" : "files"), which macOS cannot decode. Convert the sounds to wav or mp3 (for example with ffmpeg), then import again."
        }
    }
}

/// Discovers packs in the bundled resources directory and in the user pack
/// directory, then loads any of them into an in-memory `SoundPack` with
/// pre-decoded PCM buffers.
actor SoundPackLoader {
    private static let log = Logger(subsystem: "brandon.Click", category: "loader")

    /// Where user-installed packs live. Created on first access.
    nonisolated static var userPacksDirectory: URL {
        let fm = FileManager.default
        let base = try? fm.url(for: .applicationSupportDirectory,
                               in: .userDomainMask,
                               appropriateFor: nil,
                               create: true)
        let url = (base ?? fm.temporaryDirectory)
            .appendingPathComponent("Click", isDirectory: true)
            .appendingPathComponent("SoundPacks", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Built-in packs shipped inside the app bundle.
    private nonisolated static var bundledPacksDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("DefaultPacks", isDirectory: true)
    }

    /// Lists every pack on disk (bundled + user). Bundled packs win on name
    /// collisions so the user always has a fallback if their copy is broken.
    func discover() -> [PackHandle] {
        var seen: Set<String> = []
        var out: [PackHandle] = []
        for url in scanRoots() {
            for handle in handles(in: url) where !seen.contains(handle.name) {
                seen.insert(handle.name)
                out.append(handle)
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private nonisolated func scanRoots() -> [URL] {
        var roots: [URL] = []
        if let b = Self.bundledPacksDirectory { roots.append(b) }
        roots.append(Self.userPacksDirectory)
        return roots
    }

    private nonisolated func handles(in root: URL) -> [PackHandle] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries.compactMap { entry in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return makeHandle(at: entry)
        }
    }

    private nonisolated func makeHandle(at folder: URL) -> PackHandle? {
        let fm = FileManager.default
        let manifest = folder.appendingPathComponent("manifest.json")
        if fm.fileExists(atPath: manifest.path) {
            if let m: ClickPackManifest = try? JSONDecoder().decode(ClickPackManifest.self,
                                                                   from: Data(contentsOf: manifest)) {
                return PackHandle(id: folder.path, name: m.name, author: m.author,
                                  url: folder, kind: .clickpack)
            }
        }
        let config = folder.appendingPathComponent("config.json")
        if fm.fileExists(atPath: config.path),
           let kind = MechvibesAdapter.classify(folder: folder),
           let m = try? MechvibesAdapter.previewManifest(folder: folder) {
            let display = m.name ?? folder.deletingPathExtension().lastPathComponent
            return PackHandle(id: folder.path, name: display, author: nil, url: folder, kind: kind)
        }
        return nil
    }

    /// Loads a single pack into memory, pre-decoding every referenced sample.
    func load(handle: PackHandle) throws -> SoundPack {
        switch handle.kind {
        case .clickpack:
            return try loadClickPack(at: handle.url)
        case .mechvibesMulti, .mechvibesSingle:
            return try MechvibesAdapter.load(folder: handle.url, kind: handle.kind)
        }
    }

    private func loadClickPack(at folder: URL) throws -> SoundPack {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw SoundPackLoadError.manifestMissing
        }
        let manifest: ClickPackManifest
        do {
            manifest = try JSONDecoder().decode(ClickPackManifest.self, from: data)
        } catch {
            throw SoundPackLoadError.manifestInvalid(error.localizedDescription)
        }

        var samples: [Int64: [AVAudioPCMBuffer]] = [:]
        for (keyString, paths) in manifest.keyMap ?? [:] {
            guard let key = Int64(keyString) else { continue }
            var bucket: [AVAudioPCMBuffer] = []
            for relative in paths {
                let url = try Self.resolveInside(relative, base: folder)
                bucket.append(try Self.decode(url: url))
            }
            if !bucket.isEmpty { samples[key] = bucket }
        }

        var defaults: [AVAudioPCMBuffer] = []
        if let rel = manifest.defaultSound {
            let url = try Self.resolveInside(rel, base: folder)
            defaults.append(try Self.decode(url: url))
        }

        return SoundPack(name: manifest.name,
                         author: manifest.author,
                         kind: .clickpack,
                         samplesByKeyCode: samples,
                         defaultSamples: defaults)
    }

    /// Copies a pack folder (or an exported `.clickpack` bundle) into the user
    /// packs directory. Throws when the source is not a recognized pack or the
    /// copy fails so callers can surface the failure to the user.
    func importPack(at sourceURL: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir), isDir.boolValue else {
            Self.log.warning("Import rejected — not a directory: \(sourceURL.path, privacy: .public)")
            throw SoundPackLoadError.notAPackFolder
        }
        guard let handle = makeHandle(at: sourceURL) else {
            Self.log.warning("Import rejected — no manifest in \(sourceURL.path, privacy: .public)")
            throw SoundPackLoadError.notAPackFolder
        }
        let oggFiles = referencedOggFiles(in: handle)
        guard oggFiles.isEmpty else {
            Self.log.warning("Import rejected — \(oggFiles.count) ogg files referenced by \(sourceURL.path, privacy: .public)")
            throw SoundPackLoadError.unsupportedOggAudio(oggFiles.count)
        }
        let destination = Self.userPacksDirectory
            .appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: sourceURL, to: destination)
            Self.log.notice("Imported pack: \(destination.lastPathComponent, privacy: .public)")
        } catch {
            Self.log.error("Import failed: \(error.localizedDescription, privacy: .public)")
            throw SoundPackLoadError.importCopyFailed(error.localizedDescription)
        }
    }

    /// Sound files referenced by the pack manifest that AVFoundation cannot
    /// decode (Ogg Vorbis). Checked at import time so the user gets a clear
    /// error instead of a pack that plays silence.
    private nonisolated func referencedOggFiles(in handle: PackHandle) -> [String] {
        let referenced: [String]
        switch handle.kind {
        case .clickpack:
            let manifestURL = handle.url.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(ClickPackManifest.self, from: data) else {
                return []
            }
            let mapped = manifest.keyMap?.values.flatMap { $0 } ?? []
            referenced = mapped + [manifest.defaultSound].compactMap { $0 }
        case .mechvibesMulti, .mechvibesSingle:
            referenced = MechvibesAdapter.referencedAudioFiles(folder: handle.url)
        }
        return referenced.filter { $0.lowercased().hasSuffix(".ogg") }
    }

    /// Resolves a pack-relative path and rejects anything that escapes
    /// `base` (e.g. `../../etc/passwd` in a malicious manifest).
    static func resolveInside(_ relative: String, base: URL) throws -> URL {
        let candidate = base.appendingPathComponent(relative).standardizedFileURL
        let basePath = base.standardizedFileURL.path
        let candidatePath = candidate.path
        let escaped = !(candidatePath == basePath
            || candidatePath.hasPrefix(basePath + "/"))
        if escaped {
            throw SoundPackLoadError.manifestInvalid(
                "path escapes pack folder: \(relative)"
            )
        }
        return candidate
    }

    /// Decodes any AVFoundation-supported audio URL into a single PCM buffer
    /// big enough to hold the whole file.
    static func decode(url: URL) throws -> AVAudioPCMBuffer {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw SoundPackLoadError.audioMissing(url.lastPathComponent)
        }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw SoundPackLoadError.decodeFailed(url.lastPathComponent)
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw SoundPackLoadError.decodeFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        return buffer
    }
}
