import Darwin
import Foundation

/// Watches a folder (Downloads by default) and reports files that appear after the watcher starts.
/// Used so AirDropped work files can be attached to the assignment currently being written.
@MainActor
final class DropInbox {
    var onNewFiles: (([URL]) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var folder: URL?
    private var started = Date()

    var isRunning: Bool { source != nil }

    func setEnabled(_ enabled: Bool, folder: URL) {
        stop()
        self.folder = folder
        guard enabled else { return }
        known = Set(list(folder).map(key))
        started = Date()
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write], queue: .main)
        watcher.setEventHandler { [weak self] in self?.scan() }
        watcher.setCancelHandler { close(descriptor) }
        watcher.resume()
        source = watcher
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func list(_ folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    private func key(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(url.lastPathComponent)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    private func scan() {
        guard let folder else { return }
        let files = list(folder)
        let fresh = files.filter { !known.contains(key($0)) }
        known.formUnion(files.map(key))
        let ready = fresh.filter { url in
            let ext = url.pathExtension.lowercased()
            guard !["download", "crdownload", "part", "tmp"].contains(ext) else { return false }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantPast) >= started.addingTimeInterval(-2) else { return false }
            return (values.fileSize ?? 0) > 0
        }
        guard !ready.isEmpty else { return }
        onNewFiles?(ready)
    }
}
