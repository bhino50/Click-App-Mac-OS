import AppKit
import CoreGraphics
import Observation

/// Tracks whether the app is trusted for Input Monitoring (required to install a
/// global `CGEventTap`). Re-check via `refresh()`; deep-link with `openSettings()`.
@MainActor
@Observable
final class PermissionsManager {
    private(set) var isTrusted: Bool = false

    init() {
        refresh()
    }

    /// Re-reads trust state without prompting. Cheap; safe to poll once a
    /// second while the onboarding window is visible.
    func refresh() {
        isTrusted = CGPreflightListenEventAccess()
    }

    /// Triggers macOS's Input Monitoring prompt if the app is
    /// not yet trusted. Returns immediately with the current trust value.
    @discardableResult
    func requestPrompt() -> Bool {
        let trusted = CGRequestListenEventAccess()
        isTrusted = trusted
        return trusted
    }

    /// Deep link into System Settings → Privacy & Security → Input Monitoring.
    /// Built from a constant string, so construction cannot fail at runtime,
    /// but it is guarded at the call site rather than force-unwrapped.
    private static let inputMonitoringSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    )

    /// Opens System Settings → Privacy & Security → Input Monitoring.
    func openSystemSettings() {
        guard let url = Self.inputMonitoringSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
