import AVFoundation
import Foundation

/// Lightweight pointer to a pack on disk; cheap to enumerate without loading
/// audio. Use `SoundPackLoader.load(handle:)` to turn one into a real `SoundPack`.
nonisolated
struct PackHandle: Sendable, Identifiable, Hashable {
    nonisolated
    enum Kind: Sendable, Hashable {
        /// Native `.clickpack` manifest.
        case clickpack
        /// Mechvibes folder with `config.json`.
        case mechvibesMulti
        /// Mechvibes folder with `config.json` + one sliced audio file.
        case mechvibesSingle
    }

    let id: String
    let name: String
    let author: String?
    let url: URL
    let kind: Kind
}

/// Outcome of converting a pack to an engine processing format. Carries the
/// converted pack plus how many source buffers were dropped along the way.
nonisolated
struct PackConversionResult {
    let pack: SoundPack
    let failedBufferCount: Int
    let totalBufferCount: Int

    var allBuffersFailed: Bool {
        totalBufferCount > 0 && failedBufferCount == totalBufferCount
    }
}

/// A fully-loaded pack ready for playback. Owned by the audio actor.
///
/// Marked `@unchecked Sendable` because `AVAudioPCMBuffer` is a non-Sendable
/// reference type. We never mutate buffers after load and only ever hand them
/// to `AVAudioPlayerNode.scheduleBuffer`, so the contract is safe.
nonisolated
final class SoundPack: @unchecked Sendable {
    let name: String
    let author: String?
    let kind: PackHandle.Kind

    private let samplesByKeyCode: [Int64: [AVAudioPCMBuffer]]
    private let defaultSamples: [AVAudioPCMBuffer]
    /// Precomputed once so an unmapped key never flattens every sample bucket
    /// on the latency-sensitive keystroke path.
    private let fallbackSamples: [AVAudioPCMBuffer]

    init(name: String,
         author: String?,
         kind: PackHandle.Kind,
         samplesByKeyCode: [Int64: [AVAudioPCMBuffer]],
         defaultSamples: [AVAudioPCMBuffer]) {
        self.name = name
        self.author = author
        self.kind = kind
        self.samplesByKeyCode = samplesByKeyCode
        self.defaultSamples = defaultSamples
        self.fallbackSamples = samplesByKeyCode.values.flatMap { $0 }
    }

    /// Returns a sample for the given keycode. Picks at random when more than
    /// one variant is available, giving each keystroke a slightly different feel.
    /// Uses `randomElement()` (the system generator under the hood) so concurrent
    /// callers don't share mutable RNG state.
    func sample(for keyCode: Int64) -> AVAudioPCMBuffer? {
        if let bucket = samplesByKeyCode[keyCode], !bucket.isEmpty {
            return bucket.randomElement()
        }
        if let s = defaultSamples.randomElement() {
            return s
        }
        // Last-resort fallback: pick any mapped sample. Mechvibes packs never
        // populate `defaultSamples`, so the test-sound button (which uses
        // keyCode 0) would otherwise silently no-op when keyCode 0 isn't in
        // the pack's `defines` map.
        return fallbackSamples.randomElement()
    }

    var mappedKeyCount: Int { samplesByKeyCode.count }
    var variantCount: Int {
        samplesByKeyCode.values.reduce(0) { $0 + $1.count } + defaultSamples.count
    }

    /// Returns a copy of this pack with every PCM buffer converted to `format`.
    ///
    /// `AVAudioPlayerNode.scheduleBuffer` throws an Obj-C exception when the
    /// buffer's format does not match the node's connection format, so packs
    /// must be converted to the engine's processing format before they're
    /// installed. Buffers that fail to convert are dropped from the copy; the
    /// result reports how many were dropped so callers can surface total or
    /// partial conversion failures instead of playing silence.
    func converted(to format: AVAudioFormat) -> PackConversionResult {
        var failed = 0
        var total = 0
        var budget = AudioDecodeBudget()
        var samples: [Int64: [AVAudioPCMBuffer]] = [:]
        for (key, bucket) in samplesByKeyCode {
            total += bucket.count
            var converted: [AVAudioPCMBuffer] = []
            converted.reserveCapacity(bucket.count)
            for buffer in bucket {
                if let output = Self.convertBuffer(buffer, to: format, budget: &budget) {
                    converted.append(output)
                }
            }
            failed += bucket.count - converted.count
            if !converted.isEmpty { samples[key] = converted }
        }
        total += defaultSamples.count
        var defaults: [AVAudioPCMBuffer] = []
        defaults.reserveCapacity(defaultSamples.count)
        for buffer in defaultSamples {
            if let output = Self.convertBuffer(buffer, to: format, budget: &budget) {
                defaults.append(output)
            }
        }
        failed += defaultSamples.count - defaults.count
        let pack = SoundPack(name: name,
                             author: author,
                             kind: kind,
                             samplesByKeyCode: samples,
                             defaultSamples: defaults)
        return PackConversionResult(pack: pack,
                                    failedBufferCount: failed,
                                    totalBufferCount: total)
    }

    static func convertBuffer(
        _ source: AVAudioPCMBuffer,
        to format: AVAudioFormat,
        budget: inout AudioDecodeBudget
    ) -> AVAudioPCMBuffer? {
        if source.format.isEqual(format) { return source }
        guard let converter = AVAudioConverter(from: source.format, to: format) else {
            return nil
        }
        // Estimate destination frame count from the sample rate ratio.
        guard source.format.sampleRate.isFinite, source.format.sampleRate > 0,
              format.sampleRate.isFinite, format.sampleRate > 0 else {
            return nil
        }
        let ratio = format.sampleRate / source.format.sampleRate
        let estimatedValue = Double(source.frameLength) * ratio
        guard estimatedValue.isFinite, estimatedValue >= 1,
              estimatedValue <= Double(AVAudioFrameCount.max - 1_024) else {
            return nil
        }
        let estimatedFrames = AVAudioFrameCount(estimatedValue.rounded(.up)) + 1_024
        guard (try? budget.reserve(
            frameCount: AVAudioFramePosition(estimatedFrames),
            format: format,
            label: "converted audio"
        )) != nil else {
            return nil
        }
        guard let dest = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: estimatedFrames) else {
            return nil
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: dest, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return source
        }
        if status == .error || error != nil { return nil }
        return dest
    }
}
