import AppKit
import SwiftUI

struct DeskTabs: View {
    @Binding var page: DeskPage

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
        LanguageMenu()
        Picker("App Page", selection: $page) {
            ForEach(DeskPage.allCases) { page in Text(LocalizedStringKey(page.rawValue)).tag(page) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
        }
    }
}

struct LanguageMenu: View {
    @AppStorage("interfaceLanguage") private var language = "zh-Hans"

    var body: some View {
        Menu {
            Picker("语言 / Language", selection: $language) {
                Text(verbatim: "English").tag("en")
                Text(verbatim: "简体中文").tag("zh-Hans")
            }
        } label: {
            Label {
                Text(verbatim: language == "en" ? "Language: English" : "语言：简体中文")
            } icon: { Image(systemName: "globe") }
        }
        .fixedSize()
        .help("语言 / Language — English / 简体中文")
        .accessibilityLabel("语言 / Language")
        .accessibilityValue(language == "en" ? "English" : "简体中文")
    }
}

struct LanguageSettings: View {
    @AppStorage("interfaceLanguage") private var language = "zh-Hans"
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("语言 / Language", systemImage: "globe").font(.headline)
            Picker("语言 / Language", selection: $language) {
                Text(verbatim: "English").tag("en")
                Text(verbatim: "简体中文").tag("zh-Hans")
            }
            .pickerStyle(.segmented).labelsHidden()
        }
    }
}

struct TimetableWindow: View {
    @ObservedObject var store: AssignmentStore
    @State private var range = TimetableRange.today

    var body: some View {
        let days = range.days(relativeTo: store.now)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ThemeMascot(fallback: "calendar")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Timetable").font(.system(size: 27, weight: .semibold))
                    Text(Beijing.dayLabel(store.now)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                DeskTabs(page: $store.page)
                Button { store.floatingTimetable.toggle() } label: {
                    Label(store.floatingTimetable ? "Hide Floating Timetable" : "Show Floating Timetable",
                          systemImage: store.floatingTimetable ? "pin.fill" : "pin")
                }
                .help("Show or hide the floating timetable")
                Button { store.refreshTimetable() } label: {
                    Label(store.working == "timetable" ? "Refreshing…" : "Refresh Timetable", systemImage: "arrow.clockwise")
                }
                .disabled(store.working == "timetable")
                .keyboardShortcut("r", modifiers: .command)
                Button { store.settingsOpen = true } label: { Label("Settings", systemImage: "gearshape") }
            }
            .controlSize(.large)
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .background(headerDecoration)
        .overlay(alignment: .bottom) { if oceanTheme { Rectangle().fill(oceanBlue).frame(height: 2) } }

            HStack(alignment: .top, spacing: 10) {
                LessonStatus(caption: "Current Class", lesson: store.currentLesson, now: store.now,
                             empty: store.timetableCoversToday ? "No class now" : "Timetable not updated", active: true)
                LessonStatus(caption: "Next Class", lesson: store.nextLesson, now: store.now,
                             empty: store.timetableCoversToday ? "No more classes scheduled" : "Timetable not updated")
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)

            HStack {
                Picker("Timetable Range", selection: $range) {
                    ForEach(TimetableRange.allCases) { range in Text(range.rawValue).tag(range) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                Spacer()
                Text(rangeLabel(days)).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 10)
            if let error = store.timetableIssue {
                HStack(spacing: 8) {
                    Label(error, systemImage: "exclamationmark.circle")
                    Spacer()
                    if store.timetableNeedsLogin { Button("Login Settings") { store.settingsOpen = true } }
                }
                .font(.callout)
                .padding(.horizontal, 22).padding(.vertical, 8)
                .background(.orange.opacity(0.10))
            }
            Divider()
            ScrollView {
                schedule(days)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 22).padding(.vertical, 16)
            }
            .defaultScrollAnchor(.top)
            Divider()
            HStack {
                if store.working == "timetable" { ProgressView().controlSize(.small) }
                if let timetable = store.snapshot.timetable {
                    Text("Timetable updated \(Beijing.dueLabel(timetable.checkedAt, relativeTo: store.now))")
                } else {
                    Text("Waiting for timetable sync")
                }
                Spacer()
                Text("China Standard Time")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 22).frame(height: 32)
        }
        .frame(minWidth: 850, minHeight: 560)
        .background(backdrop)
        .tint(jade)
    }

    private func rangeLabel(_ days: [Date]) -> String {
        guard let start = days.first, let end = days.last else { return "" }
        return start == end ? Beijing.dayLabel(start) : "\(Beijing.shortDay(start)) – \(Beijing.shortDay(end))"
    }

    @ViewBuilder
    private func schedule(_ days: [Date]) -> some View {
        if let timetable = store.snapshot.timetable, days.allSatisfy({ timetable.covers($0) }) {
            if range == .today {
                let courses = days.first.map { timetable.lessons(on: $0) } ?? []
                if courses.isEmpty {
                    empty("No classes scheduled today")
                } else {
                    LazyVStack(spacing: 5) {
                        ForEach(courses) { course in DayLessonRow(course: course, now: store.now) }
                    }
                }
            } else {
                WeekGrid(days: days, timetable: timetable, now: store.now)
            }
        } else {
            empty(store.working == "timetable" ? "Loading school timetable…" : "No timetable for this period. Click Refresh Timetable to load it.")
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).padding(.vertical, 35)
    }
}

private struct DayLessonRow: View {
    let course: SchoolLesson
    let now: Date

