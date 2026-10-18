import SwiftUI

struct PresetCard: View {
    @Environment(AppState.self) private var state
    @Environment(\.theme) private var theme
    let preset: Preset
    @State private var hovering = false

    private var selected: Bool { state.preset == preset }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) { state.preset = preset }
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(selected ? theme.accent : theme.borderStrong, lineWidth: selected ? 6 : 1.5)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? theme.accent : theme.text)
                        .lineLimit(1)
                    Text(preset.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text2)
                }
                Spacer(minLength: 0)
                Icon(name: preset.icon, size: 16)
                    .foregroundStyle(selected ? theme.accent : theme.text3)
                    .scaleEffect(selected ? 1.1 : 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? theme.accentSoft : (hovering ? theme.surface2 : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? theme.accent : theme.border, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(state.isCompressing)
        .scaleEffect(hovering && !selected ? 1.015 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: hovering)
        .animation(.spring(response: 0.32, dampingFraction: 0.75), value: selected)
        .onHover { hovering = $0 }
    }
}
