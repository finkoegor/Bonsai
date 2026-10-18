import SwiftUI

/// A check mark that draws itself in.
struct AnimatedCheck: View {
    var color: Color
    var size: CGFloat = 44
    @State private var drawn = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.14))
            Circle()
                .strokeBorder(color.opacity(0.35), lineWidth: 1.5)
            CheckShape()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round, lineJoin: .round))
                .padding(size * 0.28)
        }
        .frame(width: size, height: size)
        .scaleEffect(drawn ? 1 : 0.6)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.65).delay(0.05)) {
                drawn = true
            }
        }
    }

    private struct CheckShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY - rect.height * 0.1))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
            return path
        }
    }
}
