import SwiftUI
import Observation

// MARK: - Day / Night theme
// All colors are driven by our own Theme value (not by the system colorScheme),
// so toggling animates every surface smoothly with one `withAnimation`.

enum ThemeMode: String {
    case day, night
}

@Observable @MainActor
final class ThemeStore {
    static let shared = ThemeStore()

    var mode: ThemeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "themeMode") }
    }

    var theme: Theme { Theme(mode: mode) }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "themeMode"),
           let m = ThemeMode(rawValue: raw) {
            mode = m
        } else {
            // First launch: follow the system. (Read from defaults — NSApp does not
            // exist yet at App.init time, touching it here crashes on launch.)
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

struct Theme: Equatable {
    let mode: ThemeMode
    var isNight: Bool { mode == .night }

    // Canvas & surfaces
    var bg: Color        { isNight ? Color(hex: 0x101014) : Color(hex: 0xF5F5F7) }
    var surface: Color   { isNight ? Color(hex: 0x1A1A20) : .white }
    var surface2: Color  { isNight ? Color(hex: 0x212129) : Color(hex: 0xFAFAFC) }
    var wellBG: Color    { isNight ? Color(hex: 0x16161B) : Color(hex: 0xEFEFF3) }

    // Text
    var text: Color      { isNight ? Color(hex: 0xF2F2F5) : Color(hex: 0x1D1D1F) }
    var text2: Color     { isNight ? Color(hex: 0x9C9CA8) : Color(hex: 0x6E6E76) }
    var text3: Color     { isNight ? Color(hex: 0x62626E) : Color(hex: 0xA0A0AB) }

    // Lines & shadows
    var border: Color    { isNight ? .white.opacity(0.08) : .black.opacity(0.07) }
    var borderStrong: Color { isNight ? .white.opacity(0.16) : .black.opacity(0.14) }
    var shadow: Color    { isNight ? .black.opacity(0.5) : .black.opacity(0.10) }

    // Brand
    var accent: Color    { isNight ? Color(hex: 0x818CF8) : Color(hex: 0x6366F1) }
    var accent2: Color   { isNight ? Color(hex: 0xA78BFA) : Color(hex: 0x8B5CF6) }
    var accentSoft: Color { accent.opacity(isNight ? 0.16 : 0.10) }
    var onAccent: Color  { .white }
    var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // Status
    var success: Color   { isNight ? Color(hex: 0x34D399) : Color(hex: 0x059669) }
    var successSoft: Color { success.opacity(isNight ? 0.16 : 0.12) }
    var danger: Color    { isNight ? Color(hex: 0xF87171) : Color(hex: 0xDC2626) }
    var dangerSoft: Color { danger.opacity(isNight ? 0.16 : 0.10) }
    var warning: Color   { isNight ? Color(hex: 0xFBBF24) : Color(hex: 0xD97706) }

    // Matching system scheme for sheets / menus / native controls
    var colorScheme: ColorScheme { isNight ? .dark : .light }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(mode: .day)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Formatting helpers

enum Format {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func size(_ b: Int64) -> String { bytes.string(fromByteCount: b) }

    static func percent(_ fraction: Double) -> String {
        // Floor, not round: 99.6% savings must read as 99%, never as a
        // physically impossible 100%.
        "\(Int((fraction * 100).rounded(.down)))%"
    }
}
