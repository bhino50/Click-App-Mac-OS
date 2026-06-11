import AppKit
import Observation
import SwiftUI
import os

/// Top-level glue: owns the settings store, audio engine, event tap, pack
/// loader, and permissions manager, and wires keystrokes through to playback.
///
/// Lives on the `MainActor` — UI binds to its `@Observable` state directly.
@MainActor
@Observable
final class AppCoordinator {
    static let log = Logger(subsystem: "brandon.Click", category: "coordinator")
    static let bundledPackFallback = "CherryMX Blue - PBT keycaps"

    var settings: SettingsStore
    var permissions: PermissionsManager
    var packLoader: SoundPackLoader
    var audio: AudioEngine
    var folderWatcher: PackFolderWatcher
    #if !MAS_BUILD
    var updateChecker: UpdateChecker
    #endif
    @ObservationIgnored
    private(set) lazy var feedbackController = KeyFeedbackController(coordinator: self)

    private(set) var currentPack: SoundPack?
    private(set) var availablePacks: [PackHandle] = []
    private(set) var lastPressedKey: Int64?
    private(set) var lastPressAt: Date?
    private(set) var loadError: String?

    /// Set to `true` when Input Monitoring permission is missing. Views observe
    /// this to surface the onboarding window.
    var needsOnboarding: Bool = false
    var shouldShowWelcomeGuide = false

    /// `true` when Input Monitoring access was revoked after the tap was running,
    /// or when the tap died and could not be reinstalled. Drives the menu bar
    /// warning state; cleared automatically once the tap is healthy again.
    private(set) var inputMonitoringLost = false

    private static let tapHealthInterval: Duration = .seconds(30)

    private var eventTap: KeyEventTap?
    private var eventConsumeTask: Task<Void, Never>?
    private var permissionsPollTask: Task<Void, Never>?
    private var folderWatchTask: Task<Void, Never>?
    private var tapHealthTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var lastKeystrokeMach: UInt64 = 0
    private var didBootstrap = false

    init() {
        self.settings = SettingsStore()
        self.permissions = PermissionsManager()
        self.packLoader = SoundPackLoader()
        self.audio = AudioEngine()
        self.folderWatcher = PackFolderWatcher(url: SoundPackLoader.userPacksDirectory)
        #if !MAS_BUILD
        self.updateChecker = UpdateChecker()
        #endif
    }

