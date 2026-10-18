import Observation
import SwiftUI

/// Holds the Day or Night choice. Colors come from `Theme` rather than the
/// system color scheme, so one `withAnimation` cross-fades every surface.
@Observable @MainActor
final class ThemeStore {
    static let shared = ThemeStore()

    var mode: ThemeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "themeMode") }
    }

    var theme: Theme { Theme(mode: mode) }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "themeMode"), let stored = ThemeMode(rawValue: raw) {
            mode = stored
        } else {
            // NSApp does not exist yet when the App struct is created; the
            // system appearance is read from defaults instead.
            let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            mode = dark ? .night : .day
        }
    }

    func toggle() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) {
            mode = mode == .day ? .night : .day
        }
    }
}
