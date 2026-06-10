import AVFoundation
import Foundation
import os

/// Wraps an `AVAudioEngine` and a `PlayerNodePool`. Owns the currently
/// installed `SoundPack` and dispatches `play(keyCode:)` to a free node.
actor AudioEngine {
    private static let log = Logger(subsystem: "brandon.Click", category: "audio")

    private let engine = AVAudioEngine()
    private var pool: PlayerNodePool?
    private var pack: SoundPack?
    /// The pack as passed to `installPack` (pre-conversion). Kept so we can
    /// re-convert against a new processing format after a configuration change.
    private var rawPack: SoundPack?
    private var processingFormat: AVAudioFormat?
    private var didRegisterConfigObserver = false

    /// Boots the engine. Idempotent.
    func start() {
        registerConfigObserverIfNeeded()
        guard !engine.isRunning else { return }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        processingFormat = format
        if pool == nil {
            pool = PlayerNodePool(engine: engine, mixer: engine.mainMixerNode, format: format, size: 16)
        }
        do {
            try engine.start()
            pool?.startAll()
            Self.log.notice("AVAudioEngine started — format \(format.sampleRate)Hz \(format.channelCount)ch")
        } catch {
            Self.log.error("AVAudioEngine.start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// AVAudioEngine implicitly stops when the audio configuration changes
    /// (output device switch, sample-rate change because another app started
    /// or stopped playback, AirPods toggling between A2DP/HFP, …). Without
    /// this observer, `play()` then silently no-ops on the `engine.isRunning`
    /// guard whenever the user has had other audio running. The engine is
    /// app-lifetime so we never remove the observer.
    private func registerConfigObserverIfNeeded() {
        guard !didRegisterConfigObserver else { return }
        didRegisterConfigObserver = true
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.handleConfigurationChange()
            }
        }
    }

    /// Rebuilds the engine after a system audio configuration change so
    /// subsequent `play()` calls don't silently no-op.
    private func handleConfigurationChange() {
        Self.log.notice("audio configuration changed — rebuilding engine")
        pool?.detachAll(from: engine)
        pool = nil
        engine.stop()
        // The previously-installed pack was converted against the old format;
        // re-convert from the raw original against the new processing format.
        let savedRaw = rawPack
        pack = nil
        processingFormat = nil
        start()
        if let savedRaw {
            installPack(savedRaw)
        }
    }

    func stop() {
        pool?.stopAll()
        engine.stop()
    }

    /// `AVAudioFormat.isEqual` also compares channel layouts, which
    /// `AVAudioConverter` may legitimately not preserve (nil-layout vs.
    /// `kAudioChannelLayoutTag_Stereo`). For `scheduleBuffer` we only need the
    /// sample format, rate, channel count, and interleaving to match.
    private static func bufferMatches(_ buffer: AVAudioFormat, _ expected: AVAudioFormat) -> Bool {
        buffer.commonFormat == expected.commonFormat
            && buffer.sampleRate == expected.sampleRate
            && buffer.channelCount == expected.channelCount
            && buffer.isInterleaved == expected.isInterleaved
    }

    func installPack(_ pack: SoundPack) {
        // Make sure the engine is running so we have a valid processing format.
        if processingFormat == nil { start() }
        guard let format = processingFormat else {
            // Don't store the un-converted pack — scheduleBuffer would throw an
            // Obj-C exception on the first keypress. Leave the previous pack in
            // place and surface the failure.
            Self.log.error("installPack: no processing format available — pack \(pack.name, privacy: .public) not installed")
            return
        }
        rawPack = pack
        self.pack = pack.converted(to: format)
        Self.log.notice("Installed pack \(pack.name, privacy: .public) — converted to \(format.sampleRate)Hz \(format.channelCount)ch")
    }

    /// Picks a sample for `keyCode` (with random selection across variants),
    /// schedules it on the next free player node, and fires playback.
    /// Volume is clamped to `[0, 1]`.
    func play(keyCode: Int64, volume: Float) {
        if !engine.isRunning {
            // Most likely a configuration change is in flight and the engine
            // was just stopped. Attempt a lazy rebuild rather than no-op'ing.
            handleConfigurationChange()
            guard engine.isRunning else {
                Self.log.error("play: engine not running (rebuild failed)")
                return
            }
        }
        guard let pack else {
            Self.log.error("play: no pack installed")
            return
        }
        guard let buffer = pack.sample(for: keyCode) else {
            Self.log.error("play: no sample for keyCode=\(keyCode, privacy: .public)")
            return
        }
        guard let node = pool?.next() else {
            Self.log.error("play: no pool node available")
            return
        }
        if let expected = processingFormat,
           !Self.bufferMatches(buffer.format, expected) {
            Self.log.error("play: format mismatch (buffer=\(buffer.format.sampleRate)/\(buffer.format.channelCount), expected=\(expected.sampleRate)/\(expected.channelCount))")
            return
        }
        let clamped = max(0.0, min(1.0, volume))
        node.volume = clamped
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionCallbackType: .dataPlayedBack) { _ in }
        if !node.isPlaying { node.play() }
    }

}
