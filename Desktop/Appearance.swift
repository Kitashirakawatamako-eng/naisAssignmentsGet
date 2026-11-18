import AppKit
import SwiftUI

var oceanTheme: Bool { UserDefaults.standard.string(forKey: "appearanceTheme") != "classic" }
var jade: Color {
    if oceanTheme { return Color(red: 0.12, green: 0.48, blue: 0.37) }
    return Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.47, green: 0.80, blue: 0.70, alpha: 1)
            : NSColor(srgbRed: 0.13, green: 0.35, blue: 0.29, alpha: 1)
    })
}
var oceanBlue: Color { oceanTheme ? Color(red: 0.15, green: 0.43, blue: 0.65) : jade }
var panel: Color { oceanTheme ? .white : Color(nsColor: .controlBackgroundColor) }
var backdrop: Color { oceanTheme ? Color(red: 0.97, green: 0.99, blue: 1) : Color(nsColor: .windowBackgroundColor) }
var headerDecoration: LinearGradient {
    LinearGradient(colors: oceanTheme ? [.white, Color(red: 0.92, green: 0.98, blue: 0.96), Color(red: 0.90, green: 0.96, blue: 1)] : [.clear, .clear], startPoint: .leading, endPoint: .trailing)
}

struct AppearanceSurface: ViewModifier {
    @AppStorage("appearanceTheme") private var theme = "ocean"
    func body(content: Content) -> some View {
        content.id(theme).preferredColorScheme(theme == "classic" ? nil : .light).tint(jade)
    }
}

@MainActor enum AppIconChoice {
    static func image(_ choice: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: choice == "classic" ? "ClassicIcon" : "CreatureIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }
    @discardableResult static func apply(_ choice: String) -> Bool {
        guard let image = image(choice) else { return false }
        NSApp.applicationIconImage = image
        // Finder custom icon metadata keeps both signed bundle resources unchanged.
        return NSWorkspace.shared.setIcon(image, forFile: Bundle.main.bundlePath, options: [])
    }
}

struct AppearanceSettings: View {
    @AppStorage("appearanceTheme") private var theme = "ocean"
    @AppStorage("appearanceIcon") private var icon = "creature"
    @State private var iconNotice = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Appearance", systemImage: "paintpalette").font(.headline)
            Picker("Color theme", selection: $theme) {
                Text("Ocean White").tag("ocean")
                Text("Classic Jade").tag("classic")
            }.pickerStyle(.segmented)
            HStack(spacing: 7) {
                ForEach(0..<3) { index in
                    Circle().fill(index == 0 ? panel : index == 1 ? jade : oceanBlue)
                        .frame(width: 14, height: 14).overlay(Circle().stroke(.secondary.opacity(0.2)))
                }
                Text(theme == "classic" ? "Original theme · follows system appearance" : "White with green and blue accents")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("App icon").font(.subheadline.weight(.medium))
            HStack(spacing: 12) {
                iconButton("creature", title: "Pixel Anomalocaris")
                iconButton("classic", title: "Original Icon")
            }
            if !iconNotice.isEmpty { Text(iconNotice).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func iconButton(_ value: String, title: LocalizedStringKey) -> some View {
        Button {
            icon = value
            iconNotice = AppIconChoice.apply(value) ? "" : "Dock icon updated. Finder may need a refresh."
        } label: {
            VStack(spacing: 7) {
                if let image = AppIconChoice.image(value) {
                    Image(nsImage: image).resizable().interpolation(.none).scaledToFit().frame(width: 64, height: 64)
                }
                Label(title, systemImage: icon == value ? "checkmark.circle.fill" : "circle").font(.caption)
            }
            .frame(maxWidth: .infinity).padding(10)
            .background(icon == value ? jade.opacity(0.10) : panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(icon == value ? jade : .secondary.opacity(0.2), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityAddTraits(icon == value ? .isSelected : [])
    }
}
