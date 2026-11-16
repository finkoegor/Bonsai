import SwiftUI

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
        .onTapGesture { activate() }
        .onDrag {
            // A card drags as its file, straight into a message or a folder:
            // the compressed version when there is one, the original otherwise.
            state.beginDragOut()
            return NSItemProvider(contentsOf: shown?.url ?? item.url) ?? NSItemProvider()
        }
        .contextMenu {
            if item.status.isFailure {
                Button("Try Again") { state.retry(item) }
            } else {
                Button("Preview Before / After") { activate() }
                    .disabled(shown == nil)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([shown?.url ?? item.url])
            }
            Divider()
            Button("Remove", role: .destructive) { state.remove(item) }
                .disabled(state.isCompressing)
        }
    }

    /// A click previews a compressed file and retries a failed one.
    private func activate() {
        if item.status.isFailure {
            state.retry(item)
        } else if shown != nil {
            openPreview(item)
        }
    }

    // MARK: Thumbnail

    private var thumbnailArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.wellBG)
            if let thumbnail = item.thumbnail {
                Image(nsImage: thumbnail)
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

    /// The version behind the chip, the badge and the preview.
    private var shown: SavedVersion? { item.shownVersion(for: state.preset) }

    @ViewBuilder
    private var statusOverlay: some View {
        switch item.status {
        case .reading:
            chip { SpinnerRing(size: 15, line: 2) } label: { Text("Reading…") }
        case .queued:
            chip { Image(systemName: "clock").font(.system(size: 11, weight: .medium)) } label: { Text("Waiting") }
                .foregroundStyle(theme.text2)
        case .compressing:
            chip { SpinnerRing(size: 15, line: 2) } label: { Text("Compressing…") }
        case .done:
            if hovering {
                chip { Icon(name: "eye", size: 13) } label: { Text("Preview") }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if shown?.result.keptOriginal == true {
                chip {
                    Icon(name: "check-circle", size: 13).foregroundStyle(theme.text2)
                } label: {
                    Text("No change").foregroundStyle(theme.text2)
                }
            } else {
                chip {
                    Icon(name: "check-circle", size: 13).foregroundStyle(theme.success)
                } label: {
                    Text(shown.map { $0.preset == state.preset ? "Saved" : $0.preset.shortTitle } ?? "Saved")
                        .foregroundStyle(theme.success)
                }
            }
        case .failed(let reason):
            if hovering {
                chip { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)) } label: {
                    Text("Try again")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                chip {
                    Icon(name: "exclamation-triangle", size: 13).foregroundStyle(theme.danger)
                } label: {
                    Text(reason).foregroundStyle(theme.danger)
                }
                .help(reason)
            }
        case .ready:
            EmptyView()
        }
    }

    private func chip<Leading: View, Label: View>(@ViewBuilder icon: () -> Leading,
                                                  @ViewBuilder label: () -> Label) -> some View {
        HStack(spacing: 6) {
            icon()
            label()
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Opaque enough to read over any first page, light or dark.
        .background(
            Capsule().fill(theme.surface.opacity(0.94))
                .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        )
        .frame(maxWidth: 150)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 14)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: item.status)
    }

    // MARK: Details

    private var info: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.url.path)
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

    @ViewBuilder
    private var resultBadge: some View {
        if case .failed = item.status {
            Badge(text: "Skipped", foreground: theme.danger, background: theme.dangerSoft)
        } else if let result = shown?.result {
            Badge(text: result.keptOriginal
                      ? "Already optimized"
                      : "\(Format.size(result.outputBytes))  -\(Format.percent(result.savedFraction))",
                  foreground: result.keptOriginal ? theme.text2 : theme.success,
                  background: result.keptOriginal ? theme.wellBG : theme.successSoft)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else {
            Color.clear.frame(height: Badge.height)
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
