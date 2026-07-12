import AppKit
import SwiftUI

/// Compact panel shown when the user clicks the menu bar icon. Uses
/// `.menuBarExtraStyle(.window)` so it can render real SwiftUI controls
/// (sliders, custom layouts) instead of being limited to NSMenu items.
struct MenuBarView: View {
    @Bindable var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    init(coordinator: AppCoordinator) {
        self._coordinator = Bindable(coordinator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            volumeSection
            packSection
            packErrorSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 280)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Click").font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Play typing sounds", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityValue(coordinator.settings.isEnabled ? "On" : "Off")
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { coordinator.settings.isEnabled },
            set: { enabled in Task { await coordinator.setEnabled(enabled) } }
        )
    }

    private var statusText: String {
        if coordinator.inputMonitoringLost {
            return "Input Monitoring access lost"
        }
        if !coordinator.permissions.isTrusted {
            return "Input Monitoring access needed"
        }
        return coordinator.settings.isEnabled ? "On" : "Off"
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $coordinator.settings.volume, in: 0...1)
                    .accessibilityLabel("Volume")
                    .accessibilityValue("\(Int(coordinator.settings.volume * 100)) percent")
                Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.secondary)
                Text("\(Int(coordinator.settings.volume * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            Button {
                Task { await coordinator.playTestSound() }
            } label: {
                Label("Test sound", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var packSection: some View {
        if coordinator.availablePacks.isEmpty {
            Text("No sound packs installed")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sound pack").font(.caption).foregroundStyle(.secondary)
                Picker("Sound pack", selection: Binding(
                    get: { coordinator.currentPack?.name ?? coordinator.availablePacks.first?.name ?? "" },
                    set: { name in
                        Task { await coordinator.selectPack(named: name) }
                    }
                )) {
                    ForEach(coordinator.availablePacks) { handle in
                        Text(handle.name).tag(handle.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    /// Surfaces pack load/import failures without requiring the Settings
    /// window to be open. Cleared by the coordinator on the next successful
    /// pack load.
    @ViewBuilder
    private var packErrorSection: some View {
        if let error = coordinator.loadError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(4)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if coordinator.inputMonitoringLost {
                Button {
                    coordinator.permissions.openSystemSettings()
                } label: {
                    Label("Input Monitoring access lost - open System Settings",
                          systemImage: "exclamationmark.triangle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .tint(.red)
            } else if !coordinator.permissions.isTrusted {
                Button {
                    openWindow(id: "onboarding")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Grant Input Monitoring…", systemImage: "exclamationmark.shield")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .tint(.orange)
            }
            Button {
                coordinator.openWelcomeGuide()
            } label: {
                Label("Setup Guide…", systemImage: "questionmark.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings…", systemImage: "gear")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",")

            #if !MAS_BUILD
            updateSection
            #endif

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Click", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
        }
    }

    /// One-line outcome of the most recent update check, shown under the
    /// "Check for Updates" button. Hidden until a check has run.
    #if !MAS_BUILD
    private var updateSection: some View {
        Group {
            Button {
                Task { await coordinator.updateChecker.checkNow() }
            } label: {
                Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .disabled(coordinator.updateChecker.status == .checking)
            if let feedback = updateStatusText {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var updateStatusText: String? {
        switch coordinator.updateChecker.status {
        case .idle:
            return nil
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            return "Click is up to date."
        case .updateAvailable(let version):
            return "Version \(version) is available."
        case .failed:
            return "Couldn't check for updates."
        }
    }
    #endif
}
