import PDFKit
import SwiftUI

/// The original and the compressed page under a draggable divider. The
/// window's title bar carries the file name. A page shows whole, or across
/// the width of the window with the rest of it reached by scrolling.
struct ComparisonView: View {
    @Environment(AppState.self) private var state
    @Environment(\.theme) private var theme
    let item: PDFItem

    @State private var page = 0
    @State private var fraction: CGFloat = 0.5
    @State private var original: NSImage?
    @State private var compressed: NSImage?
    @State private var loading = true
    /// Nil leaves the choice to the page's shape.
    @State private var fillsWidth: Bool?
    @State private var viewport = CGSize.zero

    private static let inset: CGFloat = 24
    /// A whole page narrower than this share of the window is too small to
    /// judge, so it starts out across the width.
    private static let narrowestWholePage = 1.0 / 3

    private var version: SavedVersion? { item.shownVersion(for: state.preset) }
    private var result: CompressionResult? { version?.result }

    var body: some View {
        VStack(spacing: 0) {
            comparison
            footer
        }
        .frame(minWidth: 700, idealWidth: 940, maxWidth: .infinity,
               minHeight: 520, idealHeight: 660, maxHeight: .infinity)
        .focusEffectDisabled()
        .background(theme.bg)
        .task(id: "\(page)-\(result?.outputURL.lastPathComponent ?? "")") { await render() }
    }

    // MARK: Pages

    private var pager: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { page = max(0, page - 1) }
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(CircleIconButtonStyle(diameter: 24))
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(page == 0)
            .opacity(page == 0 ? 0.35 : 1)

            Text("\(page + 1) / \(item.pageCount)")
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(theme.text2)
                .frame(minWidth: 46)
                .contentTransition(.numericText())

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { page = min(item.pageCount - 1, page + 1) }
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(CircleIconButtonStyle(diameter: 24))
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(page >= item.pageCount - 1)
            .opacity(page >= item.pageCount - 1 ? 0.35 : 1)
        }
    }

    // MARK: Comparison

    private var comparison: some View {
        GeometryReader { geometry in
            ZStack {
                theme.wellBG
                if let original, let compressed {
                    let size = pageSize(in: geometry.size)
                    let area = CGSize(width: geometry.size.width,
                                      height: max(geometry.size.height, size.height + Self.inset * 2))
                    ZStack {
                        ScrollView(.vertical) {
                            ZStack {
                                pageImage(compressed, size: size, in: area)
                                pageImage(original, size: size, in: area)
                                    .mask(alignment: .leading) {
                                        Rectangle().frame(width: area.width * fraction)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                            }
                        }
                        .id(page)
                        divider(in: geometry.size)
                        labels(in: geometry.size)
                    }
                    .transition(.opacity)
                } else if loading {
                    SpinnerRing(size: 30, line: 3)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        withAnimation(.interactiveSpring) {
                            fraction = min(0.98, max(0.02, drag.location.x / geometry.size.width))
                        }
                    }
            )
            .onAppear { viewport = geometry.size }
            .onChange(of: geometry.size) { _, size in viewport = size }
        }
        .animation(.easeOut(duration: 0.25), value: original != nil)
    }

    private func pageImage(_ image: NSImage, size: CGSize, in area: CGSize) -> some View {
        Image(nsImage: image)
            .resizable()
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            .frame(width: area.width, height: area.height)
    }

    // MARK: Fit

    /// The widths the page can take in `viewport`: shown whole, and across.
    private func pageWidths(in viewport: CGSize) -> (whole: CGFloat, across: CGFloat)? {
        guard let image = compressed ?? original, image.size.width > 0, image.size.height > 0 else { return nil }
        let width = max(1, viewport.width - Self.inset * 2)
        let height = max(1, viewport.height - Self.inset * 2)
        return (min(width, height * image.size.width / image.size.height), width)
    }

    private func goesAcross(_ widths: (whole: CGFloat, across: CGFloat)) -> Bool {
        fillsWidth ?? (widths.whole < widths.across * Self.narrowestWholePage)
    }

    private func pageSize(in viewport: CGSize) -> CGSize {
        guard let widths = pageWidths(in: viewport), let image = compressed ?? original else { return .zero }
        let width = goesAcross(widths) ? widths.across : widths.whole
        return CGSize(width: width, height: width * image.size.height / image.size.width)
    }

    /// Present only when the whole page leaves room at its sides, so the
    /// two fits differ.
    @ViewBuilder
    private var fitToggle: some View {
        if let widths = pageWidths(in: viewport), widths.whole < widths.across * 0.95 {
            let across = goesAcross(widths)
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { fillsWidth = !across }
            } label: {
                Image(systemName: across ? "arrow.down.right.and.arrow.up.left"
                                         : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(CircleIconButtonStyle(diameter: 24))
            .help(across ? "Show the whole page" : "Fit the page to the width")
        }
    }

    private func divider(in size: CGSize) -> some View {
        ZStack {
            Rectangle()
                .fill(theme.accent)
                .frame(width: 2)
                .shadow(color: .black.opacity(0.3), radius: 3)
            Circle()
                .fill(theme.accent)
                .frame(width: 30, height: 30)
                .overlay(
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white)
                )
                .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
        }
        .position(x: size.width * fraction, y: size.height / 2)
    }

    private func labels(in size: CGSize) -> some View {
        ZStack(alignment: .top) {
            HStack {
                tag("Original, \(Format.size(item.inputBytes))", visible: fraction > 0.18)
                Spacer()
                if let result {
                    tag("Compressed, \(Format.size(result.outputBytes))",
                        visible: fraction < 0.82, accent: true)
                }
            }
            .padding(14)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .allowsHitTesting(false)
    }

    private func tag(_ text: String, visible: Bool, accent: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(accent ? Color.white : theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(accent ? AnyShapeStyle(theme.accentGradient)
                                      : AnyShapeStyle(theme.surface.opacity(0.94)))
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
            )
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: visible)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(version?.preset.title ?? "")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                if item.pageCount > 1 { pager }
                fitToggle
            }
            Group {
                if let result {
                    Text(result.keptOriginal
                         ? "Already optimized, the original is kept"
                         : "Saved \(Format.size(result.savedBytes)) (-\(Format.percent(result.savedFraction)))")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(result.keptOriginal ? theme.text2 : theme.success)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Layout.inset)
        .padding(.vertical, 9)
        .background(theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    // MARK: Rendering

    /// Reads the original from the item's snapshot, which survives
    /// "Replace original".
    private func render() async {
        loading = true
        let index = page
        let before = item.sourceURL
        let after = result?.outputURL
        let pair: (NSImage?, NSImage?) = await Task.detached(priority: .userInitiated) {
            func render(_ url: URL?) -> NSImage? {
                guard let url, let document = PDFDocument(url: url), let page = document.page(at: index) else { return nil }
                let bounds = page.bounds(for: .cropBox)
                // Sharp across a wide window, within a bitmap of 24 megapixels.
                let scale = min(4, 2400 / max(bounds.width, 1),
                                (24_000_000 / max(bounds.width * bounds.height, 1)).squareRoot())
                return page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .cropBox)
            }
            return (render(before), render(after))
        }.value
        if Task.isCancelled { return }
        withAnimation(.easeOut(duration: 0.25)) {
            original = pair.0
            compressed = pair.1
            loading = false
        }
    }
}
