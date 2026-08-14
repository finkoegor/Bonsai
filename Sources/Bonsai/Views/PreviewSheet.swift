import SwiftUI
import PDFKit

/// Hosts the comparison in its own window; resolves the item by id so a
/// removed file simply closes the window instead of dangling.
struct PreviewWindow: View {
    @Environment(AppState.self) private var state
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let itemID: UUID?

    var body: some View {
        if let item = state.items.first(where: { $0.id == itemID }) {
            PreviewSheet(item: item)
                .navigationTitle(item.name)
        } else {
            Color.clear
                .frame(minWidth: 400, minHeight: 300)
                .background(theme.bg)
                .onAppear { dismiss() }
        }
    }
}

/// Before/after comparison with a draggable divider — the honest way to judge
/// what a preset does to your pages before committing.
struct PreviewSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let item: PDFItem

    @State private var page = 0
    @State private var fraction: CGFloat = 0.5
    @State private var original: NSImage?
    @State private var compressed: NSImage?
    @State private var loading = true

    private var estimate: CompressionResult? { item.estimate(for: state.preset) }

    var body: some View {
        VStack(spacing: 0) {
            header
            comparison
            footer
        }
        .frame(minWidth: 700, idealWidth: 940, maxWidth: .infinity,
               minHeight: 520, idealHeight: 660, maxHeight: .infinity)
        .focusEffectDisabled()
        .background(theme.bg)
        .task(id: "\(page)-\(state.preset.rawValue)") { await render() }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            Text(item.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if item.pageCount > 1 { pager }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    private var pager: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { page = max(0, page - 1) }
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(CircleIconButtonStyle(diameter: 24))
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
            .disabled(page >= item.pageCount - 1)
            .opacity(page >= item.pageCount - 1 ? 0.35 : 1)
        }
    }

    // MARK: comparison area

    private var comparison: some View {
        GeometryReader { geo in
            ZStack {
                theme.wellBG
                if let original, let compressed {
                    ZStack {
                        // After (right side, full)
                        pageImage(compressed, in: geo.size)
                        // Before (left of the divider)
                        pageImage(original, in: geo.size)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: geo.size.width * fraction)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        divider(in: geo.size)
                        labels(in: geo.size)
                    }
                    .transition(.opacity)
                } else if loading {
                    SpinnerRing(size: 30, line: 3)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        withAnimation(.interactiveSpring) {
                            fraction = min(0.98, max(0.02, v.location.x / geo.size.width))
                        }
                    }
            )
        }
        .animation(.easeOut(duration: 0.25), value: original != nil)
    }

    private func pageImage(_ img: NSImage, in size: CGSize) -> some View {
        Image(nsImage: img)
            .resizable()
            .scaledToFit()
            .padding(24)
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
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
                tag("Original · \(Format.size(item.inputBytes))", visible: fraction > 0.18)
                Spacer()
                if let est = estimate {
                    tag("Compressed · \(Format.size(est.outputBytes))",
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
                                      : AnyShapeStyle(.ultraThinMaterial))
            )
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: visible)
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Text(state.preset.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent)
            Spacer()
            if let est = estimate {
                Text(est.keptOriginal
                     ? "No meaningful savings, the original is kept as-is"
                     : "Saves \(Format.size(est.savedBytes)) (−\(Format.percent(est.savedFraction)))")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(est.keptOriginal ? theme.text2 : theme.success)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    // MARK: rendering

    private func render() async {
        loading = true
        let pageIndex = page
        let srcURL = item.sourceURL   // snapshot: intact even after Replace original
        let dstURL = estimate?.outputURL
        let pair: (NSImage?, NSImage?) = await Task.detached(priority: .userInitiated) {
            func renderPage(_ url: URL?) -> NSImage? {
                guard let url, let doc = PDFDocument(url: url),
                      let p = doc.page(at: pageIndex) else { return nil }
                let bounds = p.bounds(for: .cropBox)
                let scale = min(3, 1600 / max(bounds.width, 1))
                return p.thumbnail(of: CGSize(width: bounds.width * scale,
                                              height: bounds.height * scale), for: .cropBox)
            }
            return (renderPage(srcURL), renderPage(dstURL))
        }.value
        if Task.isCancelled { return }
        withAnimation(.easeOut(duration: 0.25)) {
            original = pair.0
            compressed = pair.1
            loading = false
        }
    }
}
