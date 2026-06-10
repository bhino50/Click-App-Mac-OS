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

    static func set(_ enabled: Bool) {
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
        } catch {
            log.error("Launch-at-login toggle failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
