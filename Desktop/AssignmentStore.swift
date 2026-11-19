import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

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
    enum PinScope: Equatable {
        case global, filtered
    }
    @Published private(set) var globalPins: Set<String> {
        didSet { defaults.set(globalPins.sorted(), forKey: "pinnedAssignmentsGlobal") }
    }
    @Published private(set) var filterPins: Set<String> {
        didSet { defaults.set(filterPins.sorted(), forKey: "pinnedAssignmentsFiltered") }
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

    let assistant: HomeworkAssistant
    let root: URL
    private let resources: URL?
    private let defaults = UserDefaults.standard
    private var process: Process?
    private var input: FileHandle?
    private var timer: Timer?
    private var requestedAction: String?
    private var reconnectAt = Date.distantPast
    private var refreshAfterRequest = false
    private var timetableAfterRequest = false

    init(root: URL, resources: URL? = nil) {
        self.assistant = HomeworkAssistant(root: root)
        self.root = root
        self.resources = resources
        let data = UserDefaults.standard.data(forKey: "filters")
        filters = data.flatMap { try? JSONDecoder().decode(AssignmentFilters.self, from: $0) } ?? AssignmentFilters()
        automatic = UserDefaults.standard.object(forKey: "automatic") as? Bool ?? true
        floatingTimetable = UserDefaults.standard.object(forKey: "floatingTimetable") as? Bool ?? (resources == nil)
        var globals = Set(UserDefaults.standard.stringArray(forKey: "pinnedAssignmentsGlobal") ?? [])
        filterPins = Set(UserDefaults.standard.stringArray(forKey: "pinnedAssignmentsFiltered") ?? [])
        if let legacy = UserDefaults.standard.stringArray(forKey: "pinnedAssignments"), !legacy.isEmpty {
            globals.formUnion(legacy)
            UserDefaults.standard.set(globals.sorted(), forKey: "pinnedAssignmentsGlobal")
            UserDefaults.standard.removeObject(forKey: "pinnedAssignments")
        }
        globalPins = globals
        if let cached = try? Data(contentsOf: root.appendingPathComponent("data/timetable.json")) {
            snapshot.timetable = try? Self.backendDecoder().decode(Timetable.self, from: cached)
        }
    }

    var rows: [Assignment] { filters.apply(to: snapshot.tasks, now: now) }
    var pendingCount: Int { rows.filter(\.pending).count }
    var globalPinnedTasks: [Assignment] {
        Self.pinnedOrder(snapshot.tasks.filter { globalPins.contains($0.id) })
    }
    var pinnedTasks: [Assignment] {
        globalPinnedTasks + rows.filter { filterPins.contains($0.id) && !globalPins.contains($0.id) }
    }

    private static func pinnedOrder(_ tasks: [Assignment]) -> [Assignment] {
        tasks.sorted { left, right in
            if left.assignedDay != right.assignedDay { return (left.assignedDay ?? "") > (right.assignedDay ?? "") }
            let leftDue = Beijing.parse(left.due) ?? .distantFuture
            let rightDue = Beijing.parse(right.due) ?? .distantFuture
            if leftDue != rightDue { return leftDue < rightDue }
            return left.id < right.id
        }
    }

    func pinState(_ id: String) -> PinScope? {
        if globalPins.contains(id) { return .global }
        if filterPins.contains(id) { return .filtered }
        return nil
    }

    func setPin(_ id: String, scope: PinScope) {
        globalPins.remove(id)
        filterPins.remove(id)
        switch scope {
        case .global: globalPins.insert(id)
        case .filtered: filterPins.insert(id)
        }
        keepSelection()
    }

    func unpin(_ id: String) {
        globalPins.remove(id)
        filterPins.remove(id)
        keepSelection()
    }

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
        let chinese = defaults.string(forKey: "interfaceLanguage") != "en"
        if working == "sync" { return chinese ? "正在重试…" : "Retrying…" }
        if !automatic { return chinese ? "自动重试已暂停" : "Automatic retry paused" }
        if !inSchedule || !Self.inSchedule(at: max(now, retry)) {
            return chinese ? "将在同步时段重试" : "Will retry during sync hours"
        }
        let seconds = retry.timeIntervalSince(now)
        if seconds <= 0 { return chinese ? "等待自动重试" : "Waiting to retry" }
        if seconds < 60 {
            let remaining = Int(seconds.rounded(.up))
            return chinese ? "约 \(remaining) 秒后自动重试" : "Retrying in about \(remaining) seconds"
        }
        let time = Beijing.clock(retry)
        return chinese ? "预计 \(time) 自动重试" : "Retry scheduled for \(time)"
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
            reconnectAt = Date().addingTimeInterval(30)
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
        if !loading { assistant.update(snapshot.tasks) }
        keepSelection()
        if !requesting && !settingsOpen && !schoolLoginOpen {
            if process == nil, automatic, now >= reconnectAt {
                do { try connect() }
                catch {
                    syncIssue = error.localizedDescription
                    reconnectAt = now.addingTimeInterval(30)
                }
            }
            send(["action": "poll", "automatic": automatic && !loading && !needsSetup,
                  "language": defaults.string(forKey: "interfaceLanguage") ?? "zh-Hans"])
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

    func configure(name: String, password: String) -> Bool {
        guard !requesting else { return false }
        settingsIssue = nil
        settingsNotice = nil
        return sendLoginRequest(["action": "configure", "name": name, "password": password])
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
        sendLoginRequest(["action": "verify", "cookies": cookies])
    }

    @discardableResult
    private func sendLoginRequest(_ request: [String: Any]) -> Bool {
        do {
            if process == nil { try connect() }
            if send(request) { return true }
            settingsIssue = "The sync service stopped. Try verifying again."
        } catch {
            settingsIssue = error.localizedDescription
        }
        return false
    }

    func resetFilters() {
        var defaults = AssignmentFilters()
        defaults.range = filters.range
        filters = defaults
    }

    func exportChecklist() {
        let tasks = rows
        guard tasks.contains(where: \.pending) else { return }
        let chinese = defaults.string(forKey: "interfaceLanguage") != "en"
        let text = MarkdownChecklist.text(tasks: tasks, range: filters.effectiveRange, now: now, inChinese: chinese)
        let panel = NSSavePanel()
        panel.title = chinese ? "导出作业待办" : "Export Assignment To-Do List"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = (chinese ? "作业待办-" : "Assignment-To-Do-") + "\(Beijing.day(now)).md"
        panel.canCreateDirectories = true
        let write: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self?.showError("Could not save the to-do list.", detail: error.localizedDescription)
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
        if !NSWorkspace.shared.open(url) { showError("Could not open the file or link.", detail: nil) }
    }

    func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func keepSelection() {
        let visible = rows
        if let selectedID,
           visible.contains(where: { $0.id == selectedID }) ||
            globalPinnedTasks.contains(where: { $0.id == selectedID }) { return }
        selectedID = pinnedTasks.first?.id ?? visible.first?.id
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
                NSLocalizedDescriptionKey: "The app is incomplete. Run the installer again."
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
                NSLocalizedDescriptionKey: "The sync module is incomplete. Run the installer again."
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak child] in
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
                    DispatchQueue.main.async {
                        guard let self, let child, self.process === child else { return }
                        self.receive(event)
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self, let child, self.process === child else { return }
                self.disconnected()
            }
        }
    }

    private nonisolated static func backendDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @discardableResult
    private func send(_ request: [String: Any]) -> Bool {
        guard let input else { return false }
        do {
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(0x0a)
            try input.write(contentsOf: data)
            requesting = true
            requestedAction = request["action"] as? String
            return true
        } catch {
            disconnected()
            return false
        }
    }

    private func disconnected() {
        guard process != nil else { return }
        if requestedAction == "configure" || requestedAction == "verify" {
            settingsIssue = "The sync service stopped. Try verifying again."
        }
        requestedAction = nil
        reconnectAt = Date().addingTimeInterval(15)
        stopBackend()
        requesting = false
        loading = false
        working = nil
        refreshAfterRequest = false
        timetableAfterRequest = false
        timetableIssue = "The timetable sync service stopped. Click Refresh Timetable to try again."
        syncIssue = "The sync service stopped. Click Sync Now to try again."
    }

    private func receive(_ event: BackendEvent) {
        switch event.event {
        case "snapshot":
            guard let data = event.data else { return }
            if data.timetable?.checkedAt != snapshot.timetable?.checkedAt {
                WidgetCenter.shared.reloadTimelines(ofKind: "TimetableWidget")
            }
            snapshot = data
            syncIssue = data.syncError
            needsLogin = data.requiresLogin
            loading = false
            keepSelection()
        case "working":
            working = event.operation
        case "finished":
            requesting = false
            requestedAction = nil
            working = nil
            loading = false
            if event.operation == "configure" || event.operation == "verify" {
                settingsIssue = event.error
                if event.error == nil {
                    if event.operation == "verify" { schoolLoginOpen = false }
                    settingsNotice = event.operation == "configure" ? "Automatic login is enabled." : "School session updated."
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
