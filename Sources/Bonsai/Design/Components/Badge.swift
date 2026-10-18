import SwiftUI

struct Badge: View {
    /// Fixed so that an empty slot of the same height keeps cards from
    /// jumping when the badge appears.
    static let height: CGFloat = 22

    let text: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(height: Self.height)
            .background(Capsule().fill(background))
    }
}
