import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Sparkle

@main
struct BonsaiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var state = AppState.shared
    @State private var themeStore = ThemeStore.shared
    /// Sparkle auto-updater: checks the appcast feed from Info.plist (SUFeedURL).
    private let updater = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: nil)

    var body: some Scene {
        Window("Bonsai", id: "main") {
            ContentView()
                .environment(state)
                .environment(themeStore)
                .environment(\.theme, themeStore.theme)
                .preferredColorScheme(themeStore.theme.colorScheme)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 700)

        // Before/after preview lives in its own window: movable, resizable,
        // full-screenable — everything a sheet can't do.
        WindowGroup("Preview", id: "preview", for: UUID.self) { $itemID in
            PreviewWindow(itemID: itemID)
                .environment(state)
                .environment(themeStore)
                .environment(\.theme, themeStore.theme)
                .preferredColorScheme(themeStore.theme.colorScheme)
        }
        .defaultSize(width: 1000, height: 720)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.updater.checkForUpdates()
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open PDFs…") { Self.openPanel(into: state) }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Clear List") { state.clearAll() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(state.items.isEmpty || state.isCompressing)
            }
            CommandGroup(after: .toolbar) {
                Button(themeStore.mode == .day ? "Switch to Night" : "Switch to Day") {
                    themeStore.toggle()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }

    @MainActor
    static func openPanel(into state: AppState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose PDF files to compress"
        if panel.runModal() == .OK {
            state.addURLs(panel.urls)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // PDFs dropped on the Dock icon / "Open With → Bonsai"
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            AppState.shared.addURLs(urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Compressor.cleanupTemp()
    }
}
