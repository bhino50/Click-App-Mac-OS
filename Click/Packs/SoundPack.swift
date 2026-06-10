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
        return samplesByKeyCode.values.flatMap { $0 }.randomElement()
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
    /// installed. Buffers that fail to convert are dropped from the copy.
    func converted(to format: AVAudioFormat) -> SoundPack {
        var samples: [Int64: [AVAudioPCMBuffer]] = [:]
        for (key, bucket) in samplesByKeyCode {
            let converted = bucket.compactMap { Self.convertBuffer($0, to: format) }
            if !converted.isEmpty { samples[key] = converted }
        }
        let defaults = defaultSamples.compactMap { Self.convertBuffer($0, to: format) }
        return SoundPack(name: name,
                         author: author,
                         kind: kind,
                         samplesByKeyCode: samples,
                         defaultSamples: defaults)
    }

    static func convertBuffer(_ source: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if source.format.isEqual(format) { return source }
        guard let converter = AVAudioConverter(from: source.format, to: format) else {
            return nil
        }
        // Estimate destination frame count from the sample rate ratio.
        let ratio = format.sampleRate / source.format.sampleRate
        let estimatedFrames = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
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
