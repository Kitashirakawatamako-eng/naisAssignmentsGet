import AppKit
import SwiftUI

enum DeskTheme: String, CaseIterable, Identifiable {
    case otter, paleo, ocean, classic
    var id: String { rawValue }
    static var current: DeskTheme { DeskTheme(rawValue: UserDefaults.standard.string(forKey: "appearanceTheme") ?? "otter") ?? .otter }
    var title: LocalizedStringKey {
        switch self { case .otter: "Little Otter"; case .paleo: "Fossil Cove"; case .ocean: "Ocean White"; case .classic: "Classic Jade" }
    }
    var subtitle: LocalizedStringKey {
        switch self {
        case .otter: "Cream, clear water, and a little otter"
        case .paleo: "Fossil ivory, moss green, and stone"
        case .ocean: "White with green and blue accents"
        case .classic: "Original theme · follows system appearance"
        }
    }
    var icon: String { self == .otter ? "otter" : self == .classic ? "classic" : "creature" }
    var primary: Color {
        switch self {
        case .otter: Color(red: 0.04, green: 0.53, blue: 0.55)
        case .paleo: Color(red: 0.28, green: 0.43, blue: 0.30)
        case .ocean: Color(red: 0.04, green: 0.60, blue: 0.38)
        case .classic: Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.47, green: 0.80, blue: 0.70, alpha: 1)
                : NSColor(srgbRed: 0.13, green: 0.35, blue: 0.29, alpha: 1)
        })
        }
    }
    var accent: Color {
        switch self {
        case .otter: Color(red: 0.12, green: 0.57, blue: 0.78)
        case .paleo: Color(red: 0.61, green: 0.46, blue: 0.27)
        case .ocean: Color(red: 0.02, green: 0.51, blue: 0.88)
        case .classic: primary
        }
    }
    var surface: Color {
        switch self {
        case .otter: Color(red: 1, green: 0.99, blue: 0.96)
        case .paleo: Color(red: 0.99, green: 0.98, blue: 0.94)
        case .ocean: .white
        case .classic: Color(nsColor: .controlBackgroundColor)
        }
    }
    var background: Color {
        switch self {
        case .otter: Color(red: 0.92, green: 0.98, blue: 0.98)
        case .paleo: Color(red: 0.94, green: 0.93, blue: 0.87)
        case .ocean: Color(red: 0.97, green: 0.99, blue: 1)
        case .classic: Color(nsColor: .windowBackgroundColor)
        }
    }
}

enum WidgetColor: String, CaseIterable {
    case theme, mint, blue, lavender, peach, rose

    var title: LocalizedStringKey {
        switch self {
        case .theme: "App theme"
        case .mint: "Mint"
        case .blue: "Sky blue"
        case .lavender: "Lavender"
        case .peach: "Peach"
        case .rose: "Rose"
        }
    }

    func palette(theme: DeskTheme) -> (surface: Color, card: Color, accent: Color) {
        func rgb(_ hex: Int) -> Color {
            Color(red: Double(hex >> 16) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
        }
        let colors: (Int, Int, Int)
        switch self {
        case .theme: return (theme.surface, theme.background, theme.primary)
        case .mint: colors = (0xE4F7ED, 0xC9EEDC, 0x126044)
        case .blue: colors = (0xE6F3FF, 0xCFE7FC, 0x195687)
        case .lavender: colors = (0xF1EBFE, 0xE4DAFA, 0x604193)
        case .peach: colors = (0xFFF1E3, 0xFFE2C7, 0x874922)
        case .rose: colors = (0xFDEDF2, 0xFADBE6, 0x8A3858)
        }
        return (rgb(colors.0), rgb(colors.1), rgb(colors.2))
    }
}
