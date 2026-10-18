import SwiftUI

struct EmptyDropState: View {
    @Environment(AppState.self) private var state
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Text("Drop your PDFs here")
                .font(.system(size: 22, weight: .semibold))
                .kerning(-0.3)
                .foregroundStyle(theme.text)
            Text("Compress one file or a whole batch at once")
                .font(.system(size: 13))
                .foregroundStyle(theme.text2)

            Button {
                BonsaiApp.openPanel(into: state)
            } label: {
                HStack(spacing: 7) {
                    Icon(name: "folder-open", size: 14)
                    Text("Browse Files")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(theme.accentSoft)
                        .overlay(Capsule().strokeBorder(theme.accent.opacity(0.35), lineWidth: 1))
                )
            }
            .buttonStyle(.plain)
            .modifier(HoverScale(scale: 1.04))
            .padding(.top, 16)

            HStack(spacing: 5) {
                Icon(name: "check-circle", size: 11)
                Text("100% local. Files never leave your Mac")
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.text3)
            .padding(.top, 22)
        }
    }
}
