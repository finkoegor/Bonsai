import SwiftUI

struct ThemeToggle: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            themeStore.toggle()
        } label: {
            ZStack {
                Icon(name: "sun", size: 15)
                    .opacity(theme.isNight ? 0 : 1)
                    .rotationEffect(.degrees(theme.isNight ? 90 : 0))
                    .scaleEffect(theme.isNight ? 0.4 : 1)
                Icon(name: "moon", size: 14)
                    .opacity(theme.isNight ? 1 : 0)
                    .rotationEffect(.degrees(theme.isNight ? 0 : -90))
                    .scaleEffect(theme.isNight ? 1 : 0.4)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: theme.isNight)
        }
        .buttonStyle(CircleIconButtonStyle(diameter: 30))
        .focusEffectDisabled()
        .help(theme.isNight ? "Switch to Day" : "Switch to Night")
    }
}
