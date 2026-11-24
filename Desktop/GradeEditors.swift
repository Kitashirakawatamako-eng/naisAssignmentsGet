import SwiftUI

struct GradeImportPreview: View {
    @Environment(\.dismiss) private var dismiss
    let plan: GradeCSV.Plan
    let offline: Bool
    let commit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review Grade Import").font(.title2.weight(.semibold))
            Text(offline ? "Offline Grade Import" : "Import Into Current Semester")
                .font(.callout).foregroundStyle(.secondary)
            let updates = plan.preview.filter { $0.disposition.imports }.count
            Text("\(updates) of \(plan.preview.count) records will be imported")
            List(plan.preview) { row in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.grade.title).lineLimit(1)
                        Text([row.grade.subject, row.grade.category, row.grade.day ?? ""]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let score = row.grade.score {
                        Text(score + (row.grade.total.map { " / " + $0 } ?? "")).monospacedDigit()
                    } else if let level = row.grade.level {
                        Text(level)
                    }
                    Text(LocalizedStringKey(row.disposition.rawValue))
                        .foregroundStyle(row.disposition == .conflict ? Color.orange : Color.secondary)
                        .font(.caption)
                }
            }
            .border(.quaternary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import Grades") { commit() }.keyboardShortcut(.defaultAction).disabled(updates == 0)
            }
        }
        .padding(20).frame(width: 600, height: 470)
    }
}

struct GradeCreditEditor: View {
    struct Row: Identifiable {
        let id, subject: String
        var rule: GradingRule
    }

    @Environment(\.dismiss) private var dismiss
    @State var courses: [Row]
    let save: ([Row]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Course Credits").font(.title2.weight(.semibold))
            Text("Use the school’s credits. You can exclude courses such as pass/fail classes.")
                .foregroundStyle(.secondary)
            List {
                ForEach($courses) { $course in
                    HStack(spacing: 10) {
                        Text(course.subject).frame(maxWidth: .infinity, alignment: .leading)
                        TextField("Credits", text: $course.rule.credits).frame(width: 95)
                        TextField("GPA Bonus", text: $course.rule.bonus).frame(width: 95)
                        Toggle("Exclude from GPA", isOn: Binding(
                            get: { course.rule.excludedFromGPA == true },
                            set: { course.rule.excludedFromGPA = $0 }
                        ))
                    }.textFieldStyle(.roundedBorder)
                }
            }
            .border(.quaternary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(courses); dismiss() }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(20).frame(width: 630, height: 420)
    }

    private var valid: Bool {
        courses.allSatisfy {
            ($0.rule.credits.isEmpty || (GradePoints.number($0.rule.credits) ?? 0) > 0) &&
            ($0.rule.bonus.isEmpty || (GradePoints.number($0.rule.bonus) ?? 11) <= 10)
        }
    }
}

struct TranscriptGPAEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var initial: ReportedGPA
    let save: (ReportedGPA) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Record Transcript GPA…").font(.title2.weight(.semibold))
            Text("Enter the GPA printed on your school transcript. Leave unavailable values empty.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Transcript Semester GPA", text: $initial.semester)
                TextField("Transcript Cumulative GPA", text: $initial.cumulative)
                Picker("GPA Type", selection: $initial.basis) {
                    Text("Not specified").tag("")
                    Text("Weighted GPA").tag("Weighted GPA")
                    Text("Unweighted GPA").tag("Unweighted GPA")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(initial); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(![initial.semester, initial.cumulative].allSatisfy {
                        $0.isEmpty || (GradePoints.number($0) ?? 21) <= 20
                    })
            }
        }.padding(20).frame(width: 470)
    }
}

struct CourseTaskImpactEditor: View {
    let courseID: String
    let school: SchoolDynamicCourse?
    let grades: CourseGrades?
    @Binding var items: [PlannedGrade]
    @State private var assumedCounts: [String: String] = [:]

    let editable: Bool
    let target: Double?
    let fallbackScale: GPAScale?
    let semesterImpact: (Double) -> String?

