import Foundation

/// Converts Office files to PDF when a converter is installed, so slides and pages can be sent
/// to the model as page images instead of plain text.
enum OfficeRender {
    static let candidates = [
        "/Applications/LibreOffice.app/Contents/MacOS/soffice",
        "/opt/homebrew/bin/soffice",
        "/usr/local/bin/soffice",
    ]

    static var soffice: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Returns a rendered PDF, or nil when no converter is available.
    static func pdf(from source: URL, in folder: URL) throws -> URL? {
        guard let soffice else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: soffice)
        process.arguments = ["--headless", "--convert-to", "pdf", "--outdir", folder.path, source.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        if process.isRunning {
            process.terminate()
            throw AssistantError.message("Converting \(source.lastPathComponent) took too long.")
        }
        let target = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".pdf")
        return FileManager.default.fileExists(atPath: target.path) ? target : nil
    }

    /// Slides without a converter: keep the pictures embedded in the deck, so the model still
    /// sees diagrams and screenshots at full resolution.
    static func slideImages(_ source: URL, in folder: URL) throws -> [URL] {
        let media = folder.appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", "-o", source.path, "ppt/media/*", "-d", media.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let root = media.appendingPathComponent("ppt/media", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let allowed: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "heic", "webp"]
        return names.filter { allowed.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
            .map { root.appendingPathComponent($0) }
    }
}
