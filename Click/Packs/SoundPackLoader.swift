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
    case resourceLimitExceeded(String)

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
        case .resourceLimitExceeded(let s): "Sound pack is too large: \(s)"
        }
    }
}

/// Tracks decoded PCM allocation before buffers are created. Limits apply to
/// decoded data (not merely compressed file size), preventing small crafted
/// files from expanding into unbounded memory use.
nonisolated
struct AudioDecodeBudget {
    static let maximumBytesPerBuffer: UInt64 = 128 * 1_024 * 1_024
    static let maximumBytesPerPack: UInt64 = 512 * 1_024 * 1_024

    private(set) var reservedBytes: UInt64 = 0

    mutating func reserve(
        frameCount: AVAudioFramePosition,
        format: AVAudioFormat,
        label: String
    ) throws {
        guard frameCount > 0,
              UInt64(frameCount) <= UInt64(AVAudioFrameCount.max) else {
            throw SoundPackLoadError.resourceLimitExceeded("\(label) has an unsupported frame count")
        }
        let bytesPerFrame = UInt64(format.streamDescription.pointee.mBytesPerFrame)
        let planeCount = format.isInterleaved ? UInt64(1) : UInt64(max(format.channelCount, 1))
        guard bytesPerFrame > 0 else {
            throw SoundPackLoadError.decodeFailed("\(label): invalid PCM format")
        }
        let (bytesPerPlane, frameOverflow) = UInt64(frameCount)
            .multipliedReportingOverflow(by: bytesPerFrame)
        let (decodedBytes, planeOverflow) = bytesPerPlane
            .multipliedReportingOverflow(by: planeCount)
        guard !frameOverflow, !planeOverflow,
              decodedBytes <= Self.maximumBytesPerBuffer else {
            throw SoundPackLoadError.resourceLimitExceeded("\(label) exceeds the 128 MB decoded-audio limit")
        }
        let (newTotal, totalOverflow) = reservedBytes.addingReportingOverflow(decodedBytes)
        guard !totalOverflow, newTotal <= Self.maximumBytesPerPack else {
            throw SoundPackLoadError.resourceLimitExceeded("decoded audio exceeds the 512 MB per-pack limit")
        }
        reservedBytes = newTotal
    }
}

