import Foundation

enum DateRange: String, CaseIterable, Codable, Identifiable {
    case today = "今天", yesterday = "昨天", three = "近 3 天", seven = "近 7 天", month = "本月"
    var id: Self { self }

    func contains(_ day: String?, relativeTo now: Date) -> Bool {
        let today = Beijing.day(now)
        if self == .month {
            return day?.hasPrefix(String(today.prefix(7))) ?? true
        }
        guard let day else { return false }
        let startOffset = self == .seven ? -6 : self == .three ? -2 : self == .yesterday ? -1 : 0
        let start = Beijing.day(Beijing.calendar.date(byAdding: .day, value: startOffset, to: now) ?? now)
        return day >= start && day <= (self == .yesterday ? start : today)
    }
}

enum TaskType: String, CaseIterable, Codable, Identifiable {
    case homework = "作业", pending = "待办", grades = "成绩", records = "仅记录", uncertain = "待确认"
    var id: Self { self }

    func includes(_ task: Assignment) -> Bool {
        switch self {
        case .homework: task.kind == "assignment" || task.kind == "confirm"
        case .pending: task.pending
        case .grades: task.grade != nil
        case .records: task.kind == "record"
        case .uncertain: task.kind == "uncertain"
        }
    }
}

enum Submission: String, CaseIterable, Codable, Identifiable {
    case unsubmitted, submitted
    var id: Self { self }
    var label: String { self == .unsubmitted ? "未提交" : "已提交" }
}

struct AssignmentFilters: Codable, Equatable {
    var range: DateRange = .today
    var types: Set<TaskType> = [.homework]
    var courses: Set<String> = []
    var submissions: Set<Submission> = []
    var search = ""

    var activeCount: Int {
        (types == [.homework] ? 0 : max(types.count, 1)) + courses.count + submissions.count
    }

    func apply(to tasks: [Assignment], now: Date) -> [Assignment] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return tasks.filter { task in
            range.contains(task.assignedDay, relativeTo: now)
                && (types.isEmpty || types.contains { $0.includes(task) })
                && (courses.isEmpty || courses.contains(task.course))
                && (submissions.isEmpty || submissions.contains { $0.rawValue == task.submissionBucket })
                && (query.isEmpty || task.searchable.localizedStandardContains(query))
        }.sorted { left, right in
            if left.assignedDay != right.assignedDay { return (left.assignedDay ?? "") > (right.assignedDay ?? "") }
            if left.pending != right.pending { return left.pending }
            let leftDue = Beijing.parse(left.due) ?? .distantFuture
            let rightDue = Beijing.parse(right.due) ?? .distantFuture
            if (leftDue < now) != (rightDue < now) { return rightDue < now }
            if leftDue != rightDue { return leftDue < rightDue }
            return left.id < right.id
        }
    }
}

struct Assignment: Decodable, Identifiable {
    let id, course, subject, title, brief: String
    let kind, status, submissionBucket, originalTitle, original, taskType: String
    let submission, grade, assignedDay, due: String?
    let actions: [String]
    let attachments: [Attachment]
    let pending, translated, detailPending: Bool

    var searchable: String {
        [brief, title, originalTitle, original, subject, course, taskType,
         attachments.map(\.name).joined(separator: " ")].joined(separator: "\n")
    }

    func overdue(at now: Date) -> Bool {
        pending && (Beijing.parse(due) ?? .distantFuture) < now
    }
}

struct Attachment: Decodable {
    let name: String
    let url, localPath, downloadStatus: String?

    var originalURL: URL? {
        guard let url, let parts = URLComponents(string: url),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil
        else { return nil }
        return parts.url
    }
}

struct AssignmentSnapshot: Decodable {
    var checkedAt: String? = nil
    var tasks: [Assignment] = []
    var warningCount = 0
    var autoLogin = false
    var hasSession = false
    var syncError: String? = nil
    var retryAt: String? = nil
    var requiresLogin = false
    var timetable: Timetable? = nil
}

struct TaskDay: Identifiable {
    let id: String
    let tasks: [Assignment]

    var label: String {
        Beijing.parseDay(id).map(Beijing.dayLabel) ?? "日期未注明"
    }

    static func groups(_ sortedTasks: [Assignment]) -> [TaskDay] {
        let grouped = Dictionary(grouping: sortedTasks) { $0.assignedDay ?? "" }
        return grouped.keys.sorted(by: >).map { TaskDay(id: $0, tasks: grouped[$0] ?? []) }
    }
}

enum Beijing {
    static let zone = TimeZone(identifier: "Asia/Shanghai")!
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = 2
        return calendar
    }()

    private static let iso = ISO8601DateFormatter()
    private static let dayFormat = formatter("yyyy-MM-dd", locale: "en_US_POSIX")
    private static let calendarFormat = formatter("M月d日 EEEE")
    private static let clockFormat = formatter("HH:mm")
    private static let dateTimeFormat = formatter("M月d日 HH:mm")
    private static let shortDayFormat = formatter("M月d日")
    private static let weekdayFormat = formatter("EEE")
    private static let exportFormat = formatter("yyyy-MM-dd HH:mm", locale: "en_US_POSIX")

    private static func formatter(_ pattern: String, locale: String = "zh_CN") -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.dateFormat = pattern
        return formatter
    }

    static func parse(_ value: String?) -> Date? { value.flatMap { iso.date(from: $0) } }
    static func parseDay(_ value: String) -> Date? { dayFormat.date(from: value) }
    static func day(_ date: Date) -> String { dayFormat.string(from: date) }
    static func dayLabel(_ date: Date) -> String { calendarFormat.string(from: date) }
    static func clock(_ date: Date) -> String { clockFormat.string(from: date) }
    static func dateTime(_ date: Date) -> String { dateTimeFormat.string(from: date) }
    static func shortDay(_ date: Date) -> String { shortDayFormat.string(from: date) }
    static func weekday(_ date: Date) -> String { weekdayFormat.string(from: date) }
    static func exportTime(_ date: Date) -> String { exportFormat.string(from: date) }

    static func dueLabel(_ date: Date, relativeTo now: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "今天 \(clock(date))" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "明天 \(clock(date))" }
        return dateTime(date)
    }
}

enum MarkdownChecklist {
    static func text(tasks: [Assignment], range: DateRange, now: Date) -> String {
        let pending = tasks.filter(\.pending)
        var lines = ["# 作业待办", "", "\(Beijing.day(now)) · \(range.rawValue) · \(pending.count) 项 · 北京时间"]
        for day in TaskDay.groups(pending) {
            lines += ["", "## \(day.id.isEmpty ? "布置日期未注明" : day.id)", ""]
            for task in day.tasks {
                let deadline = Beijing.parse(task.due).map { "截止 " + Beijing.exportTime($0) } ?? "截止未注明"
                let overdue = task.overdue(at: now) ? "（逾期）" : ""
                lines.append("- [ ] **\(escape(task.subject))**：\(escape(task.brief)) · \(deadline)\(overdue)")
                if let submission = task.submission, !task.brief.contains(submission) {
                    lines.append("  - 怎么交：\(escape(submission))")
                }
                let links = task.attachments.compactMap { attachment -> String? in
                    guard let url = attachment.originalURL else { return nil }
                    return "[\(escape(attachment.name))](<\(url.absoluteString)>)"
                }
                if !links.isEmpty { lines.append("  - 附件：" + links.joined(separator: "、")) }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func escape(_ text: String) -> String {
        let reserved = "\\*_~[]<>\u{60}"
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.map { reserved.contains($0) ? "\\" + String($0) : String($0) }.joined()
    }
}
