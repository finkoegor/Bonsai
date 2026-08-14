import SwiftUI

// MARK: - Layout tokens
// One spacing grid for the whole window: every container (side panel insets,
// drop-zone frame, list header, grid padding) sits on the same 24pt rhythm,
// and both header rows share one 40pt-tall axis.

enum Layout {
    static let inset: CGFloat = 24
    static let headerHeight: CGFloat = 40
}

// MARK: - Hover tracking

struct HoverScale: ViewModifier {
    var scale: CGFloat = 1.02
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Primary CTA button style

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

// MARK: - Quiet secondary button
// Single size token for every secondary pill (Clear all, Show in Finder, Clear…).
// Hover fill is translucent so it works on any backdrop, including tinted cards.

enum QuietButtonToken {
    static let fontSize: CGFloat = 13
    static let hPadding: CGFloat = 14
    static let vPadding: CGFloat = 9
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: QuietButtonToken.fontSize, weight: .medium))
            .foregroundStyle(hovering ? theme.text : theme.text2)
            .padding(.horizontal, QuietButtonToken.hPadding)
            .padding(.vertical, QuietButtonToken.vPadding)
            .background(
                Capsule().fill(theme.text.opacity(hovering ? 0.07 : 0))
                    .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Circular icon button (close, theme toggle…)

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

// MARK: - Indeterminate spinner ring

struct SpinnerRing: View {
    @Environment(\.theme) private var theme
    var size: CGFloat = 22
    var line: CGFloat = 2.5
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1)
            .stroke(AngularGradient(colors: [theme.accent.opacity(0), theme.accent],
                                    center: .center),
                    style: StrokeStyle(lineWidth: line, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    spin = true
                }
            }
    }
}

// MARK: - Shimmer placeholder (for totals while estimating)

struct Shimmer: View {
    @Environment(\.theme) private var theme
    var width: CGFloat = 70
    var height: CGFloat = 14
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(theme.text3.opacity(0.25))
            .frame(width: width, height: height)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, theme.surface.opacity(0.9), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.7)
                        .offset(x: phase * geo.size.width * 1.6)
                }
                .allowsHitTesting(false)
            )
            .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// MARK: - Animated check mark (draw-on)

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
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.09,
                                                  lineCap: .round, lineJoin: .round))
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

    struct CheckShape: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY - rect.height * 0.1))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
            return p
        }
    }
}

// MARK: - Small colored badge
// Fixed height so badge and its shimmer placeholder occupy identical space
// and cards never jump when an estimate lands.

enum BadgeToken {
    static let height: CGFloat = 22
}

struct Badge: View {
    let text: String
    let fg: Color
    let bg: Color
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Icon(name: icon, size: 10) }
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 8)
        .frame(height: BadgeToken.height)
        .background(Capsule().fill(bg))
    }
}
