import SwiftUI

/// Grid of pack tiles. Highlights the currently selected pack and lets the
/// user click another to load it.
struct PackPickerView: View {
    let coordinator: AppCoordinator

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(coordinator.availablePacks) { handle in
                Button {
                    Task { await coordinator.selectPack(handle: handle) }
                } label: {
                    PackTile(
                        handle: handle,
                        isSelected: coordinator.currentPack?.name == handle.name
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(handle.name)
                .accessibilityValue(
                    coordinator.currentPack?.name == handle.name
                        ? "\(subtitle(for: handle)), selected"
                        : subtitle(for: handle)
                )
                .accessibilityAddTraits(
                    coordinator.currentPack?.name == handle.name ? .isSelected : []
                )
            }
        }
    }

    private func subtitle(for handle: PackHandle) -> String {
        switch handle.kind {
        case .clickpack: return handle.author ?? "Native pack"
        case .mechvibesMulti: return "Mechvibes pack"
        case .mechvibesSingle: return "Mechvibes, sliced"
        }
    }
}

private struct PackTile: View {
    let handle: PackHandle
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(
                        colors: tileGradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                Image(systemName: kindIcon)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(height: 92)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            )

            Text(handle.name)
                .font(.headline)
                .lineLimit(1)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.tertiary)
        )
    }

    private var subtitle: String {
        switch handle.kind {
        case .clickpack: return handle.author ?? "Native pack"
        case .mechvibesMulti: return "Mechvibes pack"
        case .mechvibesSingle: return "Mechvibes (sliced)"
        }
    }

    private var kindIcon: String {
        switch handle.kind {
        case .clickpack: "keyboard.fill"
        case .mechvibesMulti, .mechvibesSingle: "waveform"
        }
    }

    private var tileGradient: [Color] {
        // Deterministic across launches (String.hashValue is randomized per
        // process) and crash-free (avoid abs(Int.min) trap by using .magnitude).
        let seed = handle.name.unicodeScalars.reduce(into: UInt(0)) { $0 &+= UInt($1.value) }
        let hue = Double(seed % 360) / 360.0
        return [
            Color(hue: hue, saturation: 0.55, brightness: 0.55),
            Color(hue: hue, saturation: 0.85, brightness: 0.32)
        ]
    }
}
