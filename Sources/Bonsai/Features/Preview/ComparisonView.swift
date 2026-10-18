import PDFKit
import SwiftUI

/// The original and the compressed page under a draggable divider.
struct ComparisonView: View {
    @Environment(\.theme) private var theme
    let item: PDFItem

    @State private var page = 0
    @State private var fraction: CGFloat = 0.5
    @State private var original: NSImage?
    @State private var compressed: NSImage?
    @State private var loading = true

    private var result: CompressionResult? { item.result }

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
        .task(id: "\(page)-\(result?.outputURL.lastPathComponent ?? "")") { await render() }
    }

    // MARK: Header

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
        .padding(.horizontal, Layout.inset)
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

    // MARK: Comparison

    private var comparison: some View {
        GeometryReader { geometry in
            ZStack {
                theme.wellBG
                if let original, let compressed {
                    ZStack {
                        pageImage(compressed, in: geometry.size)
                        pageImage(original, in: geometry.size)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: geometry.size.width * fraction)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
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
        }
        .animation(.easeOut(duration: 0.25), value: original != nil)
    }

    private func pageImage(_ image: NSImage, in size: CGSize) -> some View {
        Image(nsImage: image)
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
                                      : AnyShapeStyle(.ultraThinMaterial))
            )
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: visible)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(item.resultPreset?.title ?? "")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent)
            Spacer()
            if let result {
                Text(result.keptOriginal
                     ? "No meaningful savings, the original is kept as-is"
                     : "Saved \(Format.size(result.savedBytes)) (-\(Format.percent(result.savedFraction)))")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(result.keptOriginal ? theme.text2 : theme.success)
            }
        }
        .padding(.horizontal, Layout.inset)
        .padding(.vertical, 13)
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
                let scale = min(4, 2400 / max(bounds.width, 1))
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
