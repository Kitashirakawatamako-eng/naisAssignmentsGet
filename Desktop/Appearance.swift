import AppKit
import SwiftUI

var oceanTheme: Bool { DeskTheme.current != .classic }
var jade: Color { DeskTheme.current.primary }
var oceanBlue: Color { DeskTheme.current.accent }
var panel: Color { DeskTheme.current.surface }
var backdrop: Color { DeskTheme.current.background }
var headerDecoration: Color { DeskTheme.current == .classic ? .clear : panel }

struct AppearanceSurface: ViewModifier {
    @AppStorage("appearanceTheme") private var theme = "otter"
    func body(content: Content) -> some View {
        content.preferredColorScheme(theme == "classic" ? nil : .light).tint(jade)
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
    private static var images: [String: NSImage] = [:]

    static func image(_ choice: String, background: Bool? = nil, bundle: Bundle = .main) -> NSImage? {
        let tile = background ?? (UserDefaults.standard.object(forKey: "iconBackgroundEnabled") as? Bool ?? true)
        let cacheKey = "\(bundle.bundlePath):\(choice):\(tile)"
        if let cached = images[cacheKey] { return cached }

        let result: NSImage?
        switch choice {
        case "bookOtter":
            result = load("BookOtter", extension: "png", in: bundle).map { source in
                NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { canvas in
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(ovalIn: canvas.insetBy(dx: 48, dy: 48)).addClip()
                    NSColor.white.setFill()
                    canvas.fill()
                    source.draw(in: canvas)
                    NSGraphicsContext.restoreGraphicsState()
                    return true
                }
            }
        case "classic":
            result = load("ClassicIcon", extension: "icns", in: bundle).map(roundedIcon)
        case "otter", "creature":
            let otter = choice == "otter"
            let base = otter ? "Otter" : "Creature"
            guard let mascot = load(base + "TransparentIconSource", extension: "png", in: bundle)
                ?? load(base + "TransparentIcon", extension: "icns", in: bundle) else { return nil }
            result = tile ? withBackground(mascot, inset: otter ? -34 : 14) : mascot
        default:
            return image("otter", background: tile, bundle: bundle)
        }
        images[cacheKey] = result
        return result
    }

    private static func load(_ name: String, extension ext: String, in bundle: Bundle) -> NSImage? {
        bundle.url(forResource: name, withExtension: ext).flatMap(NSImage.init(contentsOf:))
    }

    private static func roundedIcon(_ source: NSImage) -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { canvas in
            let tile = canvas.insetBy(dx: 42, dy: 42)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: tile, xRadius: 97, yRadius: 97).addClip()
            source.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    private static func withBackground(_ mascot: NSImage, inset: CGFloat) -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { canvas in
            let tile = canvas.insetBy(dx: 42, dy: 42)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: tile, xRadius: 97, yRadius: 97).addClip()
            NSColor.white.setFill()
            tile.fill()
            NSGraphicsContext.current?.imageInterpolation = .none
            mascot.draw(in: tile.insetBy(dx: inset, dy: inset), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
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
                iconButton("bookOtter", title: "Notebook Otter")
                iconButton("otter", title: "Pixel Otter")
                iconButton("creature", title: "Pixel Anomalocaris")
                iconButton("classic", title: "Original Icon")
            }
            if ["otter", "creature"].contains(icon) {
                Toggle("Icon background", isOn: Binding(get: { backgroundEnabled }, set: { value in
                    backgroundEnabled = value
                    iconNotice = AppIconChoice.apply(icon) ? "" : "Could not apply the icon to Finder."
                }))
                Text("Turn off for a transparent mascot icon.").font(.caption).foregroundStyle(.secondary)
            }
            if !iconNotice.isEmpty { Text(LocalizedStringKey(iconNotice)).font(.caption).foregroundStyle(.secondary) }
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
        iconNotice = AppIconChoice.apply(value) ? "" : "Could not apply the icon to Finder."
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