    // MARK: Lifecycle

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await audio.start()
        await refreshPacks()
        if !(await selectPack(named: settings.selectedPackName ?? Self.bundledPackFallback)) {
            await selectFirstAvailablePack()
        }
        startFolderWatcher()
        feedbackController.ensurePanel()
        registerWakeObserver()
        #if !MAS_BUILD
        updateChecker.scheduleLaunchCheck()
        #endif
        await ensurePermissionsAndStartTap()
    }

    /// SF Symbol for the menu bar icon. Switches to a warning when the event
    /// tap lost Input Monitoring access or a sound pack failed to load or import,
    /// so failures are visible without opening Settings.
    var menuBarIconName: String {
        if inputMonitoringLost || loadError != nil { return "exclamationmark.triangle.fill" }
        return settings.isEnabled ? "keyboard.fill" : "keyboard"
    }

    // MARK: Pack management

    func refreshPacks() async {
        availablePacks = await packLoader.discover()
        Self.log.notice("Discovered \(self.availablePacks.count, privacy: .public) packs: \(self.availablePacks.map(\.name).joined(separator: ", "), privacy: .public)")
    }

    @discardableResult
    func selectPack(named name: String?) async -> Bool {
        guard let name,
              let handle = availablePacks.first(where: { $0.name == name }) else {
            return false
        }
        return await selectPack(handle: handle)
    }

    @discardableResult
    func selectPack(handle: PackHandle) async -> Bool {
        do {
            let pack = try await packLoader.load(handle: handle)
            if let installError = await audio.installPack(pack) {
                loadError = "\(handle.name): \(installError)"
                Self.log.error("Pack install failed for \(handle.name, privacy: .public): \(installError, privacy: .public)")
                return false
            }
            currentPack = pack
            settings.selectedPackName = pack.name
            loadError = nil
            return true
        } catch {
            loadError = "\(handle.name): \(error.localizedDescription)"
            Self.log.error("Pack load failed for \(handle.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func selectFirstAvailablePack() async {
        if let first = availablePacks.first {
            await selectPack(handle: first)
        }
    }

    /// Imports each URL as a pack and refreshes discovery. Failures are
    /// surfaced through `loadError` (menu bar warning plus Settings); the
    /// error clears on the next successful pack load.
    func importPacks(from urls: [URL]) async {
        var failures: [String] = []
        for url in urls {
            // In the sandboxed App Store build, drag-and-dropped URLs arrive
            // security-scoped; access must be claimed before reading. Returns
            // false for open-panel URLs and in the direct build — harmless.
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            do {
                try await packLoader.importPack(at: url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                Self.log.error("Pack import failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        await refreshPacks()
        if !failures.isEmpty {
            loadError = failures.joined(separator: "\n")
        }
    }

    private func startFolderWatcher() {
        folderWatchTask?.cancel()
        folderWatchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.folderWatcher.start()
            for await _ in await self.folderWatcher.changes() {
                await self.refreshPacks()
            }
        }
    }

    // MARK: Permissions / event tap

    func ensurePermissionsAndStartTap() async {
        permissions.refresh()
        if permissions.isTrusted {
            needsOnboarding = false
            await startEventTap()
            return
        }
        // Don't fire macOS's native Input Monitoring prompt here.
        // Bootstrap-time prompts collide with the Welcome window if the user
        // clicks the menu bar's Grant button — two dialogs stack on screen.
        // The Welcome window's "Open System Settings" button calls
        // `requestPrompt()` explicitly so the native dialog is user-initiated.
        needsOnboarding = true
        startPermissionsPolling()
    }

    private func startPermissionsPolling() {
        permissionsPollTask?.cancel()
        Self.log.notice("Started permissions polling (current trust=\(self.permissions.isTrusted, privacy: .public))")
        permissionsPollTask = Task { @MainActor [weak self] in
            var ticks = 0
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let wasTrusted = self.permissions.isTrusted
                self.permissions.refresh()
                ticks += 1
                if self.permissions.isTrusted != wasTrusted || ticks % 10 == 0 {
                    Self.log.notice("Polling tick #\(ticks): trust=\(self.permissions.isTrusted, privacy: .public)")
                }
                if self.permissions.isTrusted {
                    self.needsOnboarding = false
                    await self.startEventTap()
                    self.permissionsPollTask = nil
                    return
                }
            }
        }
    }

    func startEventTap() async {
        guard eventTap == nil else { return }
        let tap = KeyEventTap()
        let stream = tap.events()
        guard tap.start() else {
            Self.log.error("Failed to start event tap (Input Monitoring trusted=\(self.permissions.isTrusted, privacy: .public))")
            return
        }
        Self.log.notice("Event tap installed; trust=\(self.permissions.isTrusted, privacy: .public)")
        eventTap = tap
        inputMonitoringLost = false
        startTapHealthChecks()
        eventConsumeTask?.cancel()
        eventConsumeTask = Task { @MainActor [weak self] in
            for await event in stream {
                self?.handle(event: event)
            }
        }
    }

    /// Low-frequency watchdog. macOS can revoke Input Monitoring at any time and
    /// can disable or destroy event taps (slow-callback kills, sleep/wake),
    /// all without notifying the app — without this check Click would keep
    /// running silently.
    private func startTapHealthChecks() {
        guard tapHealthTask == nil else { return }
        tapHealthTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: Self.tapHealthInterval)
                await self.verifyTapHealth(reason: "periodic")
            }
        }
    }

    /// Sleep can tear down event taps; re-verify as soon as the Mac wakes.
    private func registerWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.verifyTapHealth(reason: "wake")
            }
        }
    }

    /// Re-checks Input Monitoring trust and tap liveness, re-enabling or
    /// reinstalling the tap when possible and flagging `inputMonitoringLost`
    /// (menu bar warning) when it is not.
    func verifyTapHealth(reason: String) async {
        permissions.refresh()
        guard permissions.isTrusted else {
            if !inputMonitoringLost {
                Self.log.error("Tap health (\(reason, privacy: .public)): Input Monitoring access revoked")
                inputMonitoringLost = true
                stopEventTap()
                // Fast 1s polling so the tap comes back the moment the user
                // re-grants access in System Settings.
                startPermissionsPolling()
            }
            return
        }
        if let eventTap {
            if eventTap.isHealthy || eventTap.start() {
                if inputMonitoringLost {
                    Self.log.notice("Tap health (\(reason, privacy: .public)): tap healthy again")
                    inputMonitoringLost = false
                }
                return
            }
            Self.log.error("Tap health (\(reason, privacy: .public)): tap could not be re-enabled — reinstalling")
            stopEventTap()
        }
        await startEventTap()
        if eventTap == nil {
            Self.log.error("Tap health (\(reason, privacy: .public)): tap reinstall failed")
            inputMonitoringLost = true
        }
    }

    func stopEventTap() {
        eventConsumeTask?.cancel()
        eventConsumeTask = nil
        eventTap?.stop()
        eventTap = nil
    }

    func toggleEnabled() {
        settings.isEnabled.toggle()
    }

    func openWelcomeGuide() {
        shouldShowWelcomeGuide = true
    }

    /// Plays a sound on demand — handy for verifying audio works before the
    /// global event tap is granted Input Monitoring permission. Uses the default
    /// sample of the current pack.
    func playTestSound() async {
        await audio.play(keyCode: 0, volume: Float(settings.volume))
    }

    // MARK: Keystroke handling

    private func handle(event: KeyEvent) {
        guard settings.isEnabled else { return }
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard settings.allowedAppPolicyMatches(frontmostBundleID: frontBundle) else { return }
        let velocity = velocityScalar(for: event)
        lastPressedKey = event.keyCode
        lastPressAt = Date()
        let volume = Float(settings.volume) * velocity
        Task { [audio] in
            await audio.play(keyCode: event.keyCode, volume: volume)
        }
    }

    private func velocityScalar(for event: KeyEvent) -> Float {
        guard settings.velocitySensitive else { return 1.0 }
        defer { lastKeystrokeMach = event.timestamp }
        guard lastKeystrokeMach != 0 else { return 0.85 }
        let deltaNs = MachClock.nanoseconds(between: lastKeystrokeMach, and: event.timestamp)
        let secs = Double(deltaNs) / 1_000_000_000.0
        // 200ms → 1.0, 1s+ → ~0.7
        let scaled = max(0.7, min(1.0, 1.0 - (secs - 0.2) * 0.35))
        return Float(scaled)
    }
}
