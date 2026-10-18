import SwiftUI

/// The secondary pill used for every small action. The hover fill is
/// translucent so it reads on tinted cards too.
struct QuietButtonStyle: ButtonStyle {
    static let fontSize: CGFloat = 13
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 9

    @Environment(\.theme) private var theme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Self.fontSize, weight: .medium))
            .foregroundStyle(hovering ? theme.text : theme.text2)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .background(
                Capsule().fill(theme.text.opacity(hovering ? 0.07 : 0))
                    .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
            .onHover { hovering = $0 }
    }
}
