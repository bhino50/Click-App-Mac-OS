import SwiftUI

@main
struct ClickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(coordinator: appDelegate.coordinator)
            OnboardingPresenter(coordinator: appDelegate.coordinator)
        } label: {
            Image(systemName: appDelegate.coordinator.menuBarIconName)
        }
        .menuBarExtraStyle(.window)

        Window("Click Settings", id: "settings") {
            SettingsView(coordinator: appDelegate.coordinator)
                .frame(minWidth: 520, minHeight: 480)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Welcome to Click", id: "onboarding") {
            PermissionsView(coordinator: appDelegate.coordinator)
                .frame(width: 520, height: 500)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // The key-press overlay is hosted in a floating NSPanel managed by
        // `KeyFeedbackController` (see `App/KeyFeedbackController.swift`) —
        // a Window scene on macOS 14 can't be borderless / floating / click-through.
    }
}