    private var categories: [String] { grades?.scenarioCategories ?? [] }
    private var missingCounts: [String] {
        Set(items.map(\.category)).sorted().filter { grades?.needsItemCount(in: $0) == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Task impact on this course", systemImage: "arrow.triangle.branch").font(.headline)
            if let grades, !categories.isEmpty {
                if let parts = school?.categories, !parts.isEmpty {
                    DisclosureGroup("Published category scores") {
                        ForEach(parts.indices, id: \.self) { index in
                            let part = parts[index]
                            LabeledContent(part.name, value: part.score.map(percent) ?? "—")
                        }
                    }
                }
                if editable {
                    ForEach($items) { $item in
                        HStack(alignment: .bottom) {
                            Picker("School category", selection: $item.category) {
                                ForEach(categories, id: \.self) { Text($0.isEmpty ? String(localized: "All items") : $0).tag($0) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            field("Expected Score", text: $item.expected)
                            field("Max Points Each", text: $item.maximum)
                            field("Count", text: Binding(get: { item.repetitions ?? "1" }, set: { item.repetitions = $0 }))
                            Button {
                                let id = item.id
                                items.removeAll { $0.id == id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.borderless).accessibilityLabel("Remove Item")
                        }
                    }
                    Button("Add task to forecast") {
                        if let category = items.last?.category, categories.contains(category) {
                            items.append(PlannedGrade(course: courseID, category: category, expected: ""))
                        } else if let category = categories.first(where: { !grades.needsItemCount(in: $0) }) ?? categories.first {
                            items.append(PlannedGrade(course: courseID, category: category, expected: ""))
                        }
                    }.disabled(items.count >= 200)
                }
                if items.isEmpty {
                    Text("Add one or more tasks to see how their scores affect this course.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    results(grades)
                }
            } else {
                Text("Course forecasting requires grades and category weights that reproduce the school total.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func results(_ grades: CourseGrades) -> some View {
        if !missingCounts.isEmpty {
            Text("SchoolPal provides these category grades without item counts. Enter known counts or use assumptions for this forecast.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(missingCounts, id: \.self) { category in
                HStack {
                    Text(verbatim: category)
                    Spacer()
                    TextField("Existing item count", text: Binding(
                        get: { assumedCounts[category, default: ""] },
                        set: { assumedCounts[category] = $0 }
                    )).frame(maxWidth: 135)
                }
            }
        }
        let counts = assumedCounts.compactMapValues { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let result = grades.impact(of: items, assumedCounts: counts) {
            Divider()
            Text("Current → projected").font(.caption).foregroundStyle(.secondary)
            ForEach(result.categories) { row in
                LabeledContent {
                    Text(change(from: row.before, to: row.after)).monospacedDigit()
                } label: {
                    Text("\(row.id.isEmpty ? String(localized: "All items") : row.id) · weight \(percent(row.weight))")
                }
            }
            Divider()
            let total = roundedCoursePercent(result.coursePercent)
            LabeledContent("Course grade", value: change(from: school?.percent ?? grades.percent(), to: total))
                .fontWeight(.semibold)
            if let target, target <= 100 {
                let gap = total - target
                LabeledContent("Above / below course goal", value: String(format: "%+.2f pp", gap))
            }
            if let mapped = (school?.scale ?? fallbackScale)?.points(at: total) {
                let bonus = school?.scale == nil ? GradePoints.number(grades.rule.bonus) ?? 0 : 0
                let points = mapped + bonus
                let currentPoints = school?.points ?? grades.percent().flatMap { fallbackScale?.points(at: $0) }.map { $0 + bonus }
                LabeledContent("Course GPA points", value: "\(currentPoints.map(gpa) ?? "—") → \(gpa(points))")
                    .fontWeight(.semibold)
                if let change = semesterImpact(points) {
                    LabeledContent("Estimated semester GPA change", value: change)
                } else {
                    Text("Semester impact requires an included course and grade points for each included course. Credit weighting also requires all credits.").font(.caption)
                }
            } else {
                Text("The school GPA scale is unavailable for this course.").font(.caption).foregroundStyle(.secondary)
            }
            if grades.averagesItems { Text("Each task contributes its own percentage. Categories use SchoolPal weights. Existing item counts may be estimated.").font(.caption).foregroundStyle(.secondary) }
        } else {
            Text("Check each score, maximum, and count (1–200), including any required existing item counts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text).labelsHidden().monospacedDigit()
        }.frame(width: 110)
    }

    private func change(from before: Double?, to after: Double) -> String {
        "\(before.map(percent) ?? "—") → \(percent(after))"
    }

    private func roundedCoursePercent(_ value: Double) -> Double { (value * 100).rounded() / 100 }
    private func percent(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) + "%" }
    private func gpa(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
}

struct GradeScenarioEditor: View {
    struct Course: Identifiable {
        let id, name: String
        let grades: CourseGrades
        let school: SchoolDynamicCourse?

        var categories: [String] {
            guard grades.canProject else { return [] }
            if !grades.rule.weighted { return [CourseGrades.totalGroup] }
            return (grades.weights ?? [:]).filter { $0.value > 0 && !grades.needsItemCount(in: $0.key) }.keys.sorted()
        }
    }

    @Environment(\.dismiss) private var dismiss
    let courses: [Course]
    let scale: GPAScale?
    @State var initial: [PlannedGrade]
    let target: Double?
    let save: ([PlannedGrade]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Multi-Course Scenario").font(.title2.weight(.semibold))
            Text("Enter the remaining graded items you want to simulate.")
                .foregroundStyle(.secondary)
            List {
                ForEach($initial) { $item in
                    HStack(spacing: 8) {
                        Picker("Subjects", selection: $item.course) {
                            ForEach(eligible.filter { !$0.categories.isEmpty }) { Text($0.name).tag($0.id) }
                        }.labelsHidden()
                            .onChange(of: item.course) { _, new in item.category = categoryList(new).first ?? "" }
                        if categoryList(item.course) != [CourseGrades.totalGroup] {
                            Picker("Category", selection: $item.category) {
                                ForEach(categoryList(item.course), id: \.self) { Text(LocalizedStringKey($0)).tag($0) }
                            }.labelsHidden()
                        }
                        TextField("Max Points Each", text: $item.maximum).frame(width: 94)
                        TextField("Expected Points", text: $item.expected).frame(width: 90)
                        Button(role: .destructive) {
                            let id = item.id
                            initial.removeAll { $0.id == id }
                        } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel("Remove Item")
                    }.textFieldStyle(.roundedBorder)
                }
            }
            .border(.quaternary)
            Button("Add Remaining Item") {
                if let course = eligible.first(where: { !$0.categories.isEmpty }) {
                    initial.append(PlannedGrade(course: course.id, category: course.categories.first ?? ""))
                }
            }.disabled(!eligible.contains { !$0.categories.isEmpty } || initial.count >= 200)
            results
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Scenario") { save(initial); dismiss() }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(20).frame(width: 680, height: 475)
    }

    @ViewBuilder private var results: some View {
        if valid, !initial.isEmpty {
            let forecast = projection()
            let best = projection(fraction: 1)
            if let predicted = forecast.average, let upper = best.average {
                Text("Projected GPA \(number(predicted)) · With full marks \(number(upper))")
                    .fontWeight(.semibold)
                Text("\(forecast.courses) of \(eligible.count) courses included")
                    .font(.caption).foregroundStyle(.secondary)
                if let target, forecast.courses == eligible.count, best.courses == eligible.count {
                    if let required = neededShare(target: target) {
                        Text("To reach \(number(target)), score at least \(percent(required)) of each planned maximum.")
                            .font(.callout)
                    } else {
                        Text("The planned items cannot reach the GPA target, even with full marks.")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
            } else {
                Text("Complete the course scores, credits and rules to estimate GPA.").foregroundStyle(.secondary)
            }
        } else {
            Text("Add valid remaining items and a GPA scale to see a projection.")
                .foregroundStyle(.secondary)
        }
    }

    private var eligible: [Course] {
        courses.filter { $0.grades.rule.excludedFromGPA != true && $0.school?.includedInGpa != false }
    }
    private func categoryList(_ course: String) -> [String] { eligible.first { $0.id == course }?.categories ?? [] }

    private var valid: Bool {
        initial.allSatisfy { item in
            guard let maximum = GradePoints.number(item.maximum), maximum > 0,
                  let expected = GradePoints.number(item.expected), expected <= maximum else { return false }
            return categoryList(item.course).contains(item.category)
        }
    }

    private func projection(fraction: Double? = nil) -> GPACreditTotal {
        let items = Dictionary(grouping: initial, by: \.course)
        var result = GPACreditTotal()
        for course in eligible {
            var future: [String: GradePoints] = [:]
            guard let credits = GradePoints.number(course.grades.rule.credits), credits > 0 else { continue }
            if items[course.id] == nil, let points = course.school?.points {
                result.add(points: points, credits: credits)
                continue
            }
            for item in items[course.id, default: []] {
                guard let maximum = GradePoints.number(item.maximum), let expected = GradePoints.number(item.expected) else { continue }
                let earned = fraction.map { $0 * maximum } ?? expected
                future[item.category, default: .empty].add(
                    course.grades.itemTotals(GradePoints(earned: earned, possible: maximum))
                )
            }
            let schoolScale = course.school?.scale
            if let percent = course.grades.percent(additions: future),
               let points = (schoolScale ?? scale)?.points(at: percent) {
                let bonus = schoolScale == nil ? (GradePoints.number(course.grades.rule.bonus) ?? 0) : 0
                result.add(points: points + bonus, credits: credits)
            }
        }
        return result
    }

    private func neededShare(target: Double) -> Double? {
        guard let best = projection(fraction: 1).average, best >= target - 1e-9 else { return nil }
        if let floor = projection(fraction: 0).average, floor >= target - 1e-9 { return 0 }
        var lower = 0.0, upper = 1.0
        for _ in 0..<36 {
            let midpoint = (lower + upper) / 2
            if let result = projection(fraction: midpoint).average, result >= target - 1e-9 { upper = midpoint }
            else { lower = midpoint }
        }
        return upper
    }

    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }

    private func percent(_ fraction: Double) -> String {
        (ceil(fraction * 10_000 - 1e-7) / 100).formatted(.number.precision(.fractionLength(0...2))) + "%"
    }
}
