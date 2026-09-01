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
    static let success = Color(hex: 0x43B03F)
    static let warning = Color(hex: 0xFFCC00)
    static let danger = Color(hex: 0xFF453A)

    // Brighter variants keep the bars distinct on Codex's dark composer.
    static let darkSuccess = Color(hex: 0x65E572)
    static let darkWarning = Color(hex: 0xFFD633)
    static let darkDanger = Color(hex: 0xFF625A)

    static func fill(
        for percent: Double,
        warnAt: Double,
        dangerAt: Double,
        dark: Bool = false
    ) -> Color {
        if percent >= dangerAt { return dark ? darkDanger : danger }
        if percent >= warnAt { return dark ? darkWarning : warning }
        return dark ? darkSuccess : success
    }
}
