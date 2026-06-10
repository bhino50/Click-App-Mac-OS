import AppKit
import SwiftUI

/// Owns the `AppCoordinator` and bootstraps it at launch time, before any
/// window appears.
///
/// MenuBarExtra content is materialized lazily (only when the user clicks the
/// menu bar icon), and the app starts with no windows visible, so we can't
/// rely on a SwiftUI `.task` modifier to start the audio engine and event tap.
/// AppKit's `applicationDidFinishLaunching` is the earliest reliable hook.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await coordinator.bootstrap() }
    }
}
