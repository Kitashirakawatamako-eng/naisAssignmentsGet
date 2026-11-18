import Foundation

struct SchoolLesson: Decodable, Identifiable {
    let id, title: String
    let startAt, endAt: Date
    let room, teacher: String?
    let temporary: Bool

    var timeRange: String { "\(Beijing.clock(startAt))–\(Beijing.clock(endAt))" }

    func timeAndRoom(relativeTo now: Date) -> String {
        let date = Beijing.calendar.isDate(startAt, inSameDayAs: now) ? "" : Beijing.shortDay(startAt) + " "
        return date + timeRange + (room.map { " · " + $0 } ?? "")
    }

    var menuTitle: String {
        let knownNames = [
            "AP商务与个人理财": "AP Business",
            "AP环境科学": "AP Environmental Science",
            "周二美国计算机联盟ACSL竞赛": "ACSL",
            "周四ACSL美国计算机联盟竞赛": "ACSL",
            "高中体育 （羽毛球）": "PE",
        ]
        let name = knownNames[title] ?? title
        return name.count <= 9 ? name : String(name.prefix(8)) + "…"
    }

    func contains(_ time: Date) -> Bool { startAt <= time && time < endAt }
}

struct Timetable: Decodable {
    let checkedAt: Date
    let startDay, endDay: String
    let courses: [SchoolLesson]

    func covers(_ day: Date) -> Bool {
        let value = Beijing.day(day)
        return startDay <= value && value <= endDay
    }

    func lessons(on day: Date) -> [SchoolLesson] {
        courses.filter { Beijing.calendar.isDate($0.startAt, inSameDayAs: day) }
    }

    func current(at time: Date) -> SchoolLesson? {
        guard covers(time) else { return nil }
        return courses.filter { $0.contains(time) }.max { left, right in
            if left.temporary != right.temporary { return right.temporary }
            return left.startAt < right.startAt
        }
    }

    func next(after time: Date) -> SchoolLesson? {
        guard covers(time) else { return nil }
        return courses.first { $0.startAt > time }
    }
}

enum DeskPage: String, CaseIterable, Identifiable {
    case assignments = "Assignments", timetable = "Timetable"
    var id: Self { self }
}

enum TimetableRange: String, CaseIterable, Identifiable {
    case today = "Today", thisWeek = "This Week", nextWeek = "Next Week"
    var id: Self { self }

    func days(relativeTo now: Date) -> [Date] {
        let calendar = Beijing.calendar
        if self == .today { return [calendar.startOfDay(for: now)] }
        let first = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let offset = self == .nextWeek ? 7 : 0
        return (offset..<(offset + 7)).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }
}
