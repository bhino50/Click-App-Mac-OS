import Foundation
import ServiceManagement
import os

/// Thin wrapper around `SMAppService.mainApp` that hides the
/// throws + version checking dance.
enum LaunchAtLogin {
    private static let log = Logger(subsystem: "brandon.Click", category: "loginitem")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns `nil` on success, or a short human-readable reason when
    /// registering/unregistering failed (running from a non-canonical path,
    /// quarantined zip, etc.) so callers can surface it in the UI.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return nil
        } catch {
            log.error("Launch-at-login toggle failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }
}
