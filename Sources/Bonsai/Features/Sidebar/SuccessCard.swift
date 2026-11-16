import SwiftUI

struct SuccessCard: View {
    @Environment(AppState.self) private var state
    @Environment(\.theme) private var theme
    let summary: ListSummary

    var body: some View {
        VStack(spacing: 12) {
            AnimatedCheck(color: theme.success, size: 46)
            Text(summary.savedBytes > 0
                 ? "Saved \(Format.size(summary.savedBytes)) (-\(Format.percent(summary.savedFraction)))"
                 : "Already optimized")
                .font(.system(size: 16, weight: .bold))
                .kerning(-0.2)
                .monospacedDigit()
                .foregroundStyle(theme.text)
            Text("\(summary.files) \(summary.files == 1 ? "file" : "files"), \(Format.size(summary.inputBytes)) to \(Format.size(summary.outputBytes))")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(theme.text2)

            HStack(spacing: 8) {
                Button {
                    state.revealSaved()
                } label: {
                    HStack(spacing: 5) {
                        Icon(name: "folder", size: 12)
                        Text("Show in Finder")
                    }
                }
                .buttonStyle(QuietButtonStyle())
                Button("Clear") {
                    state.clearAll()
                }
                .buttonStyle(QuietButtonStyle())
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.successSoft.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.success.opacity(0.25), lineWidth: 1))
        )
    }
}
