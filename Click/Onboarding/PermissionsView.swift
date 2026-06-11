import AppKit
import SwiftUI

/// First-run onboarding. Walks the user through granting Input Monitoring access
/// and live-updates as soon as macOS flips the trust bit.
struct PermissionsView: View {
    @Bindable var coordinator: AppCoordinator
    @Environment(\.dismissWindow) private var dismissWindow

    init(coordinator: AppCoordinator) {
        self._coordinator = Bindable(coordinator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(systemName: "keyboard.macwindow")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Click").font(.title).bold()
                    Text("Mechanical keyboard sounds, the way you like them.")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("Click lives in the menu bar only — look for the keyboard icon near the clock. No Dock icon.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("To play sounds as you type, Click needs **Input Monitoring** access. Keystrokes are never stored or transmitted.")
                .font(.body)

            stepRow(
                index: 1,
                title: "Open System Settings",
                detail: "We'll deep-link you to Privacy & Security → Input Monitoring.")
            stepRow(
                index: 2,
                title: "Enable Click",
                detail: "Toggle the switch next to “Click” in the list.")
            stepRow(
                index: 3,
                title: "Come back here",
                detail: "Click flips on as soon as macOS grants permission.")

            HStack {
                Button {
                    // Register Click in the TCC list, then deep-link straight
                    // to the Input Monitoring pane.
                    coordinator.permissions.requestPrompt()
                    coordinator.permissions.openSystemSettings()
                } label: {
                    Label("Open System Settings", systemImage: "arrow.up.right.square")
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Spacer()

                statusBadge
            }

            #if !MAS_BUILD
            // Direct-download builds only: Gatekeeper quarantine guidance does
            // not apply to App Store installs, and store builds must not
            // reference the website distribution (App Review guideline 2.3.10).
            Text("Blocked on first launch? See **Install First — Read Me.txt** in the download DMG for the one-time Gatekeeper steps.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif

            if coordinator.permissions.isTrusted {
                Button("Done") {
                    dismissWindow(id: "onboarding")
                }
                .controlSize(.large)
                .tint(.green)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await coordinator.ensurePermissionsAndStartTap()
        }
    }

    private func stepRow(index: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(.tint.opacity(0.15)).frame(width: 28, height: 28)
                Text("\(index)").font(.headline).foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if coordinator.permissions.isTrusted {
            Label("Input Monitoring on", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } else {
            Label("Waiting for permission…", systemImage: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
    }
}
