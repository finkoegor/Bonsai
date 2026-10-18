import SwiftUI

struct SpinnerRing: View {
    @Environment(\.theme) private var theme
    var size: CGFloat = 22
    var line: CGFloat = 2.5
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1)
            .stroke(AngularGradient(colors: [theme.accent.opacity(0), theme.accent], center: .center),
                    style: StrokeStyle(lineWidth: line, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }
}
