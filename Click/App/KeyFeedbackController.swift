import AppKit
import SwiftUI

/// Owns the floating NSPanel that hosts `KeyFeedbackOverlay`.
///
/// SwiftUI's `Window` scene is a plain `NSWindow` on macOS 14 — no floating
/// level, no transparent backdrop, no click-through. The `.plain` window style
/// and `.windowLevel(.floating)` modifier are macOS 15+, but Click targets 14,
/// so the overlay is wired up through AppKit instead.
@MainActor
final class KeyFeedbackController {
    private weak var coordinator: AppCoordinator?
    private var panel: NSPanel?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    /// Idempotent. Creates the panel on first call and shows it; the hosted
    /// view stays transparent until a keystroke arrives.
    func ensurePanel() {
        guard panel == nil, let coordinator else { return }

        let content = KeyFeedbackOverlay(coordinator: coordinator)
        let host = NSHostingController(rootView: content)
        host.view.frame = NSRect(x: 0, y: 0, width: 240, height: 96)

        let p = NSPanel(
            contentRect: host.view.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                .ignoresCycle, .fullScreenAuxiliary]
        p.contentViewController = host

        reposition(p)
        p.orderFrontRegardless()
        panel = p

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let p = self?.panel { self?.reposition(p) }
            }
        }
    }

    private func reposition(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let panelSize = panel.frame.size
        let visible = screen.visibleFrame
        let x = visible.midX - panelSize.width / 2
        let y = visible.minY + 96
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
