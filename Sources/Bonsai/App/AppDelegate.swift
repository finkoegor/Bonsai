import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// PDFs dropped on the Dock icon or opened with Bonsai from Finder.
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
