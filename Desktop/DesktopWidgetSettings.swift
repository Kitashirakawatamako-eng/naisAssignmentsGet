import SwiftUI
import WidgetKit

struct DesktopWidgetSettings: View {
    @ObservedObject var store: AssignmentStore
    @AppStorage("showTimetableInMenuBar") private var showTimetableInMenuBar = false
    @State private var showingPreview = false
    @State private var requestedRefresh = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show timetable in menu bar", isOn: $showTimetableInMenuBar)
            Label("Desktop Widgets", systemImage: "rectangle.3.group").font(.headline)
            Text("Right-click your desktop → Edit Widgets → Assignment Overview. Choose Pinned Assignments, Timetable, or Next Class.")
                .font(.callout).foregroundStyle(.secondary)
            WidgetContentPicker(slot: .first, store: store)
            WidgetContentPicker(slot: .second, store: store)
            Text("Add either widget by name from Edit Widgets. Each follows its own selection here.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(showingPreview ? "Hide Preview" : "Preview Widgets") { showingPreview.toggle() }
                Button("Refresh Widgets") {
                    store.publishWidgets()
                    WidgetCenter.shared.reloadAllTimelines()
                    requestedRefresh = true
                }
            }
            if requestedRefresh {
                Text("Refresh requested. macOS decides when desktop widgets update.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if showingPreview {
                VStack(alignment: .leading, spacing: 10) {
                    preview("Pinned Assignments", icon: "pin.fill") {
                        if let task = store.pinnedTasks.first {
                            Text(task.title).font(.headline).lineLimit(2)
                            Text(task.subject).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Pin an assignment in the app to see it here.").font(.callout)
                        }
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        HStack(alignment: .top, spacing: 10) {
                            preview("Timetable", icon: "calendar") {
                                if let lesson = store.snapshot.timetable?.current(at: context.date) {
                                    Text(lesson.title).font(.headline).lineLimit(2)
                                    Text(lesson.timeRange).font(.caption).monospacedDigit()
                                } else {
                                    Text("No Class Now").font(.callout)
                                }
                            }
                            preview("Next Class", icon: "clock") {
                                if let lesson = store.snapshot.timetable?.next(after: context.date) {
                                    Text(lesson.title).font(.headline).lineLimit(2)
                                    Text(lesson.compactStart(relativeTo: context.date)).font(.caption).monospacedDigit()
                                } else {
                                    Text("No Upcoming Class").font(.callout)
                                }
                            }
                        }
                    }
                    Text("Previews use your current data and theme. Desktop layout varies with widget size and macOS color settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func preview<Content: View>(_ title: LocalizedStringKey, icon: String,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(jade)
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
        .padding(12)
        .background(DeskTheme.current.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(jade.opacity(0.18)))
    }
}

enum EditableWidgetSlot: Int, Identifiable {
    case first = 1, second = 2
    var id: Int { rawValue }
}

struct WidgetContentPicker: View {
    let slot: EditableWidgetSlot
    @ObservedObject var store: AssignmentStore
    @AppStorage("widgetContent") private var first = "deadlines"
    @AppStorage("secondWidgetContent") private var second = "gpa"

    @AppStorage private var color: String
    @AppStorage private var pinScope: String
    @AppStorage private var selectedTask: String

    init(slot: EditableWidgetSlot, store: AssignmentStore) {
        self.slot = slot
        self.store = store
        let suffix = String(slot.rawValue)
        _color = AppStorage(wrappedValue: "theme", "widgetColor" + suffix)
        _pinScope = AppStorage(wrappedValue: "all", "widgetPinScope" + suffix)
        _selectedTask = AppStorage(wrappedValue: "", "widgetTask" + suffix)
    }

    var body: some View {
        let selection = slot == .first ? $first : $second
        let title: LocalizedStringKey = slot == .first ? "My Overview" : "My Second Overview"
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Show", selection: selection) {
                    Text("Homework Deadlines").tag("deadlines")
                    Text("Semester GPA").tag("gpa")
                    Text("Timetable").tag("timetable")
                    Text("Next Class").tag("nextClass")
                    Text("Pinned Assignments").tag("pins")
                }
                HStack {
                    Picker("Widget color", selection: $color) {
                        ForEach(WidgetColor.allCases, id: \.rawValue) { shade in Text(shade.title).tag(shade.rawValue) }
                    }
                    let sample = (WidgetColor(rawValue: color) ?? .theme).palette(theme: .current)
                    Capsule().fill(sample.surface).overlay(Capsule().stroke(sample.accent)).frame(width: 28, height: 14)
                        .accessibilityHidden(true)
                }
                if selection.wrappedValue == "pins" {
                    Picker("Show pins", selection: $pinScope) {
                        Text("All visible pins").tag("all")
                        Text("Global pins only").tag("global")
                        Text("Current filter pins only").tag("filtered")
                        Text("One assignment").tag("single")
                    }
                    if pinScope == "single" {
                        Picker("Assignment", selection: $selectedTask) {
                            Text("Choose an assignment").tag("")
                            ForEach(store.snapshot.tasks) { task in Text(verbatim: task.subject + " · " + task.title).tag(task.id) }
                        }
                    }
                }
            }.padding(4)
        } label: { Text(title).font(.headline) }
        .onChange(of: [selection.wrappedValue, color, pinScope, selectedTask]) { _, _ in store.publishWidgets() }
    }
}