    var body: some View {
        let active = course.contains(now)
        HStack(spacing: 14) {
            Text(course.timeRange).monospacedDigit().foregroundStyle(active ? jade : .secondary)
                .frame(width: 112, alignment: .leading)
            Text(course.title).fontWeight(.semibold)
            if course.temporary { Text("Temporary Class").font(.caption).foregroundStyle(.secondary) }
            if active { Text("In Progress").font(.caption.weight(.semibold)).foregroundStyle(jade) }
            Spacer()
            if let teacher = course.teacher { Text(teacher).foregroundStyle(.secondary).lineLimit(1) }
            if let room = course.room {
                Label(room, systemImage: "door.left.hand.closed")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 68, alignment: .trailing)
            }
        }
        .font(.callout)
        .padding(.horizontal, 13).padding(.vertical, 10)
        .background(active ? jade.opacity(0.13) : panel, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

private struct WeekGrid: View {
    let days: [Date]
    let timetable: Timetable
    let now: Date

    var body: some View {
        let columns = days.filter { day in
            !Beijing.calendar.isDateInWeekend(day) || !timetable.lessons(on: day).isEmpty
        }.map { day in
            (day: day, byTime: Dictionary(grouping: timetable.lessons(on: day)) { Beijing.clock($0.startAt) })
        }
        let times = Set(columns.flatMap { $0.byTime.keys }).sorted()
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text("Start").font(.caption).foregroundStyle(.secondary).frame(width: 55, alignment: .leading)
                ForEach(columns, id: \.day) { column in
                    let isToday = Beijing.calendar.isDate(column.day, inSameDayAs: now)
                    VStack(spacing: 2) {
                        Text(Beijing.weekday(column.day)).font(.callout.weight(.semibold))
                        Text(Beijing.shortDay(column.day)).font(.caption)
                    }
                    .foregroundStyle(isToday ? jade : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(isToday ? jade.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                }
            }
            if times.isEmpty {
                Text("No classes scheduled this week").foregroundStyle(.secondary).padding(.vertical, 35)
            }
            ForEach(times, id: \.self) { time in
                HStack(alignment: .top, spacing: 6) {
                    Text(time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 55, alignment: .leading).padding(.top, 8)
                    ForEach(columns, id: \.day) { column in
                        VStack(spacing: 4) {
                            ForEach(column.byTime[time] ?? []) { course in
                                weekCell(course)
                            }
                        }
                        .frame(minHeight: 48)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
    }

    private func weekCell(_ course: SchoolLesson) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(course.title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Text(course.timeRange + (course.room.map { " · " + $0 } ?? ""))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(7)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(course.contains(now) ? jade.opacity(0.13) : panel, in: RoundedRectangle(cornerRadius: 7))
        .help([course.title, course.timeRange, course.teacher, course.room].compactMap { $0 }.joined(separator: " · "))
        .accessibilityElement(children: .combine)
    }
}

private struct LessonStatus: View {
    let caption: String
    let lesson: SchoolLesson?
    let now: Date
    let empty: String
    var active = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(caption, systemImage: active ? "clock.fill" : "arrow.right.circle")
                .font(.caption.weight(.semibold)).foregroundStyle(active ? jade : .secondary)
            Text(lesson?.title ?? empty)
                .font(.callout.weight(.semibold)).foregroundStyle(lesson == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            if let lesson {
                Text(lesson.timeAndRoom(relativeTo: now))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 77, alignment: .topLeading)
        .background(active && lesson != nil ? jade.opacity(0.14) : panel, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}

struct TimetableMenuLabel: View {
    @ObservedObject var store: AssignmentStore

    var body: some View {
        Label(title, systemImage: "calendar").labelStyle(.titleAndIcon)
            .accessibilityLabel("Timetable: \(title)")
    }

    private var title: String {
        guard store.timetableCoversToday else { return "Timetable not updated" }
        let current = store.currentLesson.map { "Now: " + $0.menuTitle } ?? "No class now"
        guard let next = store.nextLesson else { return current + " · No next class" }
        let today = Beijing.calendar.isDate(next.startAt, inSameDayAs: store.now)
        let prefix = today ? "" : Beijing.weekday(next.startAt) + " "
        return current + " · Next: " + prefix + Beijing.clock(next.startAt) + " " + next.menuTitle
    }
}

struct TimetableMenu: View {
    @ObservedObject var store: AssignmentStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(Beijing.dayLabel(store.now)).font(.headline)
            LessonStatus(caption: "Current Class", lesson: store.currentLesson, now: store.now,
                         empty: store.timetableCoversToday ? "No class now" : "Timetable not updated", active: true)
            LessonStatus(caption: "Next Class", lesson: store.nextLesson, now: store.now,
                         empty: store.timetableCoversToday ? "No more classes scheduled" : "Timetable not updated")
            if let error = store.timetableIssue {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Timetable") { reveal(.timetable) }
                Button("Assignments") { reveal(.assignments) }
                Spacer()
                Button {
                    store.refreshTimetable()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh Timetable")
                .disabled(store.working == "timetable")
            }
            Divider()
            Toggle("Floating Timetable", isOn: $store.floatingTimetable)
                .toggleStyle(.checkbox)
            Button("Quit Assignment Overview") { NSApp.terminate(nil) }.buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 286)
        .tint(jade)
    }

    private func reveal(_ page: DeskPage) {
        store.page = page
        openWindow(id: "assignments")
        NSApp.activate(ignoringOtherApps: true)
        dismiss()
    }
}
