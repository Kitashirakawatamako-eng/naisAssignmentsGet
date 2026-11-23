import SwiftUI
import UniformTypeIdentifiers

struct GPAWindow: View {
    @ObservedObject var store: AssignmentStore
    @AppStorage("gradePreferences") private var saved = Data()
    @State private var selectedCourse: String?
    @State private var category: String?
    @State private var target = "90"
    @State private var maximum = "100"
    @State private var expected = "95"
    @State private var count = "2"
    @State private var targetGPA = "3.50"
    @State private var ruleOpen = false
    @State private var scaleOpen = false
    @State private var creditsOpen = false
    @State private var reportedOpen = false
    @State private var scenarioOpen = false
    @State private var importOpen = false
    @State private var previewOpen = false
    @State private var offline = false
    @State private var importRows: [GradeCSV.Row] = []
    @State private var importIssue: String?

    private var book: SemesterGradeBook? { store.snapshot.gradeBook }
    private var term: String { offline ? "" : book?.semesterId ?? "" }
    private var schoolGrades: [SchoolGrade] { offline ? [] : book?.records ?? [] }
    private var allRecords: [SchoolGrade] {
        GradeCSV.merged(school: schoolGrades, imported: store.importedGrades.terms[term] ?? [])
    }
    private var preferences: GradePreferences {
        (try? JSONDecoder().decode(GradePreferences.self, from: saved)) ?? GradePreferences()
    }

    private var courses: [(id: String, subject: String)] {
        var names = offline ? [:] : Dictionary(uniqueKeysWithValues: store.courses.map { ($0.id, $0.label) })
        for grade in allRecords where names[grade.course] == nil { names[grade.course] = grade.subject }
        return names.map { (id: $0.key, subject: $0.value) }
            .sorted { $0.subject.localizedStandardCompare($1.subject) == .orderedAscending }
    }

