import Foundation

enum DateRange: String, CaseIterable, Codable, Identifiable {
    case today = "Today", yesterday = "Yesterday", three = "Last 3 Days", seven = "Last 7 Days", month = "This Month", all = "All Dates"
    var id: Self { self }

    func contains(_ day: String?, relativeTo now: Date) -> Bool {
        let today = Beijing.day(now)
        if self == .all { return true }
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
    case homework = "Homework", pending = "To Do", grades = "Grades", records = "Records", uncertain = "Needs Review"
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
    var label: String { self == .unsubmitted ? "Not Submitted" : "Submitted" }
}

enum AssignmentQuickFilter: String, CaseIterable, Codable, Identifiable {
    case overdue = "Overdue"
    case dueToday = "Due Today"
    case hasAttachments = "Has Attachments"
    var id: Self { self }
}

struct AssignmentFilters: Codable, Equatable {
    var range: DateRange = .today
    var types: Set<TaskType> = [.homework]
    var courses: Set<String> = []
    var submissions: Set<Submission> = []
    var quickFilters: Set<AssignmentQuickFilter> = []
    var deadlineView = false
    var search = ""

    private enum CodingKeys: String, CodingKey { case range, types, courses, submissions, quickFilters, search, deadlineView }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let oldDates: [String: DateRange] = ["今天": .today, "昨天": .yesterday, "近 3 天": .three,
                                             "近 7 天": .seven, "本月": .month]
        let oldTypes: [String: TaskType] = ["作业": .homework, "待办": .pending, "成绩": .grades,
                                            "仅记录": .records, "待确认": .uncertain]
        let savedRange = try values.decodeIfPresent(String.self, forKey: .range) ?? ""
        range = DateRange(rawValue: savedRange) ?? oldDates[savedRange] ?? .today
        if let savedTypes = try values.decodeIfPresent([String].self, forKey: .types) {
            types = Set(savedTypes.compactMap { TaskType(rawValue: $0) ?? oldTypes[$0] })
        }
        courses = try values.decodeIfPresent(Set<String>.self, forKey: .courses) ?? []
        submissions = try values.decodeIfPresent(Set<Submission>.self, forKey: .submissions) ?? []
        quickFilters = try values.decodeIfPresent(Set<AssignmentQuickFilter>.self, forKey: .quickFilters) ?? []
        deadlineView = try values.decodeIfPresent(Bool.self, forKey: .deadlineView) ?? false
        search = try values.decodeIfPresent(String.self, forKey: .search) ?? ""
    }

    var activeCount: Int {
        (types == [.homework] ? 0 : max(types.count, 1)) + courses.count + submissions.count + quickFilters.count
    }

    var usesAllAssignedDates: Bool {
        deadlineView || !quickFilters.isDisjoint(with: [.overdue, .dueToday])
    }

    var effectiveRange: DateRange { usesAllAssignedDates ? .all : range }

