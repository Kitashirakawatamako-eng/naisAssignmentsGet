import SwiftUI

private let schoolURL = URL(string: "https://naisstu.schoolis.cn/Home#!/task/list/")!

struct AssignmentWindow: View {
    @ObservedObject var store: AssignmentStore
    @State private var filtersOpen = false
    @FocusState var searchFocused: Bool

    var body: some View {
        let rows = store.rows
        let filteredIDs = Set(rows.map(\.id))
        let extraPins = store.globalPinnedTasks.filter { !filteredIDs.contains($0.id) }
        VStack(spacing: 0) {
            header
            controls
            if let issue = store.syncIssue {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(issue).frame(maxWidth: .infinity, alignment: .leading)
                    if store.needsLogin { Button("Login Settings") { store.settingsOpen = true } }
                    else if let hint = store.syncRecoveryHint {
                        Text(hint).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .font(.callout)
                .padding(.horizontal, 22)
                .padding(.vertical, 9)
                .background(.orange.opacity(0.10))
            }
            Divider()
            AssignmentSplit {
                assignmentList(rows)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(panel)
            } detail: {
                Group {
                    if let task = store.selectedTask {
                        TaskDetail(task: task, store: store).id(task.id)
                    } else {
                        Placeholder(icon: "doc.text.magnifyingglass", title: "Assignment Details", subtitle: "Select an assignment to view its details.")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(backdrop)
            }
            Divider()
            footer(count: rows.count + extraPins.count, pending: (rows + extraPins).filter(\.pending).count)
        }
        .frame(minWidth: 850, minHeight: 560)
        .background(backdrop)
        .tint(jade)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ThemeMascot(fallback: "checklist")
            VStack(alignment: .leading, spacing: 3) {
                Text("Assignment Overview").font(.system(size: 27, weight: .semibold))
                Text(Beijing.dayLabel(store.now)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            DeskTabs(page: $store.page)
            Button("AI Assistant") { store.assistant.present(store.selectedID) }
            Button { store.sync() } label: {
                Label(store.working == "sync" ? LocalizedStringKey("Syncing…") : "Sync Now", systemImage: "arrow.clockwise")
            }
            .disabled(store.working != nil)
            .keyboardShortcut("r", modifiers: .command)
            Button { store.settingsOpen = true } label: { Label("Settings", systemImage: "gearshape") }
        }
        .controlSize(.large)
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background(headerDecoration)
        .overlay(alignment: .bottom) { if oceanTheme { Rectangle().fill(oceanBlue).frame(height: 2) } }
    }

    private var controls: some View {
        HStack(spacing: 9) {
            Toggle("Deadline View", isOn: $store.filters.deadlineView).toggleStyle(.button)
            Picker("Assigned Date", selection: Binding(
                get: { store.filters.effectiveRange },
                set: { store.filters.range = $0 }
            )) {
                ForEach(DateRange.allCases) { range in Text(LocalizedStringKey(range.rawValue)).tag(range) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(store.filters.usesAllAssignedDates)
            .help("Deadline View and deadline filters include all assigned dates.")
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search assignments", text: $store.filters.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !store.filters.search.isEmpty {
                    Button { store.filters.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, 9)
            .frame(width: 165, height: 27)
            .background(panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.10)) }

            Button { filtersOpen.toggle() } label: {
                Label(store.filters.activeCount == 0 ? "Filter" : "Filter \(store.filters.activeCount)",
                      systemImage: "line.3.horizontal.decrease")
            }
            .accessibilityLabel("Filter")
            .popover(isPresented: $filtersOpen, arrowEdge: .bottom) { AssignmentFilterPopover(store: store) }
            Button { store.exportChecklist() } label: {
                Label("Export To-Do List", systemImage: "square.and.arrow.down")
            }
            .disabled(store.pendingCount == 0)
            .help(store.pendingCount == 0 ? "No to-do items in the current filter" : "Export \(store.pendingCount) to-do items as Markdown")
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        .controlSize(.regular)
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }

    private func assignmentList(_ rows: [Assignment]) -> some View {
        Group {
            if store.loading {
                ProgressView("Loading assignments").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.needsSetup && store.snapshot.tasks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle").font(.system(size: 32)).foregroundStyle(jade)
                    Text("Sign in to view assignments and the timetable").font(.headline)
                    Button("Sign In to School Account") { store.settingsOpen = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty && store.pinnedTasks.isEmpty {
                Placeholder(icon: "tray", title: store.snapshot.tasks.isEmpty ? "No Assignments Yet" : "No Matching Assignments",
                            subtitle: store.snapshot.tasks.isEmpty ? "Click Sync Now to fetch your school assignments." : "Try another date or change the filters.")
            } else {
                let pinned = store.pinnedTasks
                let shown = Set(pinned.map(\.id))
                let other = rows.filter { !shown.contains($0.id) }
                List(selection: $store.selectedID) {
                    if !pinned.isEmpty {
                        Section("Pinned") {
                            ForEach(pinned) { task in assignmentRow(task) }
                        }
                    }
                    ForEach(store.filters.deadlineView ? TaskDay.deadlineGroups(other) : TaskDay.groups(other)) { day in
                        Section(LocalizedStringKey(day.label)) {
                            ForEach(day.tasks) { task in assignmentRow(task) }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Assignment List")
            }
        }
    }

    private func assignmentRow(_ task: Assignment) -> some View {
        TaskListRow(task: task, now: store.now, pin: store.pinState(task.id), writing: store.isInProgress(task.id))
            .tag(task.id)
            .listRowInsets(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
            .accessibilityElement(children: .combine)
            .contextMenu {
                CompletionActions(task: task, store: store)
                PinMenu(task: task, store: store)
            }
    }

    private func footer(count: Int, pending: Int) -> some View {
        HStack(spacing: 8) {
            if store.working == "sync" {
                ProgressView().controlSize(.small).scaleEffect(0.75)
                Text("Syncing…")
            } else {
                Circle().fill(store.automatic && store.inSchedule ? jade : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(store.automatic ? (store.inSchedule ? "Automatic Sync On" : "Waiting for Sync Hours") : "Automatic Sync Paused")
            }
            Text("·")
            if let date = Beijing.parse(store.snapshot.checkedAt) {
                Text("Last synced \(Beijing.dueLabel(date, relativeTo: store.now))")
            } else {
                Text("Not synced yet")
            }
            if store.snapshot.warningCount > 0 {
                Label("\(store.snapshot.warningCount) items to retry", systemImage: "exclamationmark.circle")
            }
            Spacer()
            Text("\(count) items · \(pending) to do").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 22)
        .frame(height: 32)
    }
}

private struct CompletionActions: View {
    let task: Assignment
    @ObservedObject var store: AssignmentStore
    var body: some View {
        Button(task.pending ? "Mark Finished" : "Mark Unfinished") {
            store.setCompletion(task.pending, for: task.id)
        }
        if store.localCompletion(task.id) != nil {
            Button("Use School Status") { store.setCompletion(nil, for: task.id) }
        }
    }
}

private struct PinMenu: View {
    let task: Assignment
    @ObservedObject var store: AssignmentStore

    var body: some View {
        let state = store.pinState(task.id)
        Menu {
            Toggle("Pin Globally", isOn: choice(.global, state))
            Toggle("Pin in Filtered Results", isOn: choice(.filtered, state))
            if state != nil {
                Divider()
                Button { store.unpin(task.id) } label: {
                    Label("Unpin", systemImage: "pin.slash")
                }
            }
        } label: {
            Label(state == nil ? "Pin" : "Pinned", systemImage: state == .global ? "pin.fill" : "pin")
        }
    }

    private func choice(_ scope: AssignmentStore.PinScope, _ state: AssignmentStore.PinScope?) -> Binding<Bool> {
        Binding {
            state == scope
        } set: { on in
            if on {
                store.setPin(task.id, scope: scope)
            } else if store.pinState(task.id) == scope {
                store.unpin(task.id)
            }
        }
    }
}

private struct TaskListRow: View {
    let task: Assignment
    let now: Date
    var pin: AssignmentStore.PinScope? = nil
    var writing = false
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    if let pin {
                        Image(systemName: pin == .global ? "pin.fill" : "pin")
                            .font(.system(size: 9))
                            .foregroundStyle(prominence == .increased ? Color.white : jade)
                            .help(pin == .global ? "Pin Globally" : "Pin in Filtered Results")
                    }
                    if writing {
                        Image(systemName: "pencil.line")
                            .font(.system(size: 9))
                            .foregroundStyle(prominence == .increased ? Color.white : jade)
                            .help("You are writing this assignment")
                    }
                    let status = Text(LocalizedStringKey(task.statusLabel))
                    Text("\(task.subject) · \(status)")
                }
                .font(.caption)
                .foregroundStyle(prominence == .increased ? Color.white : Color.secondary)
                .lineLimit(1)
                Text(task.brief)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if task.title != task.brief {
                    Text(task.title)
                        .font(.caption2)
                        .foregroundStyle(prominence == .increased ? Color.white : Color.secondary)
                        .lineLimit(1)
                        .help(task.title)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                if let due = Beijing.parse(task.due), task.kind != "record" {
                    Text(Beijing.dueLabel(due, relativeTo: now))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(task.overdue(at: now) && prominence != .increased ? Color.orange : Color.primary)
                    if task.overdue(at: now) {
                        Text("Overdue").font(.caption2)
                    }
                }
                if let grade = task.grade {
                    Text(grade).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 2)
    }
}

private struct TaskDetail: View {
    let task: Assignment
    @ObservedObject var store: AssignmentStore
    @State private var showOriginal = false
    @State private var confirmSubmit = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(task.subject).font(.subheadline.weight(.semibold)).foregroundStyle(jade)
                        Spacer()
                        PinMenu(task: task, store: store)
                    }
                    HStack {
                        CompletionActions(task: task, store: store)
                        if let finished = store.localCompletion(task.id) {
                            Text(finished ? "Finished on this Mac" : "Unfinished on this Mac").font(.caption)
                        }
                    }
                    Text(task.title).font(.system(size: 23, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(LocalizedStringKey(task.statusLabel))
                        .font(.caption.weight(.semibold)).foregroundStyle(jade)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(jade.opacity(0.12), in: Capsule())
                }
                HStack(alignment: .top, spacing: 18) {
                    field("Assigned", task.assignedDay.flatMap(Beijing.parseDay).map(Beijing.dayLabel))
                    if task.kind != "record" {
                        field("Due", Beijing.parse(task.due).map(Beijing.dateTime), overdue: task.overdue(at: store.now))
                    }
                    if let grade = task.grade { field("Grade", grade) }
                }
                .padding(12)
                .background(panel, in: RoundedRectangle(cornerRadius: 10))
                if task.detailPending {
                    Label("School details have not been updated yet.", systemImage: "clock")
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(task.translated ? LocalizedStringKey("Assignment Instructions (With Translation)") : "Assignment Instructions").font(.headline)
                    ForEach(Array(task.actions.enumerated()), id: \.offset) { _, action in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            if task.actions.count > 1 { Text("•").foregroundStyle(jade) }
                            Text(action).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let submission = task.submission {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("How to Submit").font(.headline)
                        Text(submission).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !task.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Attachments and Links").font(.headline)
                            Spacer()
                            Button("Open Attachment Folder") { store.openAttachmentFolder() }
                                .buttonStyle(.link)
                        }
                        ForEach(Array(task.attachments.enumerated()), id: \.offset) { _, attachment in
                            AttachmentRow(attachment: attachment, task: task, store: store)
                        }
                    }
                }
                DisclosureGroup("Original Text", isExpanded: $showOriginal) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(task.originalTitle).fontWeight(.semibold)
                        Text(task.original.isEmpty ? "The teacher did not provide any text." : task.original)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                }
                submissionSection(task)
                Divider()
                Button { store.open(schoolURL) } label: {
                    Label("Open School Task List", systemImage: "arrow.up.right")
                }
                .buttonStyle(.link)
            }
            .font(.system(size: 13))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        .accessibilityLabel("Assignment Details")
        .alert("Submit this assignment?", isPresented: $confirmSubmit) {
            Button("Cancel", role: .cancel) {}
            Button("Submit") { store.submitToSchool(task) }
        } message: {
            Text("The staged files are uploaded to the school and the task is submitted right away. This cannot be undone from the app.")
        }
    }

    @ViewBuilder
    private func submissionSection(_ task: Assignment) -> some View {
        let working = store.isInProgress(task.id)
        let files = store.submissionFiles(task.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Submission").font(.headline)
                Spacer()
                Toggle("Writing this now", isOn: Binding(get: { working }, set: { store.setInProgress($0 ? task.id : nil) }))
                    .toggleStyle(.switch)
            }
            Text("Files stay on this Mac until you submit. AirDropped files join automatically while this assignment is marked.")
                .font(.caption).foregroundStyle(.secondary)
            if let notice = store.dropNotice, working {
                Text(LocalizedStringKey(notice)).font(.caption).foregroundStyle(jade)
            }
            if files.isEmpty {
                Text("No files yet. Drop them here or use Add Files.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(files, id: \.self) { url in
                    HStack(spacing: 7) {
                        Image(systemName: "doc").foregroundStyle(.secondary)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Button { store.removeSubmissionFile(url, from: task.id) } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from this assignment")
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Add Files…") { store.chooseSubmissionFiles(for: task.id) }
                Button("Reveal Folder") { store.revealSubmissionFolder(task.id) }.disabled(files.isEmpty)
                Spacer()
                if store.submitting {
                    ProgressView().controlSize(.small)
                }
                Button("Submit to School") { confirmSubmit = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(files.isEmpty || store.submitting)
            }
            if let notice = store.submitNotice {
                Text(LocalizedStringKey(notice)).font(.caption)
                    .foregroundStyle(notice.hasPrefix("Submitted") ? jade : .orange)
            }
            Button("Open School Submission Page") { store.open(schoolURL) }.buttonStyle(.link)
        }
        .padding(12)
        .background(panel, in: RoundedRectangle(cornerRadius: 10))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            store.dropFiles(providers, for: task.id)
            return true
        }
    }

    private func field(_ name: LocalizedStringKey, _ value: String?, overdue: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Group {
                if let value, overdue { Text("\(value) · Overdue") }
                else if let value { Text(value) }
                else { Text("Not specified") }
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(overdue ? Color.orange : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AttachmentRow: View {
    let attachment: Attachment
    let task: Assignment
    @ObservedObject var store: AssignmentStore

    var body: some View {
        let local = store.localURL(for: attachment, in: task)
        let link = attachment.originalURL
        HStack(spacing: 9) {
            Image(systemName: local != nil ? "doc" : "link").foregroundStyle(jade)
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.name).lineLimit(2)
                if let status = attachment.downloadStatus, local == nil {
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if let local { Button("Open File") { store.open(local) } }
            if local != nil || link != nil {
                Menu {
                    if let local { Button("Show in Finder") { store.revealAttachment(local) } }
                    if let link {
                        Button("Open Link") { store.open(link) }
                        Button("Copy Link") { store.copy(link) }
                    }
                } label: {
                    Text("More")
                }
                .fixedSize()
            }
        }
        .controlSize(.small)
        .padding(9)
        .background(panel, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AssignmentFilterPopover: View {
    @ObservedObject var store: AssignmentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Filters").font(.headline)
                Spacer()
                Button("Reset") { store.resetFilters() }.buttonStyle(.link)
            }
            Picker("Completion", selection: $store.filters.completion) {
                ForEach(CompletionFilter.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented)
            Text("Submission Status").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 13) {
                ForEach(Submission.allCases) { state in
                    Toggle(LocalizedStringKey(state.label), isOn: membership(state, in: $store.filters.submissions))
                }
            }
            Divider()
            Text("Quick Filters").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 9) {
                ForEach(AssignmentQuickFilter.allCases) { filter in
                    Toggle(LocalizedStringKey(filter.rawValue), isOn: membership(filter, in: $store.filters.quickFilters))
                }
            }
            Divider()
            Text("Task Type").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 9) {
                ForEach(TaskType.allCases) { type in
                    Toggle(LocalizedStringKey(type.rawValue), isOn: membership(type, in: $store.filters.types))
                }
                Button("All") { store.filters.types = [] }.buttonStyle(.link)
            }
            if !store.courses.isEmpty {
                Divider()
                Text("Subjects").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 9) {
                        ForEach(store.courses, id: \.id) { course in
                            Toggle(course.label, isOn: membership(course.id, in: $store.filters.courses))
                        }
                    }
                }
                .frame(height: CGFloat(min(6, (store.courses.count + 1) / 2)) * 26)
            }
        }
        .toggleStyle(.checkbox)
        .padding(16)
        .frame(width: 338)
    }

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2) }

    private func membership<T: Hashable>(_ value: T, in set: Binding<Set<T>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(value) }, set: { selected in
            if selected { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) }
        })
    }
}

struct AssignmentSettings: View {
    @ObservedObject var store: AssignmentStore
    @ObservedObject var assistant: HomeworkAssistant
    @Environment(\.dismiss) private var dismiss
    @State private var editLogin = false
    @State private var name = ""
    @State private var password = ""

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("Settings").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(store.working == "configure")
            }
            AccountSettingsView(store: store)
            Divider()
            LanguageSettings()
            Divider()
            AppearanceSettings()
            Divider()
            DesktopWidgetSettings(store: store)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Collect AirDropped files", isOn: $store.watchDownloads).toggleStyle(.switch)
                Text("While an assignment is marked as being written, new files in \(store.downloadsFolder.path) are copied into that assignment's submission folder. Files stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Label("Attachment Folder", systemImage: "folder").font(.headline)
                Text("Downloaded files are organized by assignment. Changing folders keeps your existing copies in their original location.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(store.attachmentFolder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(2).help(store.attachmentFolder.path)
                HStack {
                    Button("Choose Folder…") { store.chooseAttachmentFolder() }
                    Button("Open Folder") { store.openAttachmentFolder() }
                    Spacer()
                    Button("Use Default") { store.resetAttachmentFolder() }
                        .disabled(store.attachmentFolder == AttachmentLibrary.defaultFolder)
                }
                if let issue = store.attachmentIssue {
                    Text("Could not copy files to the selected folder. \(issue)")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Automatic Sync", isOn: $store.automatic).toggleStyle(.switch)
                Text("Checks for assignments every minute on weekdays from 08:00 to 20:00. The timetable refreshes every 30 minutes. Times use China Standard Time.")
                    .foregroundStyle(.secondary).font(.callout)
            }
            Divider()
            HStack {
                Label(store.snapshot.autoLogin ? "Automatic Login Enabled" : "Set Up Automatic Login",
                      systemImage: store.snapshot.autoLogin ? "checkmark.shield" : "person.crop.circle.badge.key")
                    .font(.headline)
                Spacer()
                if store.snapshot.autoLogin {
                    Button(editLogin ? "Hide" : "Update Account") { editLogin.toggle() }
                }
            }
            if editLogin || !store.snapshot.autoLogin {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("School Account", text: $name)
                    SecureField("School Password", text: $password)
                    HStack {
                        Text("Your login credentials are stored in your Mac's Keychain.").foregroundStyle(.secondary).font(.callout)
                        Spacer()
                        Button("Save and Verify") {
                            if store.configure(name: name, password: password) { password = "" }
                        }
                        .disabled(store.requesting || name.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            if let error = store.settingsIssue {
                Label(LocalizedStringKey(error), systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
            if let notice = store.settingsNotice {
                Label(LocalizedStringKey(notice), systemImage: "checkmark").foregroundStyle(jade)
            }
            HStack {
                Button("School Login Window") { store.verifyLogin() }
                    .disabled(store.requesting)
                if store.working == "configure" || store.working == "verify" {
                    ProgressView().controlSize(.small)
                    Text("Verifying…").foregroundStyle(.secondary)
                } else if store.requesting {
                    Text("Waiting for the current sync to finish.").foregroundStyle(.secondary)
                } else {
                    Text("Use this if the school requires a verification code.").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            Divider()
            HomeworkAISettings(assistant: assistant)
        }
        .padding(23)
        }
        .frame(width: 520, height: 680)
        .sheet(isPresented: $store.schoolLoginOpen) { SchoolLoginSheet(store: store) }
        .onChange(of: store.snapshot.autoLogin) { _, enabled in if enabled { editLogin = false } }
    }
}

private struct Placeholder: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 29)).foregroundStyle(jade)
            Text(title).font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }
}
