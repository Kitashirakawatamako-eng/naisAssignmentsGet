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
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 60_000_000 else {
                throw AssistantError.message("Each attachment must be a regular file smaller than 60 MB.")
            }
            let ext = file.pathExtension.lowercased()
            switch ext {
            case "pdf":
                items += try pages(of: file, limit: maxPages - items.count)
            case "png", "jpg", "jpeg", "webp", "heic", "gif", "tiff":
                guard let image = NSImage(contentsOf: file), let data = jpeg(image) else {
                    throw AssistantError.message("Could not read \(file.lastPathComponent).")
                }
                items.append(.image(data, "image/jpeg"))
            case "pptx", "docx", "xlsx", "ppt", "doc", "xls":
                items += try officeItems(file, ext: ext, room: maxPages - items.count)
            default:
                items.append(.text(try DocumentText.extract(file)))
            }
            if items.count >= maxPages { break }
        }
        guard !items.isEmpty else { throw AssistantError.message("Add at least one attachment.") }
        return Array(items.prefix(maxPages))
    }

    /// Office files become page images when LibreOffice is installed; slides otherwise fall back
    /// to their embedded pictures plus extracted text.
    private static func officeItems(_ file: URL, ext: String, room: Int) throws -> [Item] {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("sp-pages-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let pdf = try OfficeRender.pdf(from: file, in: temporary) {
            return try pages(of: pdf, limit: room)
        }
        if ext == "pptx" || ext == "ppt" {
            var result: [Item] = [.text(try DocumentText.extract(file))]
            for image in try OfficeRender.slideImages(file, in: temporary) {
                guard result.count < room, let source = NSImage(contentsOf: image), let data = jpeg(source) else { continue }
                result.append(.image(data, "image/jpeg"))
            }
            return result
        }
        return [.text(try DocumentText.extract(file))]
    }

    private static func pages(of file: URL, limit: Int) throws -> [Item] {
        guard limit > 0, let document = PDFDocument(url: file) else { return [] }
        var result: [Item] = []
        for index in 0..<document.pageCount where result.count < limit {
            if let page = document.page(at: index), let pageData = render(page) {
                result.append(.image(pageData, "image/jpeg"))
            }
        }
        return result
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
