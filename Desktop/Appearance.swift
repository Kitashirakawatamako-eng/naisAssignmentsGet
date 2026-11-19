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
var oceanTheme: Bool { DeskTheme.current != .classic }
var jade: Color { DeskTheme.current.primary }
var oceanBlue: Color { DeskTheme.current.accent }
var panel: Color { DeskTheme.current.surface }
var backdrop: Color { DeskTheme.current.background }
var headerDecoration: Color { DeskTheme.current == .classic ? .clear : panel }

struct AppearanceSurface: ViewModifier {
    @AppStorage("appearanceTheme") private var theme = "otter"
    func body(content: Content) -> some View {
        content.id(theme).preferredColorScheme(theme == "classic" ? nil : .light).tint(jade)
    }
}

struct ThemeMascot: View {
    @AppStorage("appearanceTheme") private var theme = "otter"
    let fallback: String
    var body: some View {
        if ["otter", "paleo"].contains(theme), let image = AppIconChoice.image(theme == "otter" ? "otter" : "creature", background: false) {
            Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                .frame(width: 54, height: 54).accessibilityHidden(true)
        } else {
            Image(systemName: fallback).font(.system(size: 21, weight: .medium))
                .foregroundStyle(oceanBlue).frame(width: 43, height: 43)
                .background(jade.opacity(0.12), in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
        }
    }
}

@MainActor enum AppIconChoice {
    static func image(_ choice: String, background: Bool? = nil) -> NSImage? {
        let useBackground = background ?? (UserDefaults.standard.object(forKey: "iconBackgroundEnabled") as? Bool ?? true)
        let name = choice == "classic" ? "ClassicIcon" : choice == "otter" ? (useBackground ? "OtterIcon" : "OtterTransparentIcon") : (useBackground ? "CreatureIcon" : "CreatureTransparentIcon")
        guard let url = Bundle.main.url(forResource: name, withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }
    @discardableResult static func apply(_ choice: String, updateFinder: Bool = true) -> Bool {
        guard let image = image(choice) else { return false }
        NSApp.applicationIconImage = image
        return !updateFinder || NSWorkspace.shared.setIcon(image, forFile: Bundle.main.bundlePath, options: [])
    }
}

struct AppearanceSettings: View {
    @AppStorage("appearanceTheme") private var theme = "otter"
    @AppStorage("appearanceIcon") private var icon = "otter"
    @AppStorage("iconBackgroundEnabled") private var backgroundEnabled = true
    @State private var iconNotice = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Appearance", systemImage: "paintpalette").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(DeskTheme.allCases) { style in themeButton(style) }
            }
            Text(DeskTheme.current.subtitle).font(.caption).foregroundStyle(.secondary)
            Text("Choosing a theme also selects its matching icon. You can choose another icon below.")
                .font(.caption).foregroundStyle(.secondary)
            Text("App icon").font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                iconButton("otter", title: "Pixel Otter")
                iconButton("creature", title: "Pixel Anomalocaris")
                iconButton("classic", title: "Original Icon")
            }
            if icon != "classic" {
                Toggle("Icon background", isOn: Binding(get: { backgroundEnabled }, set: { value in
                    backgroundEnabled = value
                    iconNotice = AppIconChoice.apply(icon) ? "" : "Dock icon updated. Finder may need a refresh."
                }))
                Text("Turn off for a transparent mascot icon.").font(.caption).foregroundStyle(.secondary)
            }
            if !iconNotice.isEmpty { Text(iconNotice).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func themeButton(_ style: DeskTheme) -> some View {
        Button {
            theme = style.rawValue
            chooseIcon(style.icon)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    if let image = AppIconChoice.image(style.icon) {
                        Image(nsImage: image).resizable().interpolation(.none).scaledToFit().frame(width: 42, height: 42)
                    }
                    Spacer()
                    Image(systemName: theme == style.rawValue ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(style.primary)
                }
                Text(style.title).font(.subheadline.weight(.semibold))
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in Rectangle().fill(index == 0 ? style.surface : index == 1 ? style.primary : style.accent).frame(width: 20, height: 8).border(.secondary.opacity(0.15)) }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(style.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme == style.rawValue ? style.primary : .secondary.opacity(0.2), lineWidth: theme == style.rawValue ? 2 : 1))
        }.buttonStyle(.plain).accessibilityLabel(style.title)
            .accessibilityAddTraits(theme == style.rawValue ? .isSelected : [])
    }
    private func chooseIcon(_ value: String) {
        icon = value
        iconNotice = AppIconChoice.apply(value) ? "" : "Dock icon updated. Finder may need a refresh."
    }
    private func iconButton(_ value: String, title: LocalizedStringKey) -> some View {
        Button { chooseIcon(value) } label: {
            VStack(spacing: 7) {
                if let image = AppIconChoice.image(value) {
                    Image(nsImage: image).resizable().interpolation(.none).scaledToFit().frame(width: 54, height: 54)
                }
                Text(title).font(.caption).lineLimit(2)
                Image(systemName: icon == value ? "checkmark.circle.fill" : "circle").font(.caption)
            }
            .frame(maxWidth: .infinity).padding(8)
            .background(icon == value ? jade.opacity(0.10) : panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(icon == value ? jade : .secondary.opacity(0.2), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(icon == value ? .isSelected : [])
    }
}
