import SwiftUI

struct FileGrid: View {
    @Environment(AppState.self) private var state
    @Environment(\.theme) private var theme
    let openPreview: (PDFItem) -> Void

    private let columns = [GridItem(.adaptive(minimum: 172, maximum: 220), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(state.items) { item in
                        FileCard(item: item, openPreview: openPreview)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.85).combined(with: .opacity),
                                removal: .scale(scale: 0.9).combined(with: .opacity)))
                    }
                    addTile
                }
                .padding(Layout.inset)
                .padding(.bottom, 12)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("\(state.items.count) \(state.items.count == 1 ? "file" : "files")")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.text)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.items.count)
            Text(Format.size(state.listBytes))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(theme.text2)
            Spacer()
            Button {
                state.clearAll()
            } label: {
                HStack(spacing: 5) {
                    Icon(name: "trash-alt", size: 12)
                    Text("Clear all")
                }
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(state.isCompressing)
            .opacity(state.isCompressing ? 0.4 : 1)
        }
        // Same vertical axis as the side panel header: both sit on the 24pt
        // grid with a 40pt row, so their centers align across the divider.
        .frame(height: Layout.headerHeight)
        .padding(.horizontal, Layout.inset)
        .padding(.top, Layout.inset)
        .padding(.bottom, 4)
    }

    private var addTile: some View {
        Button {
            BonsaiApp.openPanel(into: state)
        } label: {
            VStack(spacing: 10) {
                Icon(name: "plus", size: 22)
                Text("Add PDFs")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(theme.text3)
            .frame(maxWidth: .infinity, minHeight: 208)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(theme.borderStrong)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(state.isCompressing)
        .modifier(HoverScale(scale: 1.02))
    }
}

// MARK: - File card

struct FileCard: View {
    @Environment(AppState.self) private var state
    @Environment(\.theme) private var theme
    @Bindable var item: PDFItem
    let openPreview: (PDFItem) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnailArea
            info
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow.opacity(hovering ? 1 : 0.55),
                        radius: hovering ? 16 : 8, y: hovering ? 8 : 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) { removeButton }
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { openPreviewIfDone() }
        .contextMenu {
            Button("Preview Before / After") { openPreviewIfDone() }
                .disabled(item.result == nil)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.savedURL ?? item.url])
            }
            Divider()
            Button("Remove", role: .destructive) { state.remove(item) }
                .disabled(state.isCompressing)
        }
    }

    /// The comparison needs an "after": it opens once the file has been compressed.
    private func openPreviewIfDone() {
        if item.result != nil { openPreview(item) }
    }

    // MARK: thumbnail

    private var thumbnailArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.wellBG)
            if let thumb = item.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .padding(10)
                    .transition(.opacity)
            } else {
                Icon(name: "file-alt", size: 30)
                    .foregroundStyle(theme.text3)
            }

            statusOverlay
        }
        .frame(height: 132)
        .padding(8)
    }

    /// The item is saved with the preset the user is looking at right now.
    private var doneForCurrentPreset: Bool {
        item.status == .done && item.resultPreset == state.preset
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch item.status {
        case .reading:
            overlayChip { SpinnerRing(size: 15, line: 2) } label: { Text("Reading…") }
        case .compressing:
            overlayChip { SpinnerRing(size: 15, line: 2) } label: { Text("Compressing…") }
        case .done:
            if hovering {
                overlayChip {
                    Icon(name: "eye", size: 13)
                } label: {
                    Text("Preview")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                overlayChip {
                    Icon(name: "check-circle", size: 13).foregroundStyle(theme.success)
                } label: {
                    Text(doneForCurrentPreset
                         ? "Saved"
                         : "Saved as \(item.resultPreset?.rawValue ?? "")")
                        .foregroundStyle(theme.success)
                }
            }
        case .failed(let reason):
            overlayChip {
                Icon(name: "exclamation-triangle", size: 13).foregroundStyle(theme.danger)
            } label: {
                Text(reason).foregroundStyle(theme.danger)
            }
        case .ready:
            EmptyView()
        }
    }

    private func overlayChip<I: View, L: View>(@ViewBuilder icon: () -> I,
                                               @ViewBuilder label: () -> L) -> some View {
        HStack(spacing: 6) {
            icon()
            label()
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
        )
        .frame(maxWidth: 150)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 14)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: item.status)
    }

    // MARK: info

    private var info: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.pageCount > 0
                 ? "\(Format.size(item.inputBytes)), \(item.pageCount) \(item.pageCount == 1 ? "page" : "pages")"
                 : Format.size(item.inputBytes))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(theme.text2)

            resultBadge
                .padding(.top, 3)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What landed on disk. Before the run the slot stays empty at the same
    /// height, so the card doesn't jump when the badge appears.
    @ViewBuilder
    private var resultBadge: some View {
        if case .failed = item.status {
            Badge(text: "Skipped", fg: theme.danger, bg: theme.dangerSoft)
        } else if let r = item.result {
            Badge(text: r.keptOriginal
                    ? "Already optimized"
                    : "\(Format.size(r.outputBytes))  -\(Format.percent(r.savedFraction))",
                  fg: r.keptOriginal ? theme.text2 : theme.success,
                  bg: r.keptOriginal ? theme.wellBG : theme.successSoft)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else {
            Color.clear.frame(height: BadgeToken.height)
        }
    }

    private var removeButton: some View {
        Button {
            state.remove(item)
        } label: {
            Icon(name: "times", size: 11)
        }
        .buttonStyle(CircleIconButtonStyle(diameter: 24))
        .background(Circle().fill(theme.surface).shadow(color: theme.shadow, radius: 4, y: 1))
        .padding(10)
        .disabled(state.isCompressing)
        .opacity(hovering && !state.isCompressing ? 1 : 0)
        .scaleEffect(hovering && !state.isCompressing ? 1 : 0.7)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hovering)
    }
}
