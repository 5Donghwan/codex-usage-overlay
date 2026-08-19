import SwiftUI

private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}

enum Palette {
    // ChatGPT/Codex-adjacent semantic colors. They remain legible in both themes.
    static let success = Color(hex: 0x43B03F)
    static let warning = Color(hex: 0xFFCC00)
    static let danger = Color(hex: 0xFF453A)

    static func fill(for percent: Double, warnAt: Double, dangerAt: Double) -> Color {
        if percent >= dangerAt { return danger }
        if percent >= warnAt { return warning }
        return success
    }
}
