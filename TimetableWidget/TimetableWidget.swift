import Darwin
import SwiftUI
import WidgetKit

private struct WidgetEntry: TimelineEntry {
    let date: Date
    let data: WidgetSnapshot?
    var page: WidgetPage = .timetable

    var timetable: Timetable? { data?.timetable }
    var hasSchedule: Bool { timetable?.covers(date) == true }
    var theme: DeskTheme { DeskTheme(rawValue: data?.theme ?? "") ?? .otter }
    var language: String { data?.language ?? (Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en") }
    var chinese: Bool { language == "zh-Hans" }

    static let preview: Self = {
        let date = Beijing.parse("2026-11-20T09:18:00+08:00")!
        let courses = [
            SchoolLesson(id: "math", title: "Mathematics",
                         startAt: Beijing.parse("2026-11-20T09:00:00+08:00")!,
                         endAt: Beijing.parse("2026-11-20T09:45:00+08:00")!,
                         room: "301", teacher: nil, temporary: false),
            SchoolLesson(id: "physics", title: "Physics",
                         startAt: Beijing.parse("2026-11-20T10:00:00+08:00")!,
                         endAt: Beijing.parse("2026-11-20T10:45:00+08:00")!,
                         room: "202", teacher: nil, temporary: false)
        ]
        let day = Beijing.day(date)
        let timetable = Timetable(checkedAt: date, startDay: day, endDay: day, courses: courses)
        let pins = [
            WidgetAssignment(id: "sample1", title: "Physics problem set", subject: "Physics",
                             due: Beijing.parse("2026-11-20T18:00:00+08:00"), pending: true),
            WidgetAssignment(id: "sample2", title: "Literature draft", subject: "Literature",
                             due: Beijing.parse("2026-11-21T09:30:00+08:00"), pending: true)
        ]
        return Self(date: date, data: WidgetSnapshot(theme: "otter", language: "en",
                                                     timetable: timetable, pins: pins, pinCount: pins.count))
    }()
}

private struct WidgetProvider: TimelineProvider {
    var showSchedule = true
    var slot: Int?

    private func selectedPage(_ data: WidgetSnapshot?) -> WidgetPage {
        guard let slot else { return showSchedule ? .timetable : .pins }
        let preference = slot == 1 ? data?.preferredContent : data?.secondContent
        return preference.flatMap(WidgetPage.init(rawValue:)) ?? (slot == 1 ? .deadlines : .gpa)
    }

    func placeholder(in context: Context) -> WidgetEntry {
        let sample = WidgetEntry.preview
        var data = sample.data
        data?.deadlines = sample.data?.pins
        data?.gpa = WidgetGPA(transcript: nil, estimate: 3.5, included: 4, eligible: 4, exampleScale: true)
        return WidgetEntry(date: sample.date, data: data, page: selectedPage(data))
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        let data = readData()
        completion(context.isPreview && data == nil ? placeholder(in: context) : WidgetEntry(date: Date(), data: data, page: selectedPage(data)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let data = readData()
        completion(timeline(data: data, page: selectedPage(data)))
    }

    func timeline(data: WidgetSnapshot?, page: WidgetPage) -> Timeline<WidgetEntry> {
        let now = Date()
        let showSchedule = page == .timetable || page == .nextClass
        let entry = WidgetEntry(date: now, data: data, page: page)
        guard data != nil, !showSchedule || entry.hasSchedule else {
            return Timeline(entries: [entry], policy: .after(now.addingTimeInterval(15 * 60)))
        }
        let horizon = now.addingTimeInterval(24 * 60 * 60)
        var dates = Set([now])
        if showSchedule {
            for course in data?.timetable?.courses ?? [] {
                for boundary in [course.startAt, course.endAt] where boundary > now && boundary < horizon {
                    dates.insert(boundary)
                }
            }
        } else {
            for pin in (page == .deadlines ? data?.deadlines : data?.pins) ?? [] where pin.pending {
                if let due = pin.due, due > now, due < horizon { dates.insert(due) }
            }
        }
        if let midnight = Beijing.calendar.dateInterval(of: .day, for: now)?.end {
            dates.insert(midnight)
        }
        let entries = dates.sorted().map { WidgetEntry(date: $0, data: data, page: page) }
        return Timeline(entries: entries, policy: .after(horizon))
    }

    func readData() -> WidgetSnapshot? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        let root = URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent("Library/Application Support/作业速览")
        if let data = try? Data(contentsOf: WidgetSnapshot.file(in: root)),
           let snapshot = try? WidgetSnapshot.decode(from: data) {
            return snapshot
        }
        // Keep the existing timetable usable until the updated app creates the widget snapshot.
        let cache = root.appendingPathComponent("data/timetable.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = try? Data(contentsOf: cache), let timetable = try? decoder.decode(Timetable.self, from: data) else { return nil }
        let language = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
        return WidgetSnapshot(theme: "classic", language: language, timetable: timetable, pins: [], pinCount: 0)
    }
}

private enum WidgetPage: String {
    case timetable, nextClass, pins, deadlines, gpa
}

private struct AssignmentWidgetView: View {
    let entry: WidgetEntry
    let page: WidgetPage
    var editableSlot: Int?
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var settings: WidgetSlotAppearance? {
        editableSlot.flatMap { entry.data?.slots?[String($0)] }
    }
    private var visiblePins: [WidgetAssignment] { settings?.pins ?? entry.data?.pins ?? [] }
    private var colorChoice: WidgetColor { WidgetColor(rawValue: settings?.color ?? "") ?? .theme }
    private var palette: (surface: Color, card: Color, accent: Color) { colorChoice.palette(theme: entry.theme) }
    private var adaptive: Bool { colorChoice == .theme && entry.theme == .classic }
    private var compact: Bool { family == .systemSmall }
    private var fullColor: Bool { renderingMode == .fullColor }
    private var ink: Color {
        fullColor && !adaptive ? Color(red: 0.10, green: 0.19, blue: 0.20) : .primary
    }
    private var muted: Color {
        fullColor && !adaptive ? Color(red: 0.30, green: 0.38, blue: 0.40) : .secondary
    }
    private var accent: Color { fullColor ? palette.accent : .primary }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 9) {
            HStack {
                Text(title).font(.system(size: compact ? 12 : 14, weight: .semibold))
                    .foregroundStyle(accent).widgetAccentable()
                Spacer(minLength: 3)
                if let editableSlot, !compact {
                    Link(destination: URL(string: "spassignments://edit-widget/\(editableSlot)")!) {
                        Label("Edit", systemImage: "pencil").font(.caption)
                    }
                }
                if page == .timetable {
                    Text(Beijing.shortDay(entry.date, chinese: entry.chinese))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
                }
            }
            .lineLimit(1)

            switch page {
            case .timetable: timetable
            case .nextClass: nextClass
            case .pins: pins
            case .deadlines:
                if upcoming.isEmpty {
                    empty("No Upcoming Deadlines", hint: "Open assignments to check your homework.")
                } else {
                    ForEach(upcoming.prefix(compact ? 2 : 3)) { item in
                        if compact { assignment(item) }
                        else { Link(destination: item.url) { assignment(item) }.buttonStyle(.plain) }
                    }
                }
            case .gpa:
                if let summary = entry.data?.gpa, let estimate = summary.estimate {
                    Text(verbatim: String(format: "%.2f / %d.0", estimate, summary.maximum ?? 4))
                        .font(.title.bold()).minimumScaleFactor(0.7).privacySensitive()
                    Text("Estimated semester GPA").font(.caption)
                    Text("\(summary.included) of \(summary.eligible) courses included").font(.caption2)
                } else if let value = entry.data?.gpa?.transcript, !value.isEmpty {
                    Text(value).font(.largeTitle.bold()).privacySensitive()
                    Text("From your transcript").font(.caption)
                } else {
                    empty("GPA Unavailable", hint: "Open Grades and sync semester scores.")
                }
            }
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(compact ? 12 : 14)
        .widgetURL(openURL)
        .containerBackground(for: .widget) { palette.surface }
        .environment(\.locale, Locale(identifier: entry.language))
        .environment(\.colorScheme, adaptive ? colorScheme : .light)
    }

    @Environment(\.colorScheme) private var colorScheme

    private var title: LocalizedStringKey {
        switch page {
        case .timetable: "Timetable"
        case .nextClass: "Next Class"
        case .pins: "Pinned Assignments"
        case .deadlines: "Homework Deadlines"
        case .gpa: "Semester GPA"
        }
    }

    private var upcoming: [WidgetAssignment] {
        (entry.data?.deadlines ?? []).filter { ($0.due ?? .distantPast) > entry.date }
    }

    private var openURL: URL {
        if page == .gpa { return WidgetSnapshot.gradesURL }
        if page == .deadlines { return compact ? upcoming.first?.url ?? WidgetSnapshot.assignmentURL : WidgetSnapshot.assignmentURL }
        guard page == .pins else { return WidgetSnapshot.timetableURL }
        return compact ? (visiblePins.first?.url ?? WidgetSnapshot.assignmentURL) : WidgetSnapshot.assignmentURL
    }

    @ViewBuilder private var timetable: some View {
        if entry.hasSchedule {
            let layout = compact ? AnyLayout(VStackLayout(spacing: 5)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                lesson("In Class", entry.timetable?.current(at: entry.date), next: false)
                lesson("Next Class", entry.timetable?.next(after: entry.date), next: true)
            }
        } else {
            empty("Timetable Unavailable", hint: "Open the app to sync your timetable.")
        }
    }

    @ViewBuilder private var nextClass: some View {
        if !entry.hasSchedule {
            empty("Timetable Unavailable", hint: "Open the app to sync your timetable.")
        } else if let course = entry.timetable?.next(after: entry.date) {
            let sameDay = Beijing.calendar.isDate(course.startAt, inSameDayAs: entry.date)
            VStack(alignment: .leading, spacing: 4) {
                Text(Beijing.clock(course.startAt)).font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(accent).widgetAccentable()
                Text(course.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if !sameDay {
                    Text(Beijing.shortDay(course.startAt, chinese: entry.chinese)).foregroundStyle(muted)
                }
                let end = Beijing.clock(course.endAt)
                Text(course.room.map { "\($0) · \(end)" } ?? end)
                    .monospacedDigit().foregroundStyle(muted).lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
        } else {
            empty("No Upcoming Class", hint: "Open the timetable to see the full schedule.")
        }
    }

    @ViewBuilder private var pins: some View {
        let pins = visiblePins
        if pins.isEmpty {
            empty("No Pinned Assignments", hint: "Pin an assignment in the app to see it here.")
        } else {
            ForEach(pins.prefix(compact ? 2 : 3)) { item in
                if compact {
                    assignment(item)
                } else {
                    Link(destination: item.url) { assignment(item) }
                        .buttonStyle(.plain)
                }
            }
            let remaining = (settings?.count ?? entry.data?.pinCount ?? 0) - (compact ? 2 : 3)
            if remaining > 0 {
                Text("+\(remaining) more").font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
            }
        }
    }

    private func assignment(_ item: WidgetAssignment) -> some View {
        let overdue = item.pending && item.due.map { $0 <= entry.date } == true
        return VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            HStack(spacing: 5) {
                if !compact { Text(item.subject) }
                if let due = item.due {
                    Text(Beijing.dueLabel(due, relativeTo: entry.date, chinese: entry.chinese)).monospacedDigit()
                }
                if overdue { Text("Overdue").foregroundStyle(fullColor ? Color(red: 0.69, green: 0.25, blue: 0.14) : .primary) }
                if !item.pending { Text("Completed") }
            }
            .foregroundStyle(muted).font(.system(size: 9, weight: .medium)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(fullColor ? palette.card : .primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private func lesson(_ caption: LocalizedStringKey, _ course: SchoolLesson?, next: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.system(size: 10, weight: .semibold)).foregroundStyle(next ? muted : accent)
            if let course {
                Text(course.title).font(.system(size: compact ? 12 : 15, weight: .semibold)).lineLimit(1)
                let sameDay = Beijing.calendar.isDate(course.startAt, inSameDayAs: entry.date)
                let start = sameDay ? "" : Beijing.shortDay(course.startAt, chinese: entry.chinese) + " "
                Text(start + (compact ? Beijing.clock(course.startAt) : course.timeRange))
                    .monospacedDigit().font(.system(size: 9, weight: .medium)).foregroundStyle(muted).lineLimit(1)
                if !compact, let room = course.room {
                    Text(room).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
                }
            } else {
                Text(next ? "No Upcoming Class" : "No Class Now")
                    .font(.system(size: compact ? 12 : 14, weight: .semibold)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: .topLeading)
        .padding(.horizontal, 8).padding(.vertical, compact ? 5 : 10)
        .background(fullColor ? palette.card : .primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private func empty(_ title: LocalizedStringKey, hint: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 2)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(hint).font(.system(size: 10)).foregroundStyle(muted)
            Spacer(minLength: 2)
        }
    }
}

struct DesktopTimetableWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TimetableWidget", provider: WidgetProvider()) {
            AssignmentWidgetView(entry: $0, page: .timetable)
        }
        .configurationDisplayName("Timetable")
        .description("See your current and next class.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct NextClassWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextClassWidget", provider: WidgetProvider()) {
            AssignmentWidgetView(entry: $0, page: .nextClass)
        }
        .configurationDisplayName("Next Class")
        .description("See when and where your next class starts.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct PinnedAssignmentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PinnedAssignmentsWidget", provider: WidgetProvider(showSchedule: false)) {
            AssignmentWidgetView(entry: $0, page: .pins)
        }
        .configurationDisplayName("Pinned Assignments")
        .description("Keep your pinned assignments and deadlines on the desktop.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

private func overviewConfiguration(slot: Int) -> some WidgetConfiguration {
        StaticConfiguration(kind: "OverviewSlot" + String(slot), provider: WidgetProvider(slot: slot)) { entry in
            AssignmentWidgetView(entry: entry, page: entry.page, editableSlot: slot)
        }
        .configurationDisplayName(slot == 1 ? "My Overview" : "My Second Overview")
        .description("Choose the content for this widget in the app’s Desktop Widgets settings.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
}

struct FirstOverviewWidget: Widget {
    var body: some WidgetConfiguration { overviewConfiguration(slot: 1) }
}

struct SecondOverviewWidget: Widget {
    var body: some WidgetConfiguration { overviewConfiguration(slot: 2) }
}

@main
struct AssignmentWidgets: WidgetBundle {
    var body: some Widget {
        FirstOverviewWidget()
        SecondOverviewWidget()
        DesktopTimetableWidget()
        NextClassWidget()
        PinnedAssignmentsWidget()
    }
}
