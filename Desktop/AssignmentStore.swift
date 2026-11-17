import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct BackendEvent: Decodable {
    let event: String
    let data: AssignmentSnapshot?
    let operation: String?
    let error: String?
    let requiresLogin: Bool?
}

@MainActor
final class AssignmentStore: ObservableObject {
    @Published var filters: AssignmentFilters {
        didSet {
            if let saved = try? JSONEncoder().encode(filters) { defaults.set(saved, forKey: "filters") }
            keepSelection()
        }
    }
    @Published var automatic: Bool {
        didSet {
            defaults.set(automatic, forKey: "automatic")
            if automatic { pulse() }
        }
    }
    @Published var floatingTimetable: Bool {
        didSet { defaults.set(floatingTimetable, forKey: "floatingTimetable") }
    }
    @Published var selectedID: String?
    @Published var settingsOpen = false
    @Published var schoolLoginOpen = false
    @Published var page: DeskPage = .assignments
    @Published private(set) var loading = true
    @Published private(set) var working: String?
    @Published private(set) var requesting = false
    @Published private(set) var snapshot = AssignmentSnapshot()
    @Published private(set) var now = Date()
    @Published private(set) var syncIssue: String?
    @Published private(set) var needsLogin = false
    @Published private(set) var settingsIssue: String?
    @Published private(set) var settingsNotice: String?
    @Published private(set) var timetableIssue: String?
    @Published private(set) var timetableNeedsLogin = false

    let root: URL
    private let resources: URL?
    private let defaults = UserDefaults.standard
    private var process: Process?
    private var input: FileHandle?
    private var timer: Timer?
    private var refreshAfterRequest = false
    private var timetableAfterRequest = false

    init(root: URL, resources: URL? = nil) {
        self.root = root
        self.resources = resources
        let data = UserDefaults.standard.data(forKey: "filters")
        filters = data.flatMap { try? JSONDecoder().decode(AssignmentFilters.self, from: $0) } ?? AssignmentFilters()
        automatic = UserDefaults.standard.object(forKey: "automatic") as? Bool ?? true
        floatingTimetable = UserDefaults.standard.object(forKey: "floatingTimetable") as? Bool ?? (resources == nil)
        if let cached = try? Data(contentsOf: root.appendingPathComponent("data/timetable.json")) {
            snapshot.timetable = try? Self.backendDecoder().decode(Timetable.self, from: cached)
        }
    }

    var rows: [Assignment] { filters.apply(to: snapshot.tasks, now: now) }
    var pendingCount: Int { rows.filter(\.pending).count }
    var needsSetup: Bool { !loading && !snapshot.hasSession && !snapshot.autoLogin }
    var currentLesson: SchoolLesson? { snapshot.timetable?.current(at: now) }
    var nextLesson: SchoolLesson? { snapshot.timetable?.next(after: now) }
    var timetableCoversToday: Bool { snapshot.timetable?.covers(now) == true }
    var courses: [(id: String, label: String)] {
        var values = [String: String]()
        for task in snapshot.tasks { values[task.course] = task.subject }
        return values.map { (id: $0.key, label: $0.value) }.sorted {
            $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    var inSchedule: Bool { Self.inSchedule(at: now) }

    private static func inSchedule(at date: Date) -> Bool {
        let parts = Beijing.calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else { return false }
        return (2...6).contains(weekday) && ((8..<20).contains(hour) || (hour == 20 && minute == 0))
    }

    var syncRecoveryHint: String? {
        guard !needsLogin, let retry = Beijing.parse(snapshot.retryAt) else { return nil }
        if working == "sync" { return "正在重试…" }
        if !automatic { return "自动重试已暂停" }
        if !inSchedule || !Self.inSchedule(at: max(now, retry)) { return "将在同步时段重试" }
        let seconds = retry.timeIntervalSince(now)
        if seconds <= 0 { return "等待自动重试" }
        if seconds < 60 { return "约 \(Int(seconds.rounded(.up))) 秒后自动重试" }
        return "预计 \(Beijing.clock(retry)) 自动重试"
    }

    var lastSync: String {
        guard let date = Beijing.parse(snapshot.checkedAt) else { return "尚未同步" }
        return "上次同步 \(Beijing.dueLabel(date, relativeTo: now))"
    }

    func start() {
        if timer == nil {
            let ticker = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pulse() }
            }
            RunLoop.main.add(ticker, forMode: .common)
            timer = ticker
        }
        guard process == nil else { return }
        do {
            try connect()
            pulse()
        } catch {
            loading = false
            syncIssue = error.localizedDescription
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopBackend()
    }

    private func stopBackend() {
        try? input?.close()
        if let process, process.isRunning { process.interrupt() }
        process = nil
        input = nil
    }

    func pulse() {
        now = Date()
        keepSelection()
        if !requesting && !schoolLoginOpen {
            send(["action": "poll", "automatic": automatic && !loading && !needsSetup])
        }
    }

    func sync() {
        if needsSetup {
            settingsOpen = true
            return
        }
        guard !requesting else {
            if working != "sync" { refreshAfterRequest = true }
            return
        }
        if process == nil { start() }
        if requesting {
            refreshAfterRequest = true
        } else {
            send(["action": "sync"])
        }
    }

    func refreshTimetable() {
        if needsSetup {
            settingsOpen = true
            return
        }
        if process == nil { start() }
        guard process != nil else {
            timetableIssue = syncIssue
            return
        }
        if requesting {
            if working != "timetable" { timetableAfterRequest = true }
        } else {
            send(["action": "timetable"])
        }
    }

    func configure(name: String, password: String) {
        guard !requesting else { return }
        settingsIssue = nil
        settingsNotice = nil
        send(["action": "configure", "name": name, "password": password])
    }

    func verifyLogin() {
        guard !requesting else { return }
        settingsIssue = nil
        settingsNotice = nil
        schoolLoginOpen = true
    }

    func saveBrowserSession(_ cookies: [[String: Any]]) {
        guard !requesting, !cookies.isEmpty else { return }
        settingsIssue = nil
        send(["action": "verify", "cookies": cookies])
    }

    func resetFilters() {
        var defaults = AssignmentFilters()
        defaults.range = filters.range
        filters = defaults
    }

    func exportChecklist() {
        let tasks = rows
        guard tasks.contains(where: \.pending) else { return }
        let text = MarkdownChecklist.text(tasks: tasks, range: filters.range, now: now)
        let panel = NSSavePanel()
        panel.title = "导出作业待办"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "作业待办-\(Beijing.day(now)).md"
        panel.canCreateDirectories = true
        let write: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self?.showError("保存待办失败。", detail: error.localizedDescription)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            panel.begin(completionHandler: write)
        }
    }

