import AVFoundation
import Foundation
import XCTest
@testable import Click

final class SemanticVersionTests: XCTestCase {
    func testComparesNumericComponentsInsteadOfLexicographicText() {
        XCTAssertLessThan(SemanticVersion("1.9")!, SemanticVersion("1.10")!)
        XCTAssertGreaterThan(SemanticVersion("2.0")!, SemanticVersion("1.99.99")!)
    }

    func testTreatsMissingTrailingComponentsAsZero() {
        XCTAssertEqual(SemanticVersion("1")!, SemanticVersion("1.0.0")!)
    }

    func testRejectsMalformedVersions() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("1.two.3"))
        XCTAssertNil(SemanticVersion("-1.0"))
    }
}

final class UpdateDownloadValidationTests: XCTestCase {
    func testAcceptsHTTPSDownloadURL() {
        let raw = "https://github.com/bhino50/Click-App-Mac-OS/releases/download/v1.0/Click.dmg"
        XCTAssertEqual(UpdateChecker.validatedDownloadURL(raw)?.absoluteString, raw)
    }

    func testRejectsPlaintextAndNonNetworkURLs() {
        XCTAssertNil(UpdateChecker.validatedDownloadURL("http://example.com/Click.dmg"))
        XCTAssertNil(UpdateChecker.validatedDownloadURL("file:///tmp/Click.dmg"))
        XCTAssertNil(UpdateChecker.validatedDownloadURL("not a URL"))
    }
}

final class SoundPackPathResolutionTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClickTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testAllowsFilesContainedInPack() throws {
        let pack = temporaryDirectory.appendingPathComponent("Pack.clickpack", isDirectory: true)
        let audio = pack.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let sample = audio.appendingPathComponent("sample.wav")
        try Data("sample".utf8).write(to: sample)

        let resolved = try SoundPackLoader.resolveInside("audio/sample.wav", base: pack)

        XCTAssertEqual(resolved, sample.resolvingSymlinksInPath())
    }

    func testRejectsParentDirectoryTraversal() throws {
        let pack = temporaryDirectory.appendingPathComponent("Pack.clickpack", isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try SoundPackLoader.resolveInside("../outside.wav", base: pack)
        )
    }

    func testRejectsSymlinkThatEscapesPack() throws {
        let pack = temporaryDirectory.appendingPathComponent("Pack.clickpack", isDirectory: true)
        let outside = temporaryDirectory.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sample = outside.appendingPathComponent("sample.wav")
        try Data("sample".utf8).write(to: sample)
        try FileManager.default.createSymbolicLink(
            at: pack.appendingPathComponent("linked-audio", isDirectory: true),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try SoundPackLoader.resolveInside("linked-audio/sample.wav", base: pack)
        )
    }

    func testRejectsOversizedMetadata() throws {
        let pack = temporaryDirectory.appendingPathComponent("Pack.clickpack", isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        let manifest = pack.appendingPathComponent("manifest.json")
        try Data(repeating: 0, count: SoundPackLoader.maximumMetadataFileBytes + 1)
            .write(to: manifest)

        XCTAssertThrowsError(
            try SoundPackLoader.readMetadataFile("manifest.json", base: pack)
        )
    }

    func testRejectsOversizedImportedTree() throws {
        let pack = temporaryDirectory.appendingPathComponent("Pack.clickpack", isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        let payload = pack.appendingPathComponent("unused.bin")
        _ = FileManager.default.createFile(atPath: payload.path, contents: Data())
        let handle = try FileHandle(forWritingTo: payload)
        try handle.truncate(atOffset: SoundPackLoader.maximumImportedTreeBytes + 1)
        try handle.close()

        XCTAssertThrowsError(try SoundPackLoader.validateImportedTree(at: pack))
    }
}

final class SoundPackManifestLimitTests: XCTestCase {
    func testRejectsExcessiveKeyMappings() {
        let mappings = Dictionary(uniqueKeysWithValues: (0...SoundPackLoader.maximumKeyMapEntries)
            .map { (String($0), ["audio/sample.wav"]) })
        let manifest = ClickPackManifest(
            name: "Too Many Keys",
            author: nil,
            version: nil,
            defaultSound: nil,
            keyMap: mappings
        )

        XCTAssertThrowsError(try SoundPackLoader.validate(manifest: manifest))
    }
}

final class AudioConversionLimitTests: XCTestCase {
    func testRejectsConversionThatWouldExceedDecodedBufferLimit() throws {
        let sourceFormat = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)
        )
        let outputFormat = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 192_000, channels: 2)
        )
        let source = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 1_000_000)
        )
        source.frameLength = 1_000_000
        var budget = AudioDecodeBudget()

        XCTAssertNil(SoundPack.convertBuffer(source, to: outputFormat, budget: &budget))
    }
}

final class EventTapLaunchFailureTests: XCTestCase {
    @MainActor
    private final class ScriptedTap: KeyEventTapProviding {
        private let startResult: Bool

        init(startResult: Bool) {
            self.startResult = startResult
        }

        var isHealthy: Bool { startResult }

        func events() -> AsyncStream<KeyEvent> {
            AsyncStream { $0.finish() }
        }

        @discardableResult
        func start() -> Bool { startResult }

        func stop() {}
    }

    @MainActor
    func testStartFailureShowsWarningAndKeepsWatchdogRunning() async {
        let suiteName = "ClickTests.EventTapLaunchFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.isEnabled = true
        let coordinator = AppCoordinator(settings: settings)
        coordinator.makeEventTap = { ScriptedTap(startResult: false) }

        await coordinator.startEventTap()

        XCTAssertFalse(coordinator.isInputCaptureActive)
        XCTAssertTrue(coordinator.inputMonitoringLost)
        XCTAssertTrue(coordinator.isTapHealthMonitoring)
        XCTAssertEqual(coordinator.menuBarIconName, "exclamationmark.triangle.fill")
    }

    @MainActor
    func testSuccessfulRetryClearsWarning() async {
        let suiteName = "ClickTests.EventTapLaunchFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.isEnabled = true
        let coordinator = AppCoordinator(settings: settings)
        coordinator.makeEventTap = { ScriptedTap(startResult: false) }

        await coordinator.startEventTap()
        XCTAssertTrue(coordinator.inputMonitoringLost)

        coordinator.makeEventTap = { ScriptedTap(startResult: true) }
        await coordinator.startEventTap()

        XCTAssertTrue(coordinator.isInputCaptureActive)
        XCTAssertFalse(coordinator.inputMonitoringLost)
        XCTAssertEqual(coordinator.menuBarIconName, "keyboard.fill")
    }
}

final class MasterLifecycleTests: XCTestCase {
    @MainActor
    func testTurningOffStopsCaptureMonitoringAndAudio() async {
        let suiteName = "ClickTests.MasterLifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let coordinator = AppCoordinator(settings: settings)

        await coordinator.setEnabled(true)
        await coordinator.setEnabled(false)

        XCTAssertFalse(coordinator.settings.isEnabled)
        XCTAssertFalse(coordinator.isInputCaptureActive)
        XCTAssertFalse(coordinator.isPermissionPolling)
        XCTAssertFalse(coordinator.isTapHealthMonitoring)
        let audioIsRunning = await coordinator.audio.isRunning
        XCTAssertFalse(audioIsRunning)
    }
}
