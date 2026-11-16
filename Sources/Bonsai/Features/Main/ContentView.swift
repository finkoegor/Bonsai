import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.theme) private var theme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            dropArea
            Rectangle()
                .fill(theme.border)
                .frame(width: 1)
            SidePanel()
                .frame(width: 384)
        }
        .background(theme.bg)
        .focusEffectDisabled()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshTools()
        }
        #if DEBUG
        .task { await ScriptedSession.run { openWindow(id: "preview", value: $0) } }
        #endif
    }

    private var dropArea: some View {
        ZStack {
            theme.bg
            if state.items.isEmpty {
                EmptyDropState()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                FileGrid(openPreview: { openWindow(id: "preview", value: $0.id) })
                    .transition(.opacity)
            }

            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                .foregroundStyle(state.isDropTargeted
                                 ? theme.accent
                                 : theme.borderStrong.opacity(state.items.isEmpty ? 1 : 0))
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(theme.accentSoft.opacity(state.isDropTargeted ? 1 : 0))
                )
                .padding(Layout.inset)
                .allowsHitTesting(false)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.isDropTargeted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: dropTargetBinding) { providers in
            handleDrop(providers)
        }
    }

    private var dropTargetBinding: Binding<Bool> {
        Binding(get: { state.isDropTargeted }, set: { state.isDropTargeted = $0 && !state.isDraggingOut })
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty, !state.isDraggingOut else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            state.addURLs(urls)
        }
        return true
    }
}
