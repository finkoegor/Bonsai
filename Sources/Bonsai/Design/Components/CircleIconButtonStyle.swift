import SwiftUI

struct CircleIconButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    var diameter: CGFloat = 30
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? theme.text : theme.text2)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(hovering ? theme.surface2 : theme.surface.opacity(0.001)))
            .overlay(Circle().strokeBorder(theme.border, lineWidth: hovering ? 1 : 0))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}
