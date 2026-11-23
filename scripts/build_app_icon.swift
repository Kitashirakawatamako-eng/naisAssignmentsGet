import AppKit
import Foundation

// Compile with Desktop/*.swift except Main.swift to use the same icon renderer as Settings.
// Arguments: a built app bundle containing the artwork, destination AppIcon.icns.
@main struct BuildAppIcon {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3,
              let bundle = Bundle(path: CommandLine.arguments[1]),
              let icon = AppIconChoice.image("bookOtter", bundle: bundle) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        func integer(_ value: Int) -> Data {
            var big = UInt32(value).bigEndian
            return withUnsafeBytes(of: &big) { Data($0) }
        }
        var payload = Data()
        for (kind, size) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
                             ("ic08", 256), ("ic09", 512), ("ic10", 1024)] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                      from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            let png = bitmap.representation(using: .png, properties: [:])!
            payload.append(Data(kind.utf8))
            payload.append(integer(png.count + 8))
            payload.append(png)
        }
        var result = Data("icns".utf8)
        result.append(integer(payload.count + 8))
        result.append(payload)
        try result.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
    }
}
