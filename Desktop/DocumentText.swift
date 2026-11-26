import Foundation
import PDFKit

/// Turns local documents into text so any AI provider can read them, including ones without
/// native PDF or Office support.
enum DocumentText {
    static let maxBytes = 20_000_000
    static let maxCharacters = 90_000

    static func extract(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= maxBytes else {
            throw AssistantError.message("Each attachment must be a regular file smaller than 20 MB.")
        }
        let ext = url.pathExtension.lowercased()
        let text: String
        switch ext {
        case "pdf":
            text = try pdf(url)
        case "docx", "doc", "rtf", "odt", "rtfd", "webarchive":
            text = try textutil(url)
        case "pptx":
            text = try office(url, members: "ppt/slides/*.xml")
        case "xlsx":
            text = try office(url, members: "xl/sharedStrings.xml xl/worksheets/*.xml")
        case "key", "pages", "numbers":
            throw AssistantError.message("Export \(ext.uppercased()) files to PDF first; their format is closed.")
        default:
            guard let raw = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                throw AssistantError.message("This file is not UTF-8 text. Export it to PDF first.")
            }
            text = raw
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw AssistantError.message("No text could be read from \(url.lastPathComponent). It may be a scan; attach page images instead.")
        }
        return String(cleaned.prefix(maxCharacters))
    }

    private static func pdf(_ url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw AssistantError.message("Could not open this PDF.")
        }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            if let page = document.page(at: index), let text = page.string, !text.isEmpty {
                pages.append(text)
            }
        }
        return pages.joined(separator: "\n\n")
    }

    private static func textutil(_ url: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw AssistantError.message("Could not read this document.") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            throw AssistantError.message("Could not read this document. Export it to PDF first.")
        }
        return text
    }

    /// Office Open XML files are zip archives; pull the XML members and drop the markup.
    private static func office(_ url: URL, members: String) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path] + members.split(separator: " ").map(String.init)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw AssistantError.message("Could not read this document.") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let xml = String(data: data, encoding: .utf8), !xml.isEmpty else {
            throw AssistantError.message("Could not read this document. Export it to PDF first.")
        }
        var text = xml.replacingOccurrences(of: "</a:p>", with: "\n")
        text = text.replacingOccurrences(of: "</w:p>", with: "\n")
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        return text
    }
}
