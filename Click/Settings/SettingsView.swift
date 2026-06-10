import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var importInFlight = false

    init(coordinator: AppCoordinator) {
        self._coordinator = Bindable(coordinator)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                masterSection
                packSection
                feelSection
                appsSection
                aboutSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Click")
                    .font(.largeTitle).bold()
                Text("Mechanical keyboard sounds as you type.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            permissionsBadge
        }
    }

    @ViewBuilder
    private var permissionsBadge: some View {
        if coordinator.permissions.isTrusted {
            Label("Accessibility on", systemImage: "checkmark.seal.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
        } else {
            Button("Grant Accessibility…") {
                coordinator.permissions.openSystemSettings()
            }
            .controlSize(.large)
            .tint(.orange)
        }
    }

    private var masterSection: some View {
        SettingsCard(title: "Sound") {
            Toggle("Play sounds while typing", isOn: $coordinator.settings.isEnabled)
                .toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 4) {
                Text("Volume")
                Slider(value: $coordinator.settings.volume, in: 0...1)
                    .controlSize(.large)
            }
        }
    }

    private var packSection: some View {
        SettingsCard(title: "Sound pack") {
            if coordinator.availablePacks.isEmpty {
                Text("No packs installed yet.")
                    .foregroundStyle(.secondary)
            } else {
                PackPickerView(coordinator: coordinator)
            }
            HStack(spacing: 12) {
                Button {
                    Task { await importPacks() }
                } label: {
                    Label("Import pack…", systemImage: "plus")
                }
                .disabled(importInFlight)

                Button {
                    NSWorkspace.shared.open(SoundPackLoader.userPacksDirectory)
                } label: {
                    Label("Reveal folder", systemImage: "folder")
                }

                if let error = coordinator.loadError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .padding(.top, 4)
        }
    }

    private var feelSection: some View {
        SettingsCard(title: "Feel") {
            Toggle("Velocity-sensitive (louder when typing fast)",
                   isOn: $coordinator.settings.velocitySensitive)
            Toggle("Show pressed-key overlay",
                   isOn: $coordinator.settings.visualFeedback)
            Toggle("Launch at login",
                   isOn: $coordinator.settings.launchAtLogin)
        }
    }

    private var appsSection: some View {
        SettingsCard(title: "Muted apps") {
            Text("Click stays quiet while these apps are frontmost. One bundle ID per line (e.g. `com.apple.dt.Xcode`).")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { coordinator.settings.mutedBundleIDs.joined(separator: "\n") },
                set: { coordinator.settings.mutedBundleIDs = $0
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                }
            ))
            .font(.system(.callout, design: .monospaced))
            .frame(minHeight: 80)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.3))
            )
        }
    }

    private var aboutSection: some View {
        SettingsCard(title: "About") {
            Text("Click v\(Bundle.main.shortVersion) · MIT licensed · Mechvibes-compatible")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func importPacks() async {
        importInFlight = true
        defer { importInFlight = false }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose .clickpack folders or Mechvibes pack folders"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            await coordinator.packLoader.importPack(at: url)
        }
        await coordinator.refreshPacks()
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    await coordinator.packLoader.importPack(at: url)
                    await coordinator.refreshPacks()
                }
            }
            handled = true
        }
        return handled
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.secondary)
        )
    }
}

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}
