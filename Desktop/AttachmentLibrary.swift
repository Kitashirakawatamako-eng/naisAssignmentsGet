import CryptoKit
import Foundation

struct AttachmentCopy: Hashable, Sendable {
    let source, folder, destination: URL
}

enum AttachmentLibrary {
    static var defaultFolder: URL {
        let files = FileManager.default
        let downloads = files.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? files.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        return downloads.appendingPathComponent("作业速览", isDirectory: true)
    }

    static func source(for attachment: Attachment, in root: URL) -> URL? {
        guard let path = attachment.localPath else { return nil }
        let folder = root.appendingPathComponent("data/tasks").resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(folder.path + "/"), isFile(file) else { return nil }
        return file
    }

    static func copies(for task: Assignment, in root: URL, to base: URL) -> [AttachmentCopy] {
        let cleanTitle = task.originalTitle.split(whereSeparator: {
            $0.isWhitespace || $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || "/\\:".unicodeScalars.contains($0) }
        }).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let title = String(String.UnicodeScalarView(cleanTitle.unicodeScalars.prefix(40)))
        let date = task.assignedDay.flatMap(Beijing.parseDay).map(Beijing.day).map { $0 + " " } ?? ""
        let folder = base.appendingPathComponent("\(date)\(title.isEmpty ? "Assignment" : title) [\(key(task.id))]", isDirectory: true)
        let sources = task.attachments.compactMap { source(for: $0, in: root) }
        let repetitions = Dictionary(grouping: sources) { $0.lastPathComponent.lowercased() }
        return sources.map { file in
            let name: String
            if repetitions[file.lastPathComponent.lowercased(), default: []].count > 1 {
                let stem = String(file.deletingPathExtension().lastPathComponent.prefix(42))
                let ext = file.pathExtension.isEmpty ? "" : "." + file.pathExtension
                name = "\(stem) [\(key(file.path))]\(ext)"
            } else {
                name = file.lastPathComponent
            }
            return AttachmentCopy(source: file, folder: folder, destination: folder.appendingPathComponent(name))
        }
    }

    static func readableCopy(_ copy: AttachmentCopy, in base: URL) -> URL? {
        hasSafePath(copy, in: base) && isFile(copy.destination) ? copy.destination : nil
    }

    static func makeCopy(_ copy: AttachmentCopy, in base: URL) throws {
        let files = FileManager.default
        guard hasSafePath(copy, in: base) else { throw CocoaError(.fileWriteNoPermission) }
        if isFile(copy.destination) { return }
        try files.createDirectory(at: copy.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard hasSafePath(copy, in: base) else { throw CocoaError(.fileWriteNoPermission) }
        let staging = copy.folder.appendingPathComponent(".download-\(UUID().uuidString)")
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: copy.source, to: staging)
        do { try files.moveItem(at: staging, to: copy.destination) }
        catch { if !isFile(copy.destination) { throw error } }
    }

    private static func hasSafePath(_ copy: AttachmentCopy, in base: URL) -> Bool {
        let folder = copy.folder.standardizedFileURL
        let file = copy.destination.standardizedFileURL
        let base = base.resolvingSymlinksInPath().standardizedFileURL
        let expected = base.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        return folder.resolvingSymlinksInPath().path == expected.path &&
            file.resolvingSymlinksInPath().path == expected.appendingPathComponent(file.lastPathComponent).path
    }

    private static func isFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
