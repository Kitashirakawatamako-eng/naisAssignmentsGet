import AppKit

func drawIcon(size: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let drawing = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = drawing
    let field = drawing.cgContext
    field.scaleBy(x: Double(size) / 1024, y: Double(size) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 92, y: 92, width: 840, height: 840), xRadius: 188, yRadius: 188)
    let green = NSColor(srgbRed: 0.11, green: 0.34, blue: 0.27, alpha: 1)
    let mint = NSColor(srgbRed: 0.24, green: 0.56, blue: 0.45, alpha: 1)
    NSGradient(starting: green, ending: mint)?.draw(in: tile, angle: 55)
    NSColor.white.withAlphaComponent(0.18).setFill()
    NSBezierPath(roundedRect: NSRect(x: 260, y: 245, width: 504, height: 534), xRadius: 79, yRadius: 79).fill()
    NSColor.white.setStroke()
    for y in [405.0, 525.0, 645.0] {
        let check = NSBezierPath()
        check.move(to: CGPoint(x: 346, y: y))
        check.line(to: CGPoint(x: 378, y: y - 32))
        check.line(to: CGPoint(x: 431, y: y + 27))
        check.lineWidth = 22
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.stroke()
        let rule = NSBezierPath()
        rule.move(to: CGPoint(x: 500, y: y))
        rule.line(to: CGPoint(x: y == 405 ? 620 : 670, y: y))
        rule.lineWidth = 22
        rule.lineCapStyle = .round
        rule.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

func iconRecord(_ type: String, _ content: Data) -> Data {
    var length = UInt32(8 + content.count).bigEndian
    var result = Data(type.utf8)
    result.append(withUnsafeBytes(of: &length) { Data($0) })
    result.append(content)
    return result
}

var sizes = Data()
for (size, type) in [(16, "icp4"), (32, "icp5"), (64, "icp6"), (128, "ic07"),
                     (256, "ic08"), (512, "ic09"), (1024, "ic10")] {
    guard let data = drawIcon(size: size) else { fatalError("Could not render app icon") }
    sizes.append(iconRecord(type, data))
}
try iconRecord("icns", sizes).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
