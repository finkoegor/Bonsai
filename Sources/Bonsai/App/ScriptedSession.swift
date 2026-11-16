#if DEBUG
import AppKit
import SwiftUI

/// Drives the real interface from the environment, for checks without a
/// person at the screen. `BONSAI_SCRIPT` holds commands separated by
/// semicolons:
///
///     add /a.pdf:/b.pdf    adds files or folders
///     wait                 until nothing is being read or compressed
///     sleep 500            milliseconds
///     compress             presses the button (BONSAI_OUTDIR is the folder)
///     preset extreme       low, recommended or extreme
///     mode replace         copy or replace
///     stop                 presses Stop
///     retry 0              tries the failed file at this position again
///     remove 0             removes the file at this position
///     clear                clears the list
///     theme night          day or night
///     preview 0            opens the comparison for this file
///     click 1 480 300      clicks in a window (1 is the main one, in the
///                          order of the snapshots) at a point counted
///                          from the top left corner of its frame
///     snap name            saves the main window as BONSAI_SNAPSHOTS/name.png
///                          and every other window as name-2.png, name-3.png
///     quit
@MainActor
enum ScriptedSession {
    private static var hasStarted = false

    static func run(openPreview: (UUID) -> Void) async {
        guard !hasStarted, let script = ProcessInfo.processInfo.environment["BONSAI_SCRIPT"] else { return }
        hasStarted = true
        let state = AppState.shared

        for command in script.split(separator: ";") {
            let words = command.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1).map(String.init)
            guard let verb = words.first else { continue }
            let argument = words.count > 1 ? words[1] : ""
            let item = Int(argument).flatMap { state.items.indices.contains($0) ? state.items[$0] : nil }

            switch verb {
            case "add":
                state.addURLs(argument.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
            case "wait":
                repeat {
                    try? await Task.sleep(for: .milliseconds(150))
                } while state.isReading || state.isCompressing
            case "sleep":
                try? await Task.sleep(for: .milliseconds(Int(argument) ?? 0))
            case "compress":
                state.compressAll()
            case "preset":
                if let preset = Preset(rawValue: argument) { state.preset = preset }
            case "mode":
                if let mode = SaveMode(rawValue: argument) { state.saveMode = mode }
            case "stop":
                state.stop()
            case "retry":
                if let item { state.retry(item) }
            case "remove":
                if let item { state.remove(item) }
            case "clear":
                state.clearAll()
            case "theme":
                if let mode = ThemeMode(rawValue: argument) { ThemeStore.shared.mode = mode }
            case "preview":
                if let item { openPreview(item.id) }
            case "click":
                let numbers = argument.split(separator: " ").compactMap { Double($0) }
                if numbers.count == 3 { click(window: Int(numbers[0]), at: CGPoint(x: numbers[1], y: numbers[2])) }
            case "snap":
                snapshot(named: argument)
            case "quit":
                NSApp.terminate(nil)
            default:
                break
            }
        }
    }

    /// Draws the main window's views into a bitmap, as they stand now. It
    /// works with the screen locked, when the window itself cannot be
    /// captured.
    /// The main window first, then the others in the order they opened.
    private static var windows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
            .sorted { ($0.title == "Bonsai" ? 0 : 1, $0.windowNumber) < ($1.title == "Bonsai" ? 0 : 1, $1.windowNumber) }
    }

    /// Sends a press and a release of the mouse button through the window,
    /// the way a real click arrives.
    private static func click(window index: Int, at point: CGPoint) {
        guard windows.indices.contains(index - 1) else { return }
        let window = windows[index - 1]
        let location = CGPoint(x: point.x, y: window.frame.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            window.sendEvent(event)
        }
    }

    private static func snapshot(named name: String) {
        guard let directory = ProcessInfo.processInfo.environment["BONSAI_SNAPSHOTS"] else { return }
        for (index, window) in windows.enumerated() {
            // The frame view around the content holds the title bar too.
            guard let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            let file = index == 0 ? "\(name).png" : "\(name)-\(index + 1).png"
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(file))
        }
    }
}
#endif
