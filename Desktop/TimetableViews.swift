import AppKit
import SwiftUI

struct DeskTabs: View {
    @Binding var page: DeskPage

    var body: some View {
        Picker("应用页面", selection: $page) {
            ForEach(DeskPage.allCases) { page in Text(page.rawValue).tag(page) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }
}

struct TimetableWindow: View {
    @ObservedObject var store: AssignmentStore
    @State private var range = TimetableRange.today

    var body: some View {
        let days = range.days(relativeTo: store.now)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(jade)
                    .frame(width: 43, height: 43)
                    .background(jade.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("课程表").font(.system(size: 27, weight: .semibold))
                    Text(Beijing.dayLabel(store.now)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                DeskTabs(page: $store.page)
                Button { store.floatingTimetable.toggle() } label: {
                    Label(store.floatingTimetable ? "隐藏小窗" : "显示小窗",
                          systemImage: store.floatingTimetable ? "pin.fill" : "pin")
                }
                .help("开关桌面课表小窗")
                Button { store.refreshTimetable() } label: {
                    Label(store.working == "timetable" ? "正在刷新" : "刷新课表", systemImage: "arrow.clockwise")
                }
                .disabled(store.working == "timetable")
                .keyboardShortcut("r", modifiers: .command)
                Button { store.settingsOpen = true } label: { Label("设置", systemImage: "gearshape") }
            }
            .controlSize(.large)
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 14)

            HStack(alignment: .top, spacing: 10) {
                LessonStatus(caption: "正在上课", lesson: store.currentLesson, now: store.now,
                             empty: store.timetableCoversToday ? "当前无课" : "课表待更新", active: true)
                LessonStatus(caption: "下一节", lesson: store.nextLesson, now: store.now,
                             empty: store.timetableCoversToday ? "已同步日期内暂无课程" : "课表待更新")
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)

            HStack {
                Picker("课表范围", selection: $range) {
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
                    if store.timetableNeedsLogin { Button("登录设置") { store.settingsOpen = true } }
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
                Text(store.snapshot.timetable.map { "课表更新 \(Beijing.dueLabel($0.checkedAt, relativeTo: store.now))" }
                     ?? "等待同步课表")
                Spacer()
                Text("北京时间")
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
                    empty("今天没有排课")
                } else {
                    LazyVStack(spacing: 5) {
                        ForEach(courses) { course in DayLessonRow(course: course, now: store.now) }
                    }
                }
            } else {
                WeekGrid(days: days, timetable: timetable, now: store.now)
            }
        } else {
            empty(store.working == "timetable" ? "正在读取学校课表…" : "暂无这段时间的课表，点「刷新课表」读取。")
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
            if course.temporary { Text("临时排课").font(.caption).foregroundStyle(.secondary) }
            if active { Text("上课中").font(.caption.weight(.semibold)).foregroundStyle(jade) }
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
                Text("开始").font(.caption).foregroundStyle(.secondary).frame(width: 55, alignment: .leading)
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
                Text("这周没有排课").foregroundStyle(.secondary).padding(.vertical, 35)
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
            .accessibilityLabel("课表 \(title)")
    }

    private var title: String {
        guard store.timetableCoversToday else { return "课表待更新" }
        let current = store.currentLesson.map { "上课 " + $0.menuTitle } ?? "当前无课"
        guard let next = store.nextLesson else { return current + " · 暂无下节" }
        let today = Beijing.calendar.isDate(next.startAt, inSameDayAs: store.now)
        let prefix = today ? "" : Beijing.weekday(next.startAt) + " "
        return current + " · 下节 " + prefix + Beijing.clock(next.startAt) + " " + next.menuTitle
    }
}

struct TimetableMenu: View {
    @ObservedObject var store: AssignmentStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(Beijing.dayLabel(store.now)).font(.headline)
            LessonStatus(caption: "正在上课", lesson: store.currentLesson, now: store.now,
                         empty: store.timetableCoversToday ? "当前无课" : "课表待更新", active: true)
            LessonStatus(caption: "下一节", lesson: store.nextLesson, now: store.now,
                         empty: store.timetableCoversToday ? "已同步日期内暂无课程" : "课表待更新")
            if let error = store.timetableIssue {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("打开课表") { reveal(.timetable) }
                Button("作业") { reveal(.assignments) }
                Spacer()
                Button {
                    store.refreshTimetable()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新课表")
                .disabled(store.working == "timetable")
            }
            Divider()
            Toggle("课表小窗", isOn: $store.floatingTimetable)
                .toggleStyle(.checkbox)
            Button("退出作业速览") { NSApp.terminate(nil) }.buttonStyle(.link)
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
