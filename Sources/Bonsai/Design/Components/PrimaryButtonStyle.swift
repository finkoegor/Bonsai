import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.accentGradient)
                    .brightness(configuration.isPressed ? -0.06 : (hovering ? 0.05 : 0))
            )
            .shadow(color: theme.accent.opacity(isEnabled ? (hovering ? 0.45 : 0.28) : 0),
                    radius: hovering ? 16 : 10, y: 5)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: hovering)
            .onHover { hovering = $0 }
    }
}
