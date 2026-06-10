import AppKit
import ApplicationServices
import Observation

/// Tracks whether the app is trusted for Accessibility (required to install a
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
        isTrusted = AXIsProcessTrusted()
    }

    /// Triggers macOS's "App wants accessibility access" prompt if the app is
    /// not yet trusted. Returns immediately with the current trust value.
    @discardableResult
    func requestPrompt() -> Bool {
        let key = "AXTrustedCheckOptionPrompt"
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        isTrusted = trusted
        return trusted
    }

    /// Deep link into System Settings → Privacy & Security → Accessibility.
    /// Built from a constant string, so construction cannot fail at runtime,
    /// but it is guarded at the call site rather than force-unwrapped.
    private static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )

    /// Opens System Settings → Privacy & Security → Accessibility.
    func openSystemSettings() {
        guard let url = Self.accessibilitySettingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