    func localURL(for attachment: Attachment) -> URL? {
        guard let path = attachment.localPath else { return nil }
        let folder = root.appendingPathComponent("data/tasks").resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard file.path.hasPrefix(folder.path + "/"),
              FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue
        else { return nil }
        return file
    }

    func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) { showError("无法打开文件或链接。", detail: nil) }
    }

    func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func keepSelection() {
        let visible = rows
        if let selectedID, visible.contains(where: { $0.id == selectedID }) { return }
        selectedID = visible.first?.id
    }

    private func showError(_ text: String, detail: String?) {
        let alert = NSAlert()
        alert.messageText = text
        alert.informativeText = detail ?? ""
        alert.alertStyle = .warning
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func connect() throws {
        guard let resources else {
            throw NSError(domain: "AssignmentStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "应用文件不完整，请重新运行「安装并打开.command」。"
            ])
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let files = FileManager.default
        let backend = resources.appendingPathComponent("Backend/desktop_bridge.py")
        let runtime = resources.appendingPathComponent("Python/\(architecture)")
        let python = runtime.appendingPathComponent("bin/python3.13")
        guard files.fileExists(atPath: backend.path), files.isExecutableFile(atPath: python.path) else {
            throw NSError(domain: "AssignmentStore", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "同步模块不完整，请重新运行「安装并打开.command」。"
            ])
        }
        try files.createDirectory(at: root, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        var environment = ProcessInfo.processInfo.environment
        environment["SP_ASSIGNMENTS_HOME"] = root.path
        environment["SP_ASSIGNMENTS_MODEL_DIR"] = resources.appendingPathComponent("Models/en-zh").path
        environment["SSL_CERT_FILE"] = runtime.appendingPathComponent("lib/python3.13/site-packages/certifi/cacert.pem").path
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = python
        child.arguments = ["-E", "-s", "-B", "-u", backend.path]
        child.currentDirectoryURL = root
        child.environment = environment
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        let reader = stdout.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let decoder = Self.backendDecoder()
            var buffer = Data()
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let end = buffer.firstIndex(of: 0x0a) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    guard let event = try? decoder.decode(BackendEvent.self, from: line) else { continue }
                    DispatchQueue.main.async { self?.receive(event) }
                }
            }
            DispatchQueue.main.async { self?.disconnected() }
        }
    }

    private nonisolated static func backendDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func send(_ request: [String: Any]) {
        guard let input else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(0x0a)
            try input.write(contentsOf: data)
            requesting = true
        } catch {
            disconnected()
        }
    }

    private func disconnected() {
        guard process != nil else { return }
        stopBackend()
        requesting = false
        loading = false
        working = nil
        refreshAfterRequest = false
        timetableAfterRequest = false
        timetableIssue = "课表同步服务已退出。点「刷新课表」重试。"
        syncIssue = "同步服务已退出。点「立即同步」重试。"
    }

    private func receive(_ event: BackendEvent) {
        switch event.event {
        case "snapshot":
            guard let data = event.data else { return }
            snapshot = data
            syncIssue = data.syncError
            needsLogin = data.requiresLogin
            loading = false
            keepSelection()
        case "working":
            working = event.operation
        case "finished":
            requesting = false
            working = nil
            loading = false
            if event.operation == "configure" || event.operation == "verify" {
                settingsIssue = event.error
                if event.error == nil {
                    if event.operation == "verify" { schoolLoginOpen = false }
                    settingsNotice = event.operation == "configure" ? "自动登录已启用。" : "学校会话已更新。"
                    syncIssue = nil
                    needsLogin = false
                    refreshAfterRequest = true
                }
            } else if let error = event.error {
                if event.operation != "timetable" {
                    syncIssue = error
                    needsLogin = event.requiresLogin == true
                }
            }
            if event.operation == "timetable" {
                timetableIssue = event.error
                timetableNeedsLogin = event.requiresLogin == true
                timetableAfterRequest = false
            }
            if timetableAfterRequest {
                timetableAfterRequest = false
                refreshTimetable()
            } else if refreshAfterRequest {
                refreshAfterRequest = false
                sync()
            }
        default:
            break
        }
    }
}