    func apply(to tasks: [Assignment], now: Date) -> [Assignment] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let dueFilters = quickFilters.intersection([.overdue, .dueToday])
        return tasks.filter { task in
            effectiveRange.contains(task.assignedDay, relativeTo: now)
                && (types.isEmpty || types.contains { $0.includes(task) })
                && (courses.isEmpty || courses.contains(task.course))
                && (submissions.isEmpty || submissions.contains { $0.rawValue == task.submissionBucket })
                && (dueFilters.isEmpty || dueFilters.contains { filter in
                    filter == .overdue ? task.overdue(at: now) : task.dueToday(at: now)
                })
                && (!quickFilters.contains(.hasAttachments) || !task.attachments.isEmpty)
                && (query.isEmpty || task.searchable.localizedStandardContains(query))
        }.sorted { left, right in
            if deadlineView {
                if left.pending != right.pending { return left.pending }
                let a = Beijing.parse(left.due) ?? .distantFuture
                let b = Beijing.parse(right.due) ?? .distantFuture
                return a == b ? left.id < right.id : a < b
            }
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

    var statusLabel: String {
        ["免交": "Exempt", "仅记录": "Record Only", "待确认": "Needs Review",
         "待确认完成": "Confirm Completion", "未提交（已关闭）": "Not Submitted (Closed)",
         "未提交": "Not Submitted", "已批改": "Graded", "批改中": "Being Graded",
         "延迟完成": "Submitted Late", "抄袭": "Flagged for Plagiarism", "已提交": "Submitted",
         "提交已关闭": "Submission Closed", "已归档": "Archived", "按时完成": "Completed On Time",
         "未完成": "Incomplete", "待提交": "Not Submitted", "状态未知": "Status Unknown"][status] ?? status
    }

    var searchable: String {
        [brief, title, originalTitle, original, subject, course, taskType,
         attachments.map(\.name).joined(separator: " ")].joined(separator: "\n")
    }

    func overdue(at now: Date) -> Bool {
        pending && (Beijing.parse(due) ?? .distantFuture) < now
    }

    func dueToday(at now: Date) -> Bool {
        Beijing.parse(due).map { Beijing.calendar.isDate($0, inSameDayAs: now) } == true
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
    var gradeBook: SemesterGradeBook? = nil
}

struct TaskDay: Identifiable {
    let id: String
    let tasks: [Assignment]

    var label: String {
        Beijing.parseDay(id).map(Beijing.dayLabel) ?? (id.isEmpty ? "Date not specified" : id)
    }

    static func deadlineGroups(_ tasks: [Assignment]) -> [TaskDay] {
        var result: [TaskDay] = []
        for task in tasks {
            let key = task.pending ? (Beijing.parse(task.due).map(Beijing.day) ?? "No due date") : "Completed"
            if let index = result.firstIndex(where: { $0.id == key }) {
                result[index] = TaskDay(id: key, tasks: result[index].tasks + [task])
            } else { result.append(TaskDay(id: key, tasks: [task])) }
        }
        return result
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
    private static let calendarFormat = formatter("MMM d, EEEE", locale: "en_US")
    private static let clockFormat = formatter("HH:mm")
    private static let dateTimeFormat = formatter("MMM d HH:mm", locale: "en_US")
    private static let shortDayFormat = formatter("MMM d", locale: "en_US")
    private static let weekdayFormat = formatter("EEE")
    private static let chineseCalendarFormat = formatter("M月d日 EEEE", locale: "zh_CN")
    private static let chineseDateTimeFormat = formatter("M月d日 HH:mm", locale: "zh_CN")
    private static let chineseShortDayFormat = formatter("M月d日", locale: "zh_CN")
    private static let chineseWeekdayFormat = formatter("EEE", locale: "zh_CN")
    private static let exportFormat = formatter("yyyy-MM-dd HH:mm", locale: "en_US_POSIX")

    private static var displaysChinese: Bool {
        let language = UserDefaults.standard.string(forKey: "interfaceLanguage") ?? Locale.preferredLanguages.first
        return language?.hasPrefix("zh") == true
    }

    private static func formatter(_ pattern: String, locale: String = "en_US") -> DateFormatter {
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
    static func dayLabel(_ date: Date) -> String { (displaysChinese ? chineseCalendarFormat : calendarFormat).string(from: date) }
    static func clock(_ date: Date) -> String { clockFormat.string(from: date) }
    static func dateTime(_ date: Date) -> String { (displaysChinese ? chineseDateTimeFormat : dateTimeFormat).string(from: date) }
    static func shortDay(_ date: Date) -> String { shortDay(date, chinese: displaysChinese) }
    static func shortDay(_ date: Date, chinese: Bool) -> String { (chinese ? chineseShortDayFormat : shortDayFormat).string(from: date) }
    static func weekday(_ date: Date) -> String { (displaysChinese ? chineseWeekdayFormat : weekdayFormat).string(from: date) }
    static func exportTime(_ date: Date) -> String { exportFormat.string(from: date) }

    static func dueLabel(_ date: Date, relativeTo now: Date, chinese language: Bool? = nil) -> String {
        let chinese = language ?? displaysChinese
        if calendar.isDate(date, inSameDayAs: now) { return (chinese ? "今天 " : "Today ") + clock(date) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return (chinese ? "明天 " : "Tomorrow ") + clock(date) }
        return (chinese ? chineseDateTimeFormat : dateTimeFormat).string(from: date)
    }
}

enum MarkdownChecklist {
    static func text(tasks: [Assignment], range: DateRange, now: Date, inChinese: Bool = false) -> String {
        let pending = tasks.filter(\.pending)
        let chineseStrings = Bundle.main.url(forResource: "zh-Hans", withExtension: "lproj").flatMap(Bundle.init(url:))
        let rangeName = inChinese ? (chineseStrings?.localizedString(forKey: range.rawValue, value: nil, table: nil) ?? range.rawValue) : range.rawValue
        let count = inChinese ? "\(pending.count) 项待办 · 北京时间" : "\(pending.count) tasks · China Standard Time"
        var lines = [inChinese ? "# 作业待办" : "# Assignment To-Do List", "", "\(Beijing.day(now)) · \(rangeName) · \(count)"]
        for day in TaskDay.groups(pending) {
            let heading = day.id.isEmpty ? (inChinese ? "布置日期未注明" : "Assignment date not specified") : day.id
            lines += ["", "## \(heading)", ""]
            for task in day.tasks {
                let deadline = Beijing.parse(task.due).map { (inChinese ? "截止 " : "Due ") + Beijing.exportTime($0) }
                    ?? (inChinese ? "未设截止日期" : "No due date")
                let overdue = task.overdue(at: now) ? (inChinese ? "（逾期）" : " (Overdue)") : ""
                lines.append("- [ ] **\(escape(task.subject))**: \(escape(task.brief)) · \(deadline)\(overdue)")
                if let submission = task.submission, !task.brief.contains(submission) {
                    lines.append((inChinese ? "  - 提交要求：" : "  - Submission: ") + escape(submission))
                }
                let links = task.attachments.compactMap { attachment -> String? in
                    guard let url = attachment.originalURL else { return nil }
                    return "[\(escape(attachment.name))](<\(url.absoluteString)>)"
                }
                if !links.isEmpty { lines.append((inChinese ? "  - 附件：" : "  - Attachments: ") + links.joined(separator: ", ")) }
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
