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
        // Kill macOS focus rings app-wide: the teal outline reads as a stray
        // "selected" state on our custom buttons.
        .focusEffectDisabled()
        .task { await runDebugHooks() }
    }

    /// Test hooks driven by env vars — lets CI/scripts exercise the real UI flow:
    /// BONSAI_AUTOLOAD=/a.pdf:/b.pdf  preloads files,
    /// BONSAI_AUTOCOMPRESS=1          presses the big button once estimates land.
    private func runDebugHooks() async {
        let env = ProcessInfo.processInfo.environment
        if env["BONSAI_FRONT"] == "1" {
            NSApp.activate(ignoringOtherApps: true)
        }
        if let paths = env["BONSAI_AUTOLOAD"], !paths.isEmpty {
            state.addURLs(paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        }
        // BONSAI_AUTOPREVIEW=1 → open the before/after window for the first file.
        if env["BONSAI_AUTOPREVIEW"] == "1" {
            while state.items.first.map({ $0.estimate(for: state.preset) == nil }) ?? true {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if let first = state.items.first {
                openWindow(id: "preview", value: first.id)
            }
        }
        guard env["BONSAI_AUTOCOMPRESS"] == "1" else { return }
        while !(state.totalEstimatedBytes != nil && state.canCompress) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        state.compressAll()
        // BONSAI_AUTOPRESET2=low  → after the first run, switch preset
        // and compress again (the "save one more version and compare" flow).
        guard let second = env["BONSAI_AUTOPRESET2"].flatMap(Preset.init(rawValue:)) else { return }
        while state.lastRun == nil { try? await Task.sleep(for: .milliseconds(200)) }
        state.preset = second
        while !(state.totalEstimatedBytes != nil && state.canCompress) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        state.compressAll()
    }

    // MARK: - Left side: drop zone / file grid

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

            // Drag-over highlight
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                .foregroundStyle(state.isDropTargeted ? theme.accent : theme.borderStrong.opacity(state.items.isEmpty ? 1 : 0))
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(theme.accentSoft.opacity(state.isDropTargeted ? 1 : 0))
                )
                .padding(16)
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
        var found = false
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            found = true
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            state.addURLs(urls)
        }
        return found
    }
}

// MARK: - Empty state

struct EmptyDropState: View {
    @Environment(AppState.self) private var state
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Text("Drop your PDFs here")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("Compress one file or a whole batch at once")
                .font(.system(size: 13))
                .foregroundStyle(theme.text2)

            Button {
                BonsaiApp.openPanel(into: state)
            } label: {
                HStack(spacing: 7) {
                    Icon(name: "folder-open", size: 14)
                    Text("Browse Files")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(theme.accentSoft)
                        .overlay(Capsule().strokeBorder(theme.accent.opacity(0.35), lineWidth: 1))
                )
            }
            .buttonStyle(.plain)
            .modifier(HoverScale(scale: 1.04))
            .padding(.top, 16)

            HStack(spacing: 5) {
                Icon(name: "check-circle", size: 11)
                Text("100% local. Files never leave your Mac")
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.text3)
            .padding(.top, 22)
        }
    }
}
