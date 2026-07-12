import Foundation
import Observation
import os

/// All user-facing preferences. Backed by `UserDefaults` (non-sensitive only).
/// SwiftUI binds to its `@Observable` properties; mutations write through to
/// defaults immediately.
@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }
    /// `0.0...1.0`
    var volume: Double {
        didSet { defaults.set(volume, forKey: Keys.volume) }
    }
    var selectedPackName: String? {
        didSet { defaults.set(selectedPackName, forKey: Keys.selectedPackName) }
    }
    var launchAtLogin: Bool {
        didSet {
            LaunchAtLogin.set(launchAtLogin)
            // SMAppService is the source of truth — if `set` failed (running
            // from a non-canonical path, quarantined zip, etc.) reconcile the
            // UI/UserDefaults back to reality.
            let actual = LaunchAtLogin.isEnabled
            defaults.set(actual, forKey: Keys.launchAtLogin)
            if actual != launchAtLogin {
                launchAtLogin = actual
            }
        }
    }
    var velocitySensitive: Bool {
        didSet { defaults.set(velocitySensitive, forKey: Keys.velocitySensitive) }
    }
    var visualFeedback: Bool {
        didSet { defaults.set(visualFeedback, forKey: Keys.visualFeedback) }
    }
    /// Bundle identifiers where Click should stay quiet (e.g. games, recording apps).
    var mutedBundleIDs: [String] {
        didSet { defaults.set(mutedBundleIDs, forKey: Keys.mutedBundleIDs) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.object(forKey: Keys.isEnabled) as? Bool ?? true
        self.volume = defaults.object(forKey: Keys.volume) as? Double ?? 0.7
        self.selectedPackName = defaults.string(forKey: Keys.selectedPackName)
        // Read the live SMAppService status, not UserDefaults — the user could
        // have toggled this in System Settings while we were closed and the
        // bool would otherwise drift out of sync.
        self.launchAtLogin = LaunchAtLogin.isEnabled
        self.velocitySensitive = defaults.object(forKey: Keys.velocitySensitive) as? Bool ?? true
        self.visualFeedback = defaults.bool(forKey: Keys.visualFeedback)
        self.mutedBundleIDs = defaults.stringArray(forKey: Keys.mutedBundleIDs) ?? []
        Logger(subsystem: "brandon.Click", category: "settings").notice("SettingsStore initialized")
    }

    /// Returns `true` if the frontmost app is allowed to make Click play sounds.
    func allowedAppPolicyMatches(frontmostBundleID: String?) -> Bool {
        guard let id = frontmostBundleID else { return true }
        return !mutedBundleIDs.contains(id)
    }

    private enum Keys {
        static let isEnabled = "click.isEnabled"
        static let volume = "click.volume"
        static let selectedPackName = "click.selectedPack"
        static let launchAtLogin = "click.launchAtLogin"
        static let velocitySensitive = "click.velocitySensitive"
        static let visualFeedback = "click.visualFeedback"
        static let mutedBundleIDs = "click.mutedBundleIDs"
    }
}