/// Discovers packs in the bundled resources directory and in the user pack
/// directory, then loads any of them into an in-memory `SoundPack` with
/// pre-decoded PCM buffers.
actor SoundPackLoader {
    private static let log = Logger(subsystem: "brandon.Click", category: "loader")
    static let maximumMetadataFileBytes = 1 * 1_024 * 1_024
    static let maximumEncodedAudioFileBytes = 256 * 1_024 * 1_024
    static let maximumImportedFileCount = 2_048
    static let maximumImportedTreeBytes: UInt64 = 512 * 1_024 * 1_024
    static let maximumKeyMapEntries = 512
    static let maximumAudioReferences = 4_096

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
                                                                   from: Self.readMetadataFile("manifest.json", base: folder)),
               (try? Self.validate(manifest: m)) != nil {
                return PackHandle(id: folder.path, name: m.name, author: m.author,
                                  url: folder, kind: .clickpack)
            }
        }
        let config = folder.appendingPathComponent("config.json")
        if fm.fileExists(atPath: config.path),
           let kind = MechvibesAdapter.classify(folder: folder),
           let m = try? MechvibesAdapter.previewManifest(folder: folder) {
            return PackHandle(id: folder.path, name: m.name, author: nil, url: folder, kind: kind)
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
        let data = try Self.readMetadataFile("manifest.json", base: folder)
        let manifest: ClickPackManifest
        do {
            manifest = try JSONDecoder().decode(ClickPackManifest.self, from: data)
        } catch {
            throw SoundPackLoadError.manifestInvalid(error.localizedDescription)
        }
        try Self.validate(manifest: manifest)

        var budget = AudioDecodeBudget()
        var samples: [Int64: [AVAudioPCMBuffer]] = [:]
        for (keyString, paths) in manifest.keyMap ?? [:] {
            guard let key = Int64(keyString) else { continue }
            var bucket: [AVAudioPCMBuffer] = []
            for relative in paths {
                let url = try Self.resolveInside(relative, base: folder)
                bucket.append(try Self.decode(url: url, budget: &budget))
            }
            if !bucket.isEmpty { samples[key] = bucket }
        }

        var defaults: [AVAudioPCMBuffer] = []
        if let rel = manifest.defaultSound {
            let url = try Self.resolveInside(rel, base: folder)
            defaults.append(try Self.decode(url: url, budget: &budget))
        }

        return SoundPack(name: manifest.name,
                         author: manifest.author,
                         kind: .clickpack,
                         samplesByKeyCode: samples,
                         defaultSamples: defaults)
    }

    /// Copies a pack folder (or an exported `.clickpack` bundle) into the user
    /// packs directory. The copy is staged and fully decoded before it replaces
    /// an existing pack, so a bad import can never destroy the user's working
    /// copy. Throws when the source is not a recognized, playable pack or the
    /// copy fails so callers can surface the failure to the user.
    func importPack(at sourceURL: URL) throws {
        let fm = FileManager.default
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            Self.log.warning("Import rejected — source is not a directory")
            throw SoundPackLoadError.notAPackFolder
        }
        try Self.validateImportedTree(at: source)
        guard let handle = makeHandle(at: source) else {
            Self.log.warning("Import rejected — source has no valid manifest")
            throw SoundPackLoadError.notAPackFolder
        }
        let oggFiles = referencedOggFiles(in: handle)
        guard oggFiles.isEmpty else {
            Self.log.warning("Import rejected — \(oggFiles.count) ogg files referenced")
            throw SoundPackLoadError.unsupportedOggAudio(oggFiles.count)
        }

        let packsDirectory = Self.userPacksDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let destination = packsDirectory
            .appendingPathComponent(source.lastPathComponent, isDirectory: true)
            .standardizedFileURL

        // Choosing a pack that already lives in Click's managed folder is a
        // harmless no-op. Without this guard the old implementation deleted
        // the source before attempting to copy it back over itself.
        if source.path == destination.resolvingSymlinksInPath().path {
            Self.log.notice("Import skipped — pack is already installed")
            return
        }

        let token = UUID().uuidString
        let staging = packsDirectory
            .appendingPathComponent(".\(token).importing", isDirectory: true)
        let backup = packsDirectory
            .appendingPathComponent(".\(token).backup", isDirectory: true)

        do {
            try fm.copyItem(at: source, to: staging)
        } catch {
            Self.log.error("Import staging failed: \(error.localizedDescription, privacy: .private)")
            throw SoundPackLoadError.importCopyFailed(error.localizedDescription)
        }
        defer {
            if fm.fileExists(atPath: staging.path) {
                try? fm.removeItem(at: staging)
            }
        }
        try Self.validateImportedTree(at: staging)

        // Validate the staged bytes, rather than trusting only the source
        // manifest. This catches broken references, symlink escapes, decoding
        // failures, and packs with no playable samples before replacement.
        guard let stagedHandle = makeHandle(at: staging) else {
            throw SoundPackLoadError.notAPackFolder
        }
        let stagedOggFiles = referencedOggFiles(in: stagedHandle)
        guard stagedOggFiles.isEmpty else {
            throw SoundPackLoadError.unsupportedOggAudio(stagedOggFiles.count)
        }
        let stagedPack = try load(handle: stagedHandle)
        guard stagedPack.variantCount > 0 else {
            throw SoundPackLoadError.manifestInvalid("pack contains no playable sounds")
        }

        do {
            try installStagedPack(
                staging,
                at: destination,
                preservingExistingAt: backup,
                fileManager: fm
            )
            Self.log.notice("Imported pack: \(destination.lastPathComponent, privacy: .private)")
        } catch {
            Self.log.error("Import failed: \(error.localizedDescription, privacy: .private)")
            if let loadError = error as? SoundPackLoadError {
                throw loadError
            }
            throw SoundPackLoadError.importCopyFailed(error.localizedDescription)
        }
    }

    /// Commits a validated staging directory using same-volume renames. If the
    /// new rename fails, the previous directory is moved back into place. A
    /// backup is intentionally left on disk if rollback itself fails.
    private func installStagedPack(
        _ staging: URL,
        at destination: URL,
        preservingExistingAt backup: URL,
        fileManager fm: FileManager
    ) throws {
        guard fm.fileExists(atPath: destination.path) else {
            try fm.moveItem(at: staging, to: destination)
            return
        }

        try fm.moveItem(at: destination, to: backup)
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            do {
                try fm.moveItem(at: backup, to: destination)
            } catch let rollbackError {
                Self.log.fault("Import rollback failed; previous pack preserved at \(backup.lastPathComponent, privacy: .public): \(rollbackError.localizedDescription, privacy: .public)")
                throw SoundPackLoadError.importCopyFailed(
                    "The replacement failed. Your previous pack was preserved as \(backup.lastPathComponent)."
                )
            }
            throw error
        }

        do {
            try fm.removeItem(at: backup)
        } catch {
            // Installation succeeded; a hidden stale backup is preferable to
            // reporting a false failure or risking the new working pack.
            Self.log.warning("Imported pack installed, but stale backup cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sound files referenced by the pack manifest that AVFoundation cannot
    /// decode (Ogg Vorbis). Checked at import time so the user gets a clear
    /// error instead of a pack that plays silence.
    private nonisolated func referencedOggFiles(in handle: PackHandle) -> [String] {
        let referenced: [String]
        switch handle.kind {
        case .clickpack:
            guard let data = try? Self.readMetadataFile("manifest.json", base: handle.url),
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
    /// `base` (e.g. `../../etc/passwd` or an escaping symlink in a malicious
    /// manifest).
    static func resolveInside(_ relative: String, base: URL) throws -> URL {
        let canonicalBase = base.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalBase
            .appendingPathComponent(relative)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let basePath = canonicalBase.path
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

    /// Reads a small JSON metadata file only after applying the same symlink
    /// containment rules used for audio references.
    static func readMetadataFile(_ relative: String, base: URL) throws -> Data {
        let url = try resolveInside(relative, base: base)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw SoundPackLoadError.manifestMissing
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size >= 0,
              size <= maximumMetadataFileBytes else {
            throw SoundPackLoadError.resourceLimitExceeded("\(relative) exceeds the 1 MB metadata limit")
        }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw SoundPackLoadError.manifestMissing
        }
    }

    static func validate(manifest: ClickPackManifest) throws {
        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.name.count <= 128 else {
            throw SoundPackLoadError.manifestInvalid("pack name must contain 1–128 characters")
        }
        let keyMap = manifest.keyMap ?? [:]
        guard keyMap.count <= maximumKeyMapEntries else {
            throw SoundPackLoadError.resourceLimitExceeded("manifest has more than 512 key mappings")
        }
        let referenceCount = keyMap.values.reduce(0) { partial, paths in
            partial + paths.count
        } + (manifest.defaultSound == nil ? 0 : 1)
        guard referenceCount <= maximumAudioReferences else {
            throw SoundPackLoadError.resourceLimitExceeded("manifest has more than 4,096 audio references")
        }
    }

    /// Bounds the entire imported tree, including files not referenced by the
    /// manifest, before copying and again after staging. Symlinks and special
    /// files are rejected so imports cannot escape containment or fill disk via
    /// an unexpected device/file type.
    static func validateImportedTree(at root: URL) throws {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
        ]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw SoundPackLoadError.resourceLimitExceeded("the pack folder could not be enumerated")
        }

        var fileCount = 0
        var totalBytes: UInt64 = 0
        while let item = enumerator.nextObject() as? URL {
            let values: URLResourceValues
            do {
                values = try item.resourceValues(forKeys: Set(keys))
            } catch {
                throw SoundPackLoadError.resourceLimitExceeded("file metadata could not be read")
            }
            if values.isSymbolicLink == true {
                throw SoundPackLoadError.manifestInvalid("symbolic links are not allowed in imported packs")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
                throw SoundPackLoadError.manifestInvalid("import contains an unsupported file type")
            }
            fileCount += 1
            guard fileCount <= maximumImportedFileCount else {
                throw SoundPackLoadError.resourceLimitExceeded("the pack contains more than 2,048 files")
            }
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(UInt64(size))
            guard !overflow, newTotal <= maximumImportedTreeBytes else {
                throw SoundPackLoadError.resourceLimitExceeded("the pack exceeds the 512 MB import limit")
            }
            totalBytes = newTotal
        }
        if enumerationError != nil {
            throw SoundPackLoadError.resourceLimitExceeded("the complete pack tree could not be read")
        }
    }

    /// Decodes any AVFoundation-supported audio URL into a single PCM buffer
    /// big enough to hold the whole file.
    static func decode(url: URL, budget: inout AudioDecodeBudget) throws -> AVAudioPCMBuffer {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw SoundPackLoadError.audioMissing(url.lastPathComponent)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size >= 0 else {
            throw SoundPackLoadError.decodeFailed("\(url.lastPathComponent): unsupported file type")
        }
        if size > maximumEncodedAudioFileBytes {
            throw SoundPackLoadError.resourceLimitExceeded(
                "\(url.lastPathComponent) exceeds the 256 MB file limit"
            )
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw SoundPackLoadError.audioMissing(url.lastPathComponent)
        }
        let format = file.processingFormat
        try budget.reserve(frameCount: file.length, format: format, label: url.lastPathComponent)
        // Safe after the budget checked positivity and AVAudioFrameCount.max.
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
