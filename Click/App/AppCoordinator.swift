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
    @ObservationIgnored
    private(set) lazy var feedbackController = KeyFeedbackController(coordinator: self)

    private(set) var currentPack: SoundPack?
    private(set) var availablePacks: [PackHandle] = []
    private(set) var lastPressedKey: Int64?
    private(set) var lastPressAt: Date?
    private(set) var loadError: String?

    /// Set to `true` when accessibility permission is missing. Views observe
    /// this to surface the onboarding window.
    var needsOnboarding: Bool = false
    var shouldShowWelcomeGuide = false

    private var eventTap: KeyEventTap?
    private var eventConsumeTask: Task<Void, Never>?
    private var permissionsPollTask: Task<Void, Never>?
    private var folderWatchTask: Task<Void, Never>?
    private var lastKeystrokeMach: UInt64 = 0
    private var didBootstrap = false

    init() {
        self.settings = SettingsStore()
        self.permissions = PermissionsManager()
        self.packLoader = SoundPackLoader()
        self.audio = AudioEngine()
        self.folderWatcher = PackFolderWatcher(url: SoundPackLoader.userPacksDirectory)
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
        await ensurePermissionsAndStartTap()
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
            currentPack = pack
            await audio.installPack(pack)
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
        // Don't fire macOS's native "wants accessibility access" prompt here.
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
            Self.log.error("Failed to start event tap (AXIsProcessTrusted=\(self.permissions.isTrusted, privacy: .public))")
            return
        }
        Self.log.notice("Event tap installed; trust=\(self.permissions.isTrusted, privacy: .public)")
        eventTap = tap
        eventConsumeTask?.cancel()
        eventConsumeTask = Task { @MainActor [weak self] in
            for await event in stream {
                self?.handle(event: event)
            }
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
    /// global event tap is granted accessibility permission. Uses the default
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
