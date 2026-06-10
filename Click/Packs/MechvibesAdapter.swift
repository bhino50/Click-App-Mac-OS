import AVFoundation
import Foundation

/// Translates Mechvibes pack folders into the internal `SoundPack` model.
///
/// Mechvibes ships two variants:
///
/// 1. **Multi-file**: `config.json` with `defines: { "<mvKeycode>": "file.ogg" }`
///    and a folder of small audio files.
/// 2. **Single-file**: `config.json` with `key_define_type: "single"`, one
///    audio file (`sound: "<file>"`), and `defines: { "<mvKeycode>": [startMs, durationMs] }`.
///
/// Both produce `SoundPack` objects with pre-decoded `AVAudioPCMBuffer`s,
/// keyed by macOS virtual keycodes — the rest of the app is format-agnostic.
nonisolated
enum MechvibesAdapter {
    nonisolated
    struct Config: Decodable {
        let id: String?
        let name: String?
        let key_define_type: String?
        let sound: String?
        let includes_numpad: Bool?
        let defines: [String: ConfigValue]?

        enum ConfigValue: Decodable {
            case file(String)
            case slice(start: Double, duration: Double)
            case missing

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if container.decodeNil() { self = .missing; return }
                if let s = try? container.decode(String.self) {
                    self = .file(s); return
                }
                if let pair = try? container.decode([Double].self), pair.count >= 2 {
                    self = .slice(start: pair[0], duration: pair[1]); return
                }
                if let b = try? container.decode(Bool.self), b == false {
                    self = .missing; return
                }
                self = .missing
            }
        }
    }

    /// Light-weight inspection used while listing packs (avoids decoding audio).
    static func previewManifest(folder: URL) throws -> ClickPackManifest {
        let cfg = try decodeConfig(at: folder)
        return ClickPackManifest(name: cfg.name ?? folder.lastPathComponent,
                                 author: nil,
                                 version: nil,
                                 defaultSound: nil,
                                 keyMap: nil)
    }

    /// Audio file names referenced by a Mechvibes `config.json` — the single
    /// `sound` file or every file-typed entry in `defines`. Used by the import
    /// guard to detect formats AVFoundation cannot decode.
    static func referencedAudioFiles(folder: URL) -> [String] {
        guard let cfg = try? decodeConfig(at: folder) else { return [] }
        var files: [String] = []
        if let sound = cfg.sound { files.append(sound) }
        for value in (cfg.defines ?? [:]).values {
            if case let .file(file) = value { files.append(file) }
        }
        return files
    }

    /// Returns the right `PackHandle.Kind` if `folder` looks like a Mechvibes pack.
    static func classify(folder: URL) -> PackHandle.Kind? {
        guard let cfg = try? decodeConfig(at: folder) else { return nil }
        let type = (cfg.key_define_type ?? "multi").lowercased()
        if type == "single" && cfg.sound != nil { return .mechvibesSingle }
        return .mechvibesMulti
    }

    static func load(folder: URL, kind: PackHandle.Kind) throws -> SoundPack {
        let cfg = try decodeConfig(at: folder)
        switch kind {
        case .mechvibesSingle:
            return try loadSingle(folder: folder, config: cfg)
        case .mechvibesMulti:
            return try loadMulti(folder: folder, config: cfg)
        case .clickpack:
            throw SoundPackLoadError.manifestInvalid("clickpack passed to mechvibes loader")
        }
    }

    // MARK: Private

    private static func decodeConfig(at folder: URL) throws -> Config {
        let url = folder.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url) else {
            throw SoundPackLoadError.manifestMissing
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw SoundPackLoadError.manifestInvalid(error.localizedDescription)
        }
    }

    private static func loadMulti(folder: URL, config: Config) throws -> SoundPack {
        var samples: [Int64: [AVAudioPCMBuffer]] = [:]
        for (mvCode, value) in config.defines ?? [:] {
            guard case let .file(file) = value,
                  let mv = Int(mvCode),
                  let mac = KeyCodeMap.mechvibesToMac[mv] else { continue }
            // Reject path traversal in malicious config.json `defines`.
            guard let url = try? SoundPackLoader.resolveInside(file, base: folder),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            let buffer = try SoundPackLoader.decode(url: url)
            samples[mac, default: []].append(buffer)
        }
        return SoundPack(name: config.name ?? folder.lastPathComponent,
                         author: nil,
                         kind: .mechvibesMulti,
                         samplesByKeyCode: samples,
                         defaultSamples: [])
    }

    private static func loadSingle(folder: URL, config: Config) throws -> SoundPack {
        guard let soundName = config.sound else {
            throw SoundPackLoadError.manifestInvalid("Single-file pack missing 'sound'")
        }
        let soundURL = try SoundPackLoader.resolveInside(soundName, base: folder)
        let source = try SoundPackLoader.decode(url: soundURL)
        let sampleRate = source.format.sampleRate

        var samples: [Int64: [AVAudioPCMBuffer]] = [:]
        for (mvCode, value) in config.defines ?? [:] {
            guard case let .slice(start, duration) = value,
                  duration > 0,
                  let mv = Int(mvCode),
                  let mac = KeyCodeMap.mechvibesToMac[mv] else { continue }
            if let slice = slice(buffer: source,
                                 startMillis: start,
                                 durationMillis: duration,
                                 sampleRate: sampleRate) {
                samples[mac, default: []].append(slice)
            }
        }
        return SoundPack(name: config.name ?? folder.lastPathComponent,
                         author: nil,
                         kind: .mechvibesSingle,
                         samplesByKeyCode: samples,
                         defaultSamples: [])
    }

    /// Copies a sub-range of `buffer` into a new PCM buffer. Returns `nil` when
    /// the range falls outside the source or the destination buffer can't be
    /// allocated.
    private static func slice(buffer: AVAudioPCMBuffer,
                              startMillis: Double,
                              durationMillis: Double,
                              sampleRate: Double) -> AVAudioPCMBuffer? {
        let startFrame = AVAudioFramePosition(startMillis / 1000.0 * sampleRate)
        let frameCount = AVAudioFrameCount(durationMillis / 1000.0 * sampleRate)
        guard frameCount > 0,
              startFrame >= 0,
              startFrame + AVAudioFramePosition(frameCount) <= AVAudioFramePosition(buffer.frameLength)
        else { return nil }

        guard let dest = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frameCount) else {
            return nil
        }
        dest.frameLength = frameCount
        let channels = Int(buffer.format.channelCount)

        if let src = buffer.floatChannelData, let dst = dest.floatChannelData {
            for ch in 0..<channels {
                let srcPtr = src[ch].advanced(by: Int(startFrame))
                dst[ch].update(from: srcPtr, count: Int(frameCount))
            }
            return dest
        }
        if let src = buffer.int16ChannelData, let dst = dest.int16ChannelData {
            for ch in 0..<channels {
                let srcPtr = src[ch].advanced(by: Int(startFrame))
                dst[ch].update(from: srcPtr, count: Int(frameCount))
            }
            return dest
        }
        return nil
    }
}