    private var activeCourse: String? {
        if let selectedCourse, courses.contains(where: { $0.id == selectedCourse }) { return selectedCourse }
        return courses.first?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ThemeMascot(fallback: "chart.bar.xaxis")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Grades").font(.system(size: 27, weight: .semibold))
                    Text("Semester grades and goals").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                DeskTabs(page: $store.page)
                Button {
                    store.syncSemesterGrades()
                } label: {
                    Label(store.working == "grades" ? LocalizedStringKey("Syncing Grades…") : "Sync Semester Grades",
                          systemImage: "arrow.clockwise")
                }
                .disabled(store.requesting)
                .help("Read published grades without downloading assignments or attachments.")
                Menu {
                    Button("Import Grades CSV…") { importOpen = true }
                    Button("Record Transcript GPA…") { reportedOpen = true }
                    Button("Copy Grade Sync Diagnostics") { store.copyGradeDiagnostics() }
                    if book?.semesterId != nil, store.importedGrades.terms[""]?.isEmpty == false {
                        Toggle("View Offline Grades", isOn: $offline)
                    }
                } label: { Label("Grade Tools", systemImage: "ellipsis.circle") }
                .fixedSize()
                Button { store.settingsOpen = true } label: { Label("Settings", systemImage: "gearshape") }
            }
            .controlSize(.large)
            .padding(.horizontal, 22).padding(.vertical, 16)
            .background(headerDecoration)
            Divider()
            if let issue = importIssue ?? (offline ? nil : store.gradeIssue ?? book?.syncIssue), store.working != "grades" {
                Label(LocalizedStringKey(issue), systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                Divider()
            }
            if let course = activeCourse {
                HStack(spacing: 0) {
                    sidebar.frame(width: 230)
                    Divider()
                    let data = grades(for: course)
                    let groups = availableGroups(for: course)
                    let selected = category.flatMap { groups.contains($0) ? $0 : nil } ?? groups.first ?? CourseGrades.totalGroup
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            estimatePanel(course)
                            courseSummary(course, data)
                            overall(course, data: data, group: selected)
                            scenario(data, group: selected, groups: groups)
                            scores(course, data: data)
                        }
                        .padding(18)
                        .frame(maxWidth: 1020)
                        .frame(maxWidth: .infinity)
                    }
                    .sheet(isPresented: $ruleOpen) {
                        CourseRuleEditor(initial: rule(for: course), groups: groupsForRules(course),
                                         title: courses.first { $0.id == course }?.subject ?? course) { value in
                            update { $0.rules[ruleKey(course)] = value }
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 32)).foregroundStyle(jade)
                    Text("No Grades Yet").font(.headline)
                    Text("Sync semester grades to get started.").foregroundStyle(.secondary)
                    Button("Import Grades CSV…") { importOpen = true }
                    transcriptGPA
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(backdrop)
        .frame(minWidth: 960, minHeight: 570)
        .sheet(isPresented: $scaleOpen) {
            GPAScaleEditor(initial: preferences.scale) { value in update { $0.scale = value } }
        }
        .sheet(isPresented: $creditsOpen) {
            GradeCreditEditor(courses: courses.map { GradeCreditEditor.Row(id: $0.id, subject: $0.subject, rule: rule(for: $0.id)) }) { rows in
                update { pref in for row in rows { pref.rules[ruleKey(row.id)] = row.rule } }
            }
        }
        .sheet(isPresented: $reportedOpen) {
            TranscriptGPAEditor(initial: preferences.reported?[term] ?? ReportedGPA()) { value in
                update { $0.reported = ($0.reported ?? [:]).merging([term: value]) { _, new in new } }
            }
        }
        .sheet(isPresented: $scenarioOpen) {
            GradeScenarioEditor(courses: courses.map { GradeScenarioEditor.Course(id: $0.id, name: $0.subject, grades: grades(for: $0.id)) },
                                scale: GPAScale(preferences.scale), initial: preferences.scenarios?[term] ?? [],
                                target: GradePoints.number(targetGPA)) { value in
                update { $0.scenarios = ($0.scenarios ?? [:]).merging([term: value]) { _, new in new } }
            }
        }
        .fileImporter(isPresented: $importOpen, allowedContentTypes: [.commaSeparatedText]) { selected in
            do {
                let url = try selected.get()
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= 5_000_000 else { throw GradeCSV.ImportError.format }
                importRows = try GradeCSV.parse(Data(contentsOf: url))
                importIssue = nil
                previewOpen = true
            } catch { importIssue = error.localizedDescription }
        }
        .sheet(isPresented: $previewOpen) { importPreview }
    }

