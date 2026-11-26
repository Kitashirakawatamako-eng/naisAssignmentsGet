import AppKit
import Foundation
import PDFKit

/// Turns attachments into page images so the model reads the page itself, not extracted text.
/// Long PDFs are split into batches that are sent as separate requests.
enum PageImages {
    static let maxPages = 24
    static let pagesPerBatch = 4
    static let maxEdge: CGFloat = 1400

    enum Item {
        case image(Data, String)
        case text(String)
    }

    static func prepare(_ files: [URL]) throws -> [Item] {
        var items: [Item] = []
        for file in files {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 40_000_000 else {
                throw AssistantError.message("Each attachment must be a regular file smaller than 40 MB.")
            }
            switch file.pathExtension.lowercased() {
            case "pdf":
                guard let document = PDFDocument(url: file) else {
                    throw AssistantError.message("Could not open \(file.lastPathComponent).")
                }
                guard document.pageCount > 0 else { throw AssistantError.message("This PDF has no pages.") }
                for index in 0..<document.pageCount {
                    guard items.count < maxPages else { break }
                    if let page = document.page(at: index), let pageData = render(page) {
                        items.append(.image(pageData, "image/jpeg"))
                    }
                }
            case "png", "jpg", "jpeg", "webp", "heic", "gif", "tiff":
                guard let image = NSImage(contentsOf: file), let data = jpeg(image) else {
                    throw AssistantError.message("Could not read \(file.lastPathComponent).")
                }
                items.append(.image(data, "image/jpeg"))
            default:
                items.append(.text(try DocumentText.extract(file)))
            }
            if items.count >= maxPages { break }
        }
        guard !items.isEmpty else { throw AssistantError.message("Add at least one attachment.") }
        return items
    }

    static func batches(_ items: [Item]) -> [[Item]] {
        var result: [[Item]] = []
        var current: [Item] = []
        for item in items {
            current.append(item)
            if current.count == pagesPerBatch {
                result.append(current); current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func parts(_ batch: [Item], header: String) -> [[String: Any]] {
        var parts: [[String: Any]] = [["type": "text", "text": header]]
        for item in batch {
            switch item {
            case let .image(data, mime):
                parts.append(["type": "image", "mime_type": mime, "data": data.base64EncodedString()])
            case let .text(text):
                parts.append(["type": "text", "text": text])
            }
        }
        return parts
    }

    private static func render(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(2.0, maxEdge / max(bounds.width, bounds.height))
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
        image.unlockFocus()
        return jpeg(image)
    }

    private static func jpeg(_ image: NSImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let ratio = min(1, maxEdge / max(1, longest))
        let target = NSSize(width: max(1, image.size.width * ratio), height: max(1, image.size.height * ratio))
        let resized = NSImage(size: target)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.62])
    }
}
