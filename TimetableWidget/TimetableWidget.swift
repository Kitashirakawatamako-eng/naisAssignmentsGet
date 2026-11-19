import Darwin
import SwiftUI
import WidgetKit

private struct TimetableEntry: TimelineEntry {
    let date: Date
    let timetable: Timetable?

    var hasSchedule: Bool { timetable?.covers(date) == true }
    var current: SchoolLesson? { timetable?.current(at: date) }
    var next: SchoolLesson? { timetable?.next(after: date) }

    static let preview: Self = {
        let date = Beijing.parse("2026-11-19T09:18:00+08:00")!
        let courses = [
            SchoolLesson(id: "math", title: "Advanced Mathematics",
                         startAt: Beijing.parse("2026-11-19T09:00:00+08:00")!,
                         endAt: Beijing.parse("2026-11-19T09:45:00+08:00")!,
                         room: "301", teacher: nil, temporary: false),
            SchoolLesson(id: "physics", title: "Physics",
                         startAt: Beijing.parse("2026-11-19T10:00:00+08:00")!,
                         endAt: Beijing.parse("2026-11-19T10:45:00+08:00")!,
                         room: "202", teacher: nil, temporary: false)
        ]
        let day = Beijing.day(date)
        return Self(date: date, timetable: Timetable(checkedAt: date, startDay: day, endDay: day, courses: courses))
    }()
}

private struct TimetableProvider: TimelineProvider {
    func placeholder(in context: Context) -> TimetableEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (TimetableEntry) -> Void) {
        completion(context.isPreview ? .preview : TimetableEntry(date: Date(), timetable: readTimetable()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TimetableEntry>) -> Void) {
        let now = Date()
        let timetable = readTimetable()
        guard let timetable, timetable.covers(now) else {
            completion(Timeline(entries: [TimetableEntry(date: now, timetable: nil)],
                                policy: .after(now.addingTimeInterval(15 * 60))))
            return
        }
        let horizon = now.addingTimeInterval(24 * 60 * 60)
        var dates = Set([now])
        for course in timetable.courses {
            for boundary in [course.startAt, course.endAt] where boundary > now && boundary < horizon {
                dates.insert(boundary)
            }
        }
        if let midnight = Beijing.calendar.dateInterval(of: .day, for: now)?.end {
            dates.insert(midnight)
        }
        let entries = dates.sorted().map { TimetableEntry(date: $0, timetable: timetable) }
        completion(Timeline(entries: entries, policy: .after(horizon)))
    }

    private func readTimetable() -> Timetable? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        let url = URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent("Library/Application Support/作业速览/data/timetable.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Timetable.self, from: data)
    }
}

private struct TimetableWidgetView: View {
    let entry: TimetableEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var compact: Bool { family == .systemSmall }
    private var fullColor: Bool { renderingMode == .fullColor }
    private var ink: Color { fullColor ? Color(red: 0.96, green: 0.99, blue: 0.97) : .primary }
    private var muted: Color { fullColor ? Color(red: 0.69, green: 0.78, blue: 0.76) : .secondary }
    private var jade: Color { fullColor ? Color(red: 0.56, green: 0.91, blue: 0.77) : .primary }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack {
                Text("Timetable").font(.system(size: compact ? 13 : 15, weight: .semibold))
                Spacer(minLength: 4)
                Text(Beijing.shortDay(entry.date))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
            }
            if entry.hasSchedule {
                let layout = compact ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 9))
                layout {
                    lesson("In Class", entry.current, next: false)
                    lesson("Next Class", entry.next, next: true)
                }
            } else {
                Spacer(minLength: 2)
                Text("Timetable Unavailable").font(.system(size: 14, weight: .semibold))
                Text("Open the app to sync your timetable.")
                    .font(.system(size: 11)).foregroundStyle(muted)
                Spacer(minLength: 2)
            }
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(compact ? 11 : 14)
        .widgetURL(URL(string: "spassignments://timetable"))
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.075, green: 0.21, blue: 0.20),
                                    Color(red: 0.05, green: 0.14, blue: 0.14)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func lesson(_ caption: LocalizedStringKey, _ course: SchoolLesson?, next: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 5) {
            HStack(spacing: 3) {
                Text(caption).fontWeight(.semibold).foregroundStyle(next ? muted : jade)
                Spacer(minLength: 0)
                if let course {
                    Text(compact ? course.compactStart(relativeTo: entry.date) : course.timeRange)
                        .monospacedDigit().foregroundStyle(muted)
                }
            }
            .lineLimit(1)
            .font(.system(size: 10))
            if let course {
                Text(course.title).font(.system(size: compact ? 13 : 16, weight: .semibold)).lineLimit(1)
            } else {
                Text(next ? "No Upcoming Class" : "No Class Now")
                    .font(.system(size: compact ? 13 : 16, weight: .semibold)).lineLimit(1)
            }
            if !compact, let course {
                let today = Beijing.calendar.isDate(course.startAt, inSameDayAs: entry.date)
                let location = [today ? nil : Beijing.shortDay(course.startAt), course.room].compactMap { $0 }
                if !location.isEmpty {
                    Text(location.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, compact ? 8 : 11)
        .padding(.vertical, compact ? 5 : 11)
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: .topLeading)
        .background(fullColor
            ? Color(red: 0.52, green: 0.91, blue: 0.81).opacity(next ? 0.08 : 0.15)
            : Color.primary.opacity(next ? 0.06 : 0.11), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

@main
struct DesktopTimetableWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TimetableWidget", provider: TimetableProvider()) { entry in
            TimetableWidgetView(entry: entry)
        }
        .configurationDisplayName("Timetable")
        .description("See your current and next class.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