    private var sidebar: some View {
        List(selection: $selectedCourse) {
            Section("Subjects") {
                ForEach(courses, id: \.id) { course in
                    let data = grades(for: course.id)
                    HStack(spacing: 5) {
                        Text(course.subject).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(data.percent().map(percentText) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(course.id)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(panel)
        .onAppear { if selectedCourse == nil { selectedCourse = activeCourse } }
    }

    private func courseSummary(_ course: String, _ data: CourseGrades) -> some View {
        GradeSection {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(courses.first { $0.id == course }?.subject ?? course).font(.title3.weight(.semibold))
                    Text(data.percent().map(percentText) ?? "—")
                        .font(.system(size: 39, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(data.rule.weighted ? "Category-weighted percentage" : "Total-points percentage")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Course Rules…") { ruleOpen = true }
            }
            if let percent = data.percent() { ProgressView(value: min(percent, 100), total: 100) }
            Text("\(data.scored) scored · \(data.unscored) incomplete · \(data.omitted) excluded")
                .font(.caption).foregroundStyle(.secondary)
            coverage
            if data.rule.weighted, data.percent() == nil {
                Text("Use Course Rules to complete category weights and points.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var coverage: some View {
        if offline || (term.isEmpty && store.importedGrades.terms[""]?.isEmpty == false) {
            Text("Offline Grade Import").font(.caption).foregroundStyle(.secondary)
        } else if let start = book?.startDay, let end = book?.endDay {
            Text("Semester range: \(start) – \(end)").font(.caption).foregroundStyle(.secondary)
        }
        let days = allRecords.compactMap(\.day).sorted()
        if let first = days.first, let last = days.last {
            Text("Available grade dates: \(first) – \(last)").font(.caption).foregroundStyle(.secondary)
        }
        if !offline, let imported = Beijing.parse(book?.checkedAt) {
            Text("Published semester grades fetched \(Beijing.dateTime(imported))")
                .font(.caption).foregroundStyle(.secondary)
            if let count = book?.sourcePublishedCount {
                Text("\(count) published entries available from the school list")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if !offline {
            Text("Based on cached grades. Sync the semester for a wider date range.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !offline, book?.syncIssue != nil, let failed = Beijing.parse(book?.lastAttemptAt) {
            Text("Last attempted \(Beijing.dateTime(failed))").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func scenario(_ data: CourseGrades, group: String, groups: [String]) -> some View {
        GradeSection {
            HStack {
                Label("Course Goal", systemImage: "scope").font(.headline)
                Spacer()
                Button("Maintain Current Grade") {
                    if let value = data.percent() { target = plain(value) }
                }.disabled(data.percent() == nil)
            }
            if data.rule.weighted {
                Picker("Category", selection: Binding(get: { group }, set: { category = $0 })) {
                    ForEach(groups, id: \.self) { name in Text(LocalizedStringKey(name)).tag(name) }
                }
            }
            HStack(spacing: 10) {
                input("Target %", text: $target)
                input("Max Points Each", text: $maximum)
                input("Expected Points", text: $expected)
                input("Number of Items", text: $count)
            }
            if let target = GradePoints.number(target), target <= 200,
               let maximum = GradePoints.number(maximum), maximum > 0,
               let needed = data.requiredScore(target: target, addedMaximum: maximum, in: group) {
                if needed <= maximum + 1e-8 {
                    Text("Next item needs at least \(roundedUp(needed)) / \(plain(maximum))")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(jade)
                    if let projected = data.percent(additional: GradePoints(earned: maximum, possible: maximum), to: group) {
                        Text("With full marks on the next item: \(percentText(projected))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if let best = data.percent(additional: GradePoints(earned: maximum, possible: maximum), to: group) {
                    Text("One item can reach at most \(percentText(best)).")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.orange)
                }
                if let expected = GradePoints.number(expected), expected <= maximum,
                   let count = Int(count), (1...200).contains(count),
                   let projection = data.percent(additional: GradePoints(earned: expected * Double(count),
                                                                         possible: maximum * Double(count)), to: group) {
                    Text("After \(count) items at \(plain(expected)) points each: \(percentText(projection))")
                    let capacity = maximum * Double(count)
                    if let total = data.requiredScore(target: target, addedMaximum: capacity, in: group) {
                        if total <= capacity + 1e-8 {
                            Text("To hit the goal in \(count) items, average at least \(roundedUp(total / Double(count))) points each.")
                        } else if let best = data.percent(additional: GradePoints(earned: capacity, possible: capacity), to: group) {
                            Text("With full marks on all \(count) items, the highest grade is \(percentText(best)).")
                                .foregroundStyle(.orange)
                        }
                    }
                    if let minimum = data.minimumCount(target: target, maximum: maximum, expected: expected, in: group) {
                        if minimum == 0 {
                            Text("The current grade already meets this target.")
                        } else {
                            Text("At that score, at least \(minimum) more items are needed.")
                        }
                    } else {
                        Text("This score per item cannot reach the target.").foregroundStyle(.orange)
                    }
                } else {
                    Text("Enter 1–200 items and an expected score within the maximum.").foregroundStyle(.secondary)
                }
            } else {
                Text("Enter a valid goal and complete the course rules to calculate a result.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func estimatePanel(_ course: String) -> some View {
        let pref = preferences
        let key = ruleKey(course)
        let rows = pref.sectionPlans?[key] ?? []
        let current = OverallEstimate(records: allRecords, courses: courses.map(\.id), term: term, preferences: pref)
        let projected = OverallEstimate(records: allRecords, courses: courses.map(\.id), term: term, preferences: pref, projected: true)
        let priorKey = term + (current.maximum == 5 ? "/weighted" : "/4")
        let prior = pref.priorTerms?[priorKey] ?? PriorGPA()
        func save(_ rows: [GradeSectionInput]) {
            update { $0.sectionPlans = ($0.sectionPlans ?? [:]).merging([key: rows]) { _, new in new } }
        }
        func field(_ id: UUID, _ path: WritableKeyPath<GradeSectionInput, String>) -> Binding<String> {
            Binding(get: { rows.first { $0.id == id }?[keyPath: path] ?? "" }, set: { value in
                var next = preferences.sectionPlans?[key] ?? []
                if let i = next.firstIndex(where: { $0.id == id }) { next[i][keyPath: path] = value; save(next) }
            })
        }
        func previous(_ path: WritableKeyPath<PriorGPA, String>) -> Binding<String> {
            Binding(get: { prior[keyPath: path] }, set: { value in
                update {
                    var terms = $0.priorTerms ?? [:]
                    terms[priorKey, default: PriorGPA()][keyPath: path] = value
                    $0.priorTerms = terms
                }
            })
        }
        func display(_ value: Double?) -> String {
            value.map { String(format: "%.2f / %d.0", $0, current.maximum) } ?? "—"
        }
        return GradeSection {
            HStack {
                Label("Overall GPA estimate", systemImage: "sum").font(.headline)
                Spacer()
                Picker("Display scale", selection: Binding(get: { current.maximum }, set: { value in update { $0.weightedEstimate = value == 5 } })) {
                    Text("Unweighted 4.0").tag(4)
                    Text("Weighted 5.0").tag(5)
                }.pickerStyle(.segmented).fixedSize()
            }
            LabeledContent("Semester total", value: display(current.total.average))
            Text("\(current.total.courses) of \(current.eligible) courses included").font(.caption)
            Text("90 / 80 / 70 / 60% earn 4 / 3 / 2 / 1 points. Weighted GPA adds 1 for AP or 0.5 for Honors on passing grades, up to 5. Change bonuses in Course Credits. Blank credits count as 1.").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Cumulative GPA across semesters") {
                HStack {
                    input("Previous cumulative GPA", text: previous(\.average))
                    input("Previous credits", text: previous(\.credits))
                }
                Text("Use your previous GPA on the selected scale and enter this semester’s actual course credits.").font(.caption)
                LabeledContent("Cumulative estimate", value: display(current.cumulative(prior: prior)))
            }
            Divider()
            DisclosureGroup("What if my section scores change?") {
                Text("Enter expected final percentages and weights for the selected course. Weights must total 100%. Other courses keep their current grades unless you enter a plan for them.").font(.caption)
                ForEach(rows) { row in
                    HStack {
                        input("Section", text: field(row.id, \.name))
                        input("Weight (%)", text: field(row.id, \.weight))
                        input("Expected score (%)", text: field(row.id, \.score))
                        Button { save(rows.filter { $0.id != row.id }) } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove section")
                    }
                }
                Button("Add section") {
                    let names = groupsForRules(course).filter { name in !rows.contains { $0.name == name } }
                    let name = names.first ?? ""
                    save(rows + [GradeSectionInput(name: name, weight: rule(for: course).weights[name] ?? "", score: "")])
                }
                if let percent = GradeSectionInput.projectedPercent(rows) {
                    LabeledContent("Projected course grade", value: percentText(percent))
                }
                if !projected.valid { Text("Complete all planned scores and make each planned course’s weights total 100%.").foregroundStyle(.orange) }
                LabeledContent("Projected semester GPA", value: display(projected.valid ? projected.total.average : nil))
                if !prior.credits.isEmpty { LabeledContent("Projected cumulative GPA", value: display(projected.cumulative(prior: prior))) }
            }
        }
    }

    private func overall(_ course: String, data: CourseGrades, group: String) -> some View {
        GradeSection {
            HStack {
                Label("Semester GPA", systemImage: "chart.bar.xaxis").font(.headline)
                Spacer()
                Button("Course Credits…") { creditsOpen = true }
                Button("GPA Scale…") { scaleOpen = true }
            }
            transcriptGPA
            if let scale = GPAScale(preferences.scale) {
                if preferences.scale == GPAScale.example {
                    Text("This calculation uses the example GPA scale.").font(.caption).foregroundStyle(.orange)
                }
                let current = creditTotal(using: scale)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(current.average.map(gpaText) ?? "—")
                        .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                    let eligible = courses.filter { rule(for: $0.id).excludedFromGPA != true }.count
                    Text("\(current.courses) of \(eligible) courses included")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    input("Target GPA", text: $targetGPA).frame(maxWidth: 120)
                }
                if data.rule.excludedFromGPA == true {
                    Text("This course is excluded from GPA.").font(.caption).foregroundStyle(.secondary)
                } else if let target = GradePoints.number(targetGPA), target <= 20,
                   let credits = GradePoints.number(data.rule.credits), credits > 0, data.percent() != nil {
                    let others = creditTotal(using: scale, except: course)
                    let bonus = GradePoints.number(data.rule.bonus) ?? 0
                    if let threshold = scale.minimumPercent(for: others.pointsNeeded(to: target, courseCredits: credits) - bonus) {
                        Text("With other included courses fixed, this course needs \(percentText(threshold)).")
                        if let maximum = GradePoints.number(maximum), maximum > 0,
                           let needed = data.requiredScore(target: threshold, addedMaximum: maximum, in: group),
                           needed <= maximum + 1e-8 {
                            Text("For the GPA goal, the next item needs \(roundedUp(needed)) / \(plain(maximum)).")
                                .foregroundStyle(jade).fontWeight(.medium)
                        }
                        Button("Use as Course Goal") { self.target = plain(threshold) }.buttonStyle(.link)
                    } else {
                        Text("This course alone cannot reach the target GPA.").foregroundStyle(.orange)
                    }
                } else {
                    Text("Enter the course credits and a GPA target to see the required grade.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Set the school’s percentage-to-GPA scale and enter credits for each course.")
                    .foregroundStyle(.secondary)
            }
            Button("Multi-Course Scenario…") { scenarioOpen = true }.buttonStyle(.link)
        }
    }

    private func scores(_ course: String, data: CourseGrades) -> some View {
        let categories = groupsForRules(course)
        let rows = records(for: course)
        let pref = preferences
        let byCategory = Dictionary(grouping: rows) { pref.groups[$0.id] ?? $0.group }
        return GradeSection {
            Label("Published Scores", systemImage: "list.bullet.rectangle").font(.headline)
            if !data.rule.pastPoints.isEmpty {
                Text("Includes manually entered earlier points.").font(.caption).foregroundStyle(.secondary)
            }
            if rows.isEmpty { Text("No published scores for this course.").foregroundStyle(.secondary) }
            ForEach(byCategory.keys.sorted(), id: \.self) { category in
                let entries = byCategory[category] ?? []
                let totals = CourseGrades(records: entries, rule: GradingRule(), excluded: pref.omitted)
                Divider()
                HStack {
                    Text(LocalizedStringKey(category)).font(.subheadline.weight(.semibold)).foregroundStyle(jade)
                    Spacer()
                    if let points = totals.totals[CourseGrades.totalGroup] {
                        Text("\(plain(points.earned)) / \(plain(points.possible)) · \(entries.count) entries")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Text("\(entries.count) entries").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(entries) { row in
                    scoreRow(row, excluded: pref.omitted.contains(row.id), categories: data.rule.weighted ? categories : [])
                }
            }
        }
    }

    private func scoreRow(_ row: SchoolGrade, excluded: Bool, categories: [String]) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 5) {
                    if let day = row.day { Text(day) }
                    if row.exempt || excluded { Text("Excluded") }
                    else if row.score != nil && row.total == nil { Text("Maximum Missing") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let score = row.score.map({ $0 + (row.total.map { " / " + $0 } ?? "") }) ?? row.level {
                Text(score).fontWeight(.semibold).monospacedDigit()
            } else {
                Text("Score Missing").font(.caption).foregroundStyle(.secondary)
            }
            if !row.exempt || !categories.isEmpty {
                Menu {
                    if !row.exempt {
                        Button(excluded ? LocalizedStringKey("Include Score") : "Exclude Score") {
                            update { if excluded { $0.omitted.remove(row.id) } else { $0.omitted.insert(row.id) } }
                        }
                    }
                    if !categories.isEmpty {
                        Menu("Category") {
                            ForEach(categories, id: \.self) { name in
                                Button(LocalizedStringKey(name)) { update { $0.groups[row.id] = name } }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Score Options")
            }
        }
        .padding(.vertical, 3)
    }

    private func input(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text).labelsHidden().textFieldStyle(.roundedBorder)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func records(for course: String) -> [SchoolGrade] { allRecords.filter { $0.course == course } }
    private func ruleKey(_ course: String) -> String { term + "\u{1f}" + course }
    private func rule(for course: String) -> GradingRule { preferences.rules[ruleKey(course)] ?? GradingRule() }

    private func grades(for course: String) -> CourseGrades {
        let pref = preferences
        return CourseGrades(records: records(for: course), rule: rule(for: course), groups: pref.groups, excluded: pref.omitted)
    }

    private func groupsForRules(_ course: String) -> [String] {
        let rule = rule(for: course)
        return Set(records(for: course).map { preferences.groups[$0.id] ?? $0.group })
            .union(rule.weights.keys).union(rule.pastPoints.keys.filter { !$0.isEmpty }).sorted()
    }

    private func availableGroups(for course: String) -> [String] {
        rule(for: course).weighted ? groupsForRules(course) : [CourseGrades.totalGroup]
    }

    private func creditTotal(using scale: GPAScale, except course: String? = nil) -> GPACreditTotal {
        var total = GPACreditTotal()
        for candidate in courses where candidate.id != course {
            let data = grades(for: candidate.id)
            guard data.rule.excludedFromGPA != true, let percent = data.percent(), let points = scale.points(at: percent),
                  let credits = GradePoints.number(data.rule.credits), credits > 0 else { continue }
            total.add(points: points + (GradePoints.number(data.rule.bonus) ?? 0), credits: credits)
        }
        return total
    }

    @ViewBuilder private var transcriptGPA: some View {
        if let reported = preferences.reported?[term], !reported.semester.isEmpty || !reported.cumulative.isEmpty {
            HStack {
                if !reported.semester.isEmpty { Text("Transcript Semester GPA \(reported.semester)") }
                if !reported.cumulative.isEmpty { Text("Transcript Cumulative GPA \(reported.cumulative)") }
                if !reported.basis.isEmpty { Text(LocalizedStringKey(reported.basis)).foregroundStyle(.secondary) }
            }.font(.callout)
            Text("Recorded from a transcript on this Mac").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var importPreview: some View {
        let destinationTerm = term
        var aliases: [String: Set<String>] = [:]
        for course in courses {
            aliases[course.id, default: []].insert(course.id)
            aliases[course.subject, default: []].insert(course.id)
        }
        let plan = GradeCSV.plan(importRows, school: schoolGrades, stored: store.importedGrades.terms[term] ?? [],
                                 aliases: aliases, start: offline ? nil : book?.startDay, end: offline ? nil : book?.endDay)
        return GradeImportPreview(plan: plan, offline: destinationTerm.isEmpty) {
            guard term == destinationTerm else {
                importIssue = "The active semester changed. Review the import again."
                previewOpen = false
                return
            }
            do { try store.saveGradeImport(plan.records, term: destinationTerm); previewOpen = false }
            catch { importIssue = error.localizedDescription; previewOpen = false }
        }
    }

    private func update(_ changes: (inout GradePreferences) -> Void) {
        var value = preferences
        changes(&value)
        if let encoded = try? JSONEncoder().encode(value) { saved = encoded }
    }
}

private struct GradeSection<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .background(panel, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CourseRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: GradingRule
    @State private var groupNames: [String]
    @State private var extraName = ""
    @State private var earlierScores: [String: String]
    @State private var earlierMaximums: [String: String]
    let title: String
    let save: (GradingRule) -> Void

    init(initial: GradingRule, groups: [String], title: String, save: @escaping (GradingRule) -> Void) {
        _draft = State(initialValue: initial)
        _groupNames = State(initialValue: groups)
        _earlierScores = State(initialValue: initial.pastPoints.mapValues { plain($0.earned) })
        _earlierMaximums = State(initialValue: initial.pastPoints.mapValues { plain($0.possible) })
        self.title = title
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.semibold))
            Text("Course Rules").font(.headline)
            Form {
                TextField("Credits", text: $draft.credits)
                TextField("GPA Bonus", text: $draft.bonus)
                Toggle("Weight by category", isOn: $draft.weighted)
            }
            Divider()
            if draft.weighted {
                HStack {
                    TextField("New Category", text: $extraName)
                    Button("Add Category") {
                        let name = extraName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty && !groupNames.contains(name) { groupNames.append(name) }
                        extraName = ""
                    }.disabled(extraName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Positive category weights must add up to 100%.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Earlier Points").font(.headline)
            Text("Enter only points from grades absent from the list.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(draft.weighted ? groupNames : [CourseGrades.totalGroup], id: \.self) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            if draft.weighted { Text(LocalizedStringKey(group)).fontWeight(.medium) }
                            HStack(spacing: 8) {
                                if draft.weighted {
                                    TextField("Weight %", text: dictionaryBinding($draft.weights, key: group))
                                }
                                TextField("Points Earned", text: dictionaryBinding($earlierScores, key: group))
                                TextField("Points Possible", text: dictionaryBinding($earlierMaximums, key: group))
                            }.textFieldStyle(.roundedBorder)
                        }
                    }
                }.padding(.vertical, 1)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { commit() }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(20).frame(width: 490, height: 425)
    }

    private var activeGroups: [String] { draft.weighted ? groupNames : [CourseGrades.totalGroup] }

    private var valid: Bool {
        (draft.credits.isEmpty || (GradePoints.number(draft.credits) ?? 0) > 0)
            && (draft.bonus.isEmpty || (GradePoints.number(draft.bonus) ?? 11) <= 10)
            && activeGroups.allSatisfy { group in
                let score = earlierScores[group] ?? ""
                let maximum = earlierMaximums[group] ?? ""
                return (score.isEmpty && maximum.isEmpty) || GradePoints(earned: score, possible: maximum) != nil
            }
    }

    private func commit() {
        var result = draft
        for group in activeGroups {
            result.pastPoints[group] = GradePoints(earned: earlierScores[group], possible: earlierMaximums[group])
        }
        save(result)
        dismiss()
    }

    private func dictionaryBinding(_ source: Binding<[String: String]>, key: String) -> Binding<String> {
        Binding(get: { source.wrappedValue[key] ?? "" }, set: { source.wrappedValue[key] = $0 })
    }
}

private struct GPAScaleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var initial: String
    let save: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GPA Scale").font(.title2.weight(.semibold))
            Text("Enter one minimum percentage and GPA pair per line, for example 90=4.0. Include a 0% row.")
                .foregroundStyle(.secondary)
            TextEditor(text: $initial).font(.system(.body, design: .monospaced))
                .padding(6).border(.quaternary)
            Button("Fill Example Scale") { initial = GPAScale.example }.buttonStyle(.link)
            Text("The example is for simulation. Use the school’s scale for your courses.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(initial); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(!initial.isEmpty && GPAScale(initial) == nil)
            }
        }.padding(20).frame(width: 410, height: 322)
    }
}

private func plain(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...8)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
}

private func percentText(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2))) + "%"
}

private func gpaText(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }

private func roundedUp(_ value: Double) -> String { plain(ceil(value * 100 - 1e-8) / 100) }
