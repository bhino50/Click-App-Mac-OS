import SwiftUI

/// Transient overlay shown at the bottom of the screen when the user enables
/// "Show pressed-key overlay". Reads `lastPressedKey` from the coordinator
/// and fades out after a short delay.
struct KeyFeedbackOverlay: View {
    @Bindable var coordinator: AppCoordinator
    @State private var visible = false
    @State private var hideTask: Task<Void, Never>?

    init(coordinator: AppCoordinator) {
        self._coordinator = Bindable(coordinator)
    }

    var body: some View {
        Group {
            if coordinator.settings.visualFeedback, visible, let key = coordinator.lastPressedKey {
                Text(label(for: key))
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.black.opacity(0.55))
                    )
                    .foregroundStyle(.white)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: coordinator.lastPressAt) { _, _ in
            guard coordinator.settings.visualFeedback else { return }
            visible = true
            // Cancel any in-flight hide so fast typing doesn't make older
            // tasks fire `visible = false` over a newer keystroke.
            hideTask?.cancel()
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.18)) { visible = false }
            }
        }
    }

    private func label(for keyCode: Int64) -> String {
        if let name = KeyLabels.mac[Int(keyCode)] { return name }
        return "·"
    }
}

private enum KeyLabels {
    static let mac: [Int: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F",
        0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L",
        0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5",
        0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9", 0x1D: "0",
        0x31: "␣", 0x24: "↩", 0x33: "⌫", 0x30: "⇥", 0x35: "⎋",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑"
    ]
}
