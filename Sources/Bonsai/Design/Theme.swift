import SwiftUI

struct Theme: Equatable {
    let mode: ThemeMode

    var isNight: Bool { mode == .night }

    // Surfaces
    var bg: Color { isNight ? Color(hex: 0x101014) : Color(hex: 0xF5F5F7) }
    var surface: Color { isNight ? Color(hex: 0x1A1A20) : .white }
    var surface2: Color { isNight ? Color(hex: 0x212129) : Color(hex: 0xFAFAFC) }
    var wellBG: Color { isNight ? Color(hex: 0x16161B) : Color(hex: 0xEFEFF3) }

    // Text
    var text: Color { isNight ? Color(hex: 0xF2F2F5) : Color(hex: 0x1D1D1F) }
    var text2: Color { isNight ? Color(hex: 0x9C9CA8) : Color(hex: 0x6E6E76) }
    var text3: Color { isNight ? Color(hex: 0x62626E) : Color(hex: 0xA0A0AB) }

    // Lines and shadows
    var border: Color { isNight ? .white.opacity(0.08) : .black.opacity(0.07) }
    var borderStrong: Color { isNight ? .white.opacity(0.16) : .black.opacity(0.14) }
    var shadow: Color { isNight ? .black.opacity(0.5) : .black.opacity(0.10) }

    // Brand
    var accent: Color { isNight ? Color(hex: 0x818CF8) : Color(hex: 0x6366F1) }
    var accent2: Color { isNight ? Color(hex: 0xA78BFA) : Color(hex: 0x8B5CF6) }
    var accentSoft: Color { accent.opacity(isNight ? 0.16 : 0.10) }
    var onAccent: Color { .white }
    var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // Status
    var success: Color { isNight ? Color(hex: 0x34D399) : Color(hex: 0x059669) }
    var successSoft: Color { success.opacity(isNight ? 0.16 : 0.12) }
    var danger: Color { isNight ? Color(hex: 0xF87171) : Color(hex: 0xDC2626) }
    var dangerSoft: Color { danger.opacity(isNight ? 0.16 : 0.10) }
    var warning: Color { isNight ? Color(hex: 0xFBBF24) : Color(hex: 0xD97706) }

    /// For sheets, menus and native controls.
    var colorScheme: ColorScheme { isNight ? .dark : .light }
}
