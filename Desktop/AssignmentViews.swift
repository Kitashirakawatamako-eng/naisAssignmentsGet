import SwiftUI

let jade = Color(nsColor: NSColor(name: nil) { appearance in
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return dark ? NSColor(srgbRed: 0.47, green: 0.80, blue: 0.70, alpha: 1)
        : NSColor(srgbRed: 0.13, green: 0.35, blue: 0.29, alpha: 1)
})
let panel = Color(nsColor: .controlBackgroundColor)
let backdrop = Color(nsColor: .windowBackgroundColor)
private let schoolURL = URL(string: "https://naisstu.schoolis.cn/Home#!/task/list/")!

struct AssignmentWindow: View {
    @ObservedObject var store: AssignmentStore
    @State private var filtersOpen = false
    @FocusState var searchFocused: Bool

    var body: some View {
        let rows = store.rows
        VStack(spacing: 0) {
            header
            controls
            if let issue = store.syncIssue {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(issue).frame(maxWidth: .infinity, alignment: .leading)
                    if store.needsLogin { Button("登录设置") { store.settingsOpen = true } }
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
                    if let task = rows.first(where: { $0.id == store.selectedID }) {
                        TaskDetail(task: task, store: store).id(task.id)
                    } else {
                        Placeholder(icon: "doc.text.magnifyingglass", title: "作业详情", subtitle: "选中一项作业查看。")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(backdrop)
            }
            Divider()
            footer(count: rows.count, pending: rows.filter(\.pending).count)
        }
        .frame(minWidth: 850, minHeight: 560)
        .background(backdrop)
        .tint(jade)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(jade)
                .frame(width: 43, height: 43)
                .background(jade.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("作业速览").font(.system(size: 27, weight: .semibold))
                Text(Beijing.dayLabel(store.now)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            DeskTabs(page: $store.page)
            Button { store.sync() } label: {
                Label(store.working == "sync" ? "正在同步" : "立即同步", systemImage: "arrow.clockwise")
            }
            .disabled(store.working != nil)
            .keyboardShortcut("r", modifiers: .command)
            Button { store.settingsOpen = true } label: { Label("设置", systemImage: "gearshape") }
        }
        .controlSize(.large)
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private var controls: some View {
        HStack(spacing: 9) {
            Picker("布置日期", selection: $store.filters.range) {
                ForEach(DateRange.allCases) { range in Text(range.rawValue).tag(range) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索作业", text: $store.filters.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !store.filters.search.isEmpty {
                    Button { store.filters.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索")
                }
            }
            .padding(.horizontal, 9)
            .frame(width: 165, height: 27)
            .background(panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.10)) }

            Button { filtersOpen.toggle() } label: {
                Label(store.filters.activeCount == 0 ? "筛选" : "筛选 \(store.filters.activeCount)",
                      systemImage: "line.3.horizontal.decrease")
            }
            .accessibilityLabel("筛选")
            .popover(isPresented: $filtersOpen, arrowEdge: .bottom) { AssignmentFilterPopover(store: store) }
            Button { store.exportChecklist() } label: {
                Label("导出待办", systemImage: "square.and.arrow.down")
            }
            .disabled(store.pendingCount == 0)
            .help(store.pendingCount == 0 ? "当前筛选没有待办" : "导出 \(store.pendingCount) 项待办为 Markdown")
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        .controlSize(.regular)
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }

    private func assignmentList(_ rows: [Assignment]) -> some View {
        Group {
            if store.loading {
                ProgressView("正在读取作业").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.needsSetup && store.snapshot.tasks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle").font(.system(size: 32)).foregroundStyle(jade)
                    Text("登录后查看作业和课表").font(.headline)
                    Button("登录学校账号") { store.settingsOpen = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                Placeholder(icon: "tray", title: store.snapshot.tasks.isEmpty ? "还没有作业记录" : "没有符合条件的作业",
                            subtitle: store.snapshot.tasks.isEmpty ? "点「立即同步」读取学校任务。" : "试试其他日期或调整筛选。")
            } else {
                List(selection: $store.selectedID) {
                    ForEach(TaskDay.groups(rows)) { day in
                        Section(day.label) {
                            ForEach(day.tasks) { task in
                                TaskListRow(task: task, now: store.now)
                                    .tag(task.id)
                                    .listRowInsets(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
                                    .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("作业列表")
            }
        }
    }

    private func footer(count: Int, pending: Int) -> some View {
        HStack(spacing: 8) {
            if store.working == "sync" {
                ProgressView().controlSize(.small).scaleEffect(0.75)
                Text("正在同步")
            } else {
                Circle().fill(store.automatic && store.inSchedule ? jade : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(store.automatic ? (store.inSchedule ? "实时同步已开启" : "等待同步时段") : "实时同步已暂停")
            }
            Text("·")
            Text(store.lastSync)
            if store.snapshot.warningCount > 0 {
                Label("\(store.snapshot.warningCount) 项待重试", systemImage: "exclamationmark.circle")
            }
            Spacer()
            Text("\(count) 项 · \(pending) 待办").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 22)
        .frame(height: 32)
    }
}

private struct TaskListRow: View {
    let task: Assignment
    let now: Date
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(task.subject + " · " + task.status)
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
                        Text("逾期").font(.caption2)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(task.subject).font(.subheadline.weight(.semibold)).foregroundStyle(jade)
                    Text(task.title).font(.system(size: 23, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(task.status)
                        .font(.caption.weight(.semibold)).foregroundStyle(jade)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(jade.opacity(0.12), in: Capsule())
                }
                HStack(alignment: .top, spacing: 18) {
                    field("布置日期", task.assignedDay.flatMap(Beijing.parseDay).map(Beijing.dayLabel) ?? "未注明")
                    if task.kind != "record" {
                        field("截止", Beijing.parse(task.due).map(Beijing.dateTime) ?? "未注明", overdue: task.overdue(at: store.now))
                    }
                    if let grade = task.grade { field("成绩", grade) }
                }
                .padding(12)
                .background(panel, in: RoundedRectangle(cornerRadius: 10))
                if task.detailPending {
                    Label("学校详情暂未更新。", systemImage: "clock")
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(task.translated ? "作业要求（含译文）" : "作业要求").font(.headline)
                    ForEach(Array(task.actions.enumerated()), id: \.offset) { _, action in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            if task.actions.count > 1 { Text("•").foregroundStyle(jade) }
                            Text(action).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let submission = task.submission {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("怎么交").font(.headline)
                        Text(submission).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !task.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("附件与链接").font(.headline)
                        ForEach(Array(task.attachments.enumerated()), id: \.offset) { _, attachment in
                            AttachmentRow(attachment: attachment, store: store)
                        }
                    }
                }
                DisclosureGroup("老师原文", isExpanded: $showOriginal) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(task.originalTitle).fontWeight(.semibold)
                        Text(task.original.isEmpty ? "老师未填写正文。" : task.original)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                }
                Divider()
                Button { store.open(schoolURL) } label: {
                    Label("打开学校任务页", systemImage: "arrow.up.right")
                }
                .buttonStyle(.link)
            }
            .font(.system(size: 13))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        .accessibilityLabel("作业详情")
    }

    private func field(_ name: String, _ value: String, overdue: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(overdue ? value + " · 逾期" : value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(overdue ? Color.orange : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AttachmentRow: View {
    let attachment: Attachment
    @ObservedObject var store: AssignmentStore

    var body: some View {
        let local = store.localURL(for: attachment)
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
            if let local { Button("打开文件") { store.open(local) } }
            if let link {
                Menu {
                    Button("打开原始链接") { store.open(link) }
                    Button("复制下载链接") { store.copy(link) }
                } label: {
                    Text("链接")
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
                Text("筛选").font(.headline)
                Spacer()
                Button("重置") { store.resetFilters() }.buttonStyle(.link)
            }
            Text("提交状态").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 13) {
                ForEach(Submission.allCases) { state in
                    Toggle(state.label, isOn: membership(state, in: $store.filters.submissions))
                }
            }
            Divider()
            Text("任务类型").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 9) {
                ForEach(TaskType.allCases) { type in
                    Toggle(type.rawValue, isOn: membership(type, in: $store.filters.types))
                }
                Button("全部") { store.filters.types = [] }.buttonStyle(.link)
            }
            if !store.courses.isEmpty {
                Divider()
                Text("科目").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
    @Environment(\.dismiss) private var dismiss
    @State private var editLogin = false
    @State private var name = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("设置").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("实时同步", isOn: $store.automatic).toggleStyle(.switch)
                Text("工作日 08:00–20:00 每分钟检查作业。课表每 30 分钟更新，时间按北京时间。")
                    .foregroundStyle(.secondary).font(.callout)
            }
            Divider()
            HStack {
                Label(store.snapshot.autoLogin ? "自动登录已启用" : "设置自动登录",
                      systemImage: store.snapshot.autoLogin ? "checkmark.shield" : "person.crop.circle.badge.key")
                    .font(.headline)
                Spacer()
                if store.snapshot.autoLogin {
                    Button(editLogin ? "收起" : "更新账号") { editLogin.toggle() }
                }
            }
            if editLogin || !store.snapshot.autoLogin {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("学校账号", text: $name)
                    SecureField("学校密码", text: $password)
                    HStack {
                        Text("登录凭据保存在本机钥匙串。").foregroundStyle(.secondary).font(.callout)
                        Spacer()
                        Button("保存并验证") {
                            store.configure(name: name, password: password)
                            password = ""
                        }
                        .disabled(store.requesting || name.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            if let error = store.settingsIssue {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
            if let notice = store.settingsNotice {
                Label(notice, systemImage: "checkmark").foregroundStyle(jade)
            }
            HStack {
                Button("学校登录窗口") { store.verifyLogin() }
                    .disabled(store.requesting)
                if store.working == "configure" || store.working == "verify" {
                    ProgressView().controlSize(.small)
                    Text("正在验证……").foregroundStyle(.secondary)
                } else {
                    Text("学校要求验证码时使用。").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .padding(23)
        .frame(width: 468)
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
