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
        #if DEBUG
        .task { await runScriptedSession() }
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
        Binding(get: { state.isDropTargeted }, set: { state.isDropTargeted = $0 })
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
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

    #if DEBUG
    /// Drives the real interface from the environment, for scripted checks:
    /// BONSAI_AUTOLOAD=/a.pdf:/b.pdf adds files, BONSAI_AUTOCOMPRESS=1 presses
    /// the button once they are read (BONSAI_OUTDIR sets the folder),
    /// BONSAI_AUTOPREVIEW=1 opens the comparison afterwards and
    /// BONSAI_AUTOPRESET2=<preset> compresses once more with another preset.
    private func runScriptedSession() async {
        let environment = ProcessInfo.processInfo.environment
        if let paths = environment["BONSAI_AUTOLOAD"], !paths.isEmpty {
            state.addURLs(paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        }
        guard environment["BONSAI_AUTOCOMPRESS"] == "1" else { return }
        while !state.canCompress { try? await Task.sleep(for: .milliseconds(200)) }
        state.compressAll()
        while state.lastRun == nil { try? await Task.sleep(for: .milliseconds(200)) }
        if environment["BONSAI_AUTOPREVIEW"] == "1", let first = state.items.first(where: { $0.result != nil }) {
            openWindow(id: "preview", value: first.id)
        }
        guard let second = environment["BONSAI_AUTOPRESET2"].flatMap(Preset.init(rawValue:)) else { return }
        state.preset = second
        while !state.canCompress { try? await Task.sleep(for: .milliseconds(200)) }
        state.compressAll()
    }
    #endif
}
