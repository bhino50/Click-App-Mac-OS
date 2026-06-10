import AppKit
import SwiftUI

/// Opens the welcome window automatically when Accessibility is missing.
struct OnboardingPresenter: View {
    @Bindable var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { presentIfNeeded() }
            .onChange(of: coordinator.needsOnboarding) { _, needs in
                if needs { presentIfNeeded() }
            }
            .onChange(of: coordinator.shouldShowWelcomeGuide) { _, shouldShow in
                if shouldShow { presentWelcomeGuide() }
            }
    }

    private func presentIfNeeded() {
        guard coordinator.needsOnboarding else { return }
        presentWelcomeGuide()
    }

    private func presentWelcomeGuide() {
        openWindow(id: "onboarding")
        NSApp.activate(ignoringOtherApps: true)
        coordinator.shouldShowWelcomeGuide = false
    }
}
