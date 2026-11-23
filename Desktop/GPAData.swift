import Foundation

struct SchoolGrade: Codable, Identifiable, Equatable {
    let id, course, subject, title, category: String
    let day, score, total, level: String?
    let exempt: Bool

    var group: String { category.isEmpty ? "Uncategorized" : category }
    var points: GradePoints? { GradePoints(earned: score, possible: total) }
}

struct SemesterGradeBook: Decodable {
    let semesterId, startDay, endDay, checkedAt: String?
    let lastAttemptAt, syncIssue: String?
    let sourcePublishedCount: Int?
    var records: [SchoolGrade]
}

struct GradePoints: Codable, Equatable {
    var earned: Double
    var possible: Double
    static let empty = Self(earned: 0, possible: 0)

    init(earned: Double, possible: Double) {
        self.earned = earned
        self.possible = possible
    }

    init?(earned: String?, possible: String?) {
        guard let earned = Self.number(earned), let possible = Self.number(possible), possible > 0 else { return nil }
        self.init(earned: earned, possible: possible)
    }

    var percent: Double? { possible > 0 ? earned / possible * 100 : nil }

    mutating func add(_ other: Self) {
        earned += other.earned
        possible += other.possible
    }

    static func number(_ text: String?) -> Double? {
        guard let text, let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, (0...1_000_000).contains(value) else { return nil }
        return value
    }
}

struct GradingRule: Codable, Equatable {
    var credits = ""
    var bonus = ""
    var weighted = false
    var weights: [String: String] = [:]
    var pastPoints: [String: GradePoints] = [:]
    var excludedFromGPA: Bool?
}

struct ReportedGPA: Codable, Equatable {
    var semester = ""
    var cumulative = ""
    var basis = ""
}

struct PlannedGrade: Codable, Equatable, Identifiable {
    var id = UUID()
    var course: String
    var category = CourseGrades.totalGroup
    var maximum = "100"
    var expected = "95"
}

struct GradePreferences: Codable, Equatable {
    var rules: [String: GradingRule] = [:]
    var groups: [String: String] = [:]
    var omitted: Set<String> = []
    var scale = ""
    var reported: [String: ReportedGPA]?
    var weightedEstimate: Bool?
    var sectionPlans: [String: [GradeSectionInput]]?
    var priorTerms: [String: PriorGPA]?
    var scenarios: [String: [PlannedGrade]]?
}

struct CourseGrades {
    static let totalGroup = ""
    let rule: GradingRule
    private(set) var totals: [String: GradePoints] = [:]
    private(set) var scored = 0
    private(set) var unscored = 0
    private(set) var omitted = 0

    init(records: [SchoolGrade], rule: GradingRule, groups: [String: String] = [:], excluded: Set<String> = []) {
        self.rule = rule
        for grade in records {
            if grade.exempt || excluded.contains(grade.id) { omitted += 1; continue }
            guard let points = grade.points else { unscored += 1; continue }
            let name = rule.weighted ? (groups[grade.id] ?? grade.group) : Self.totalGroup
            totals[name, default: .empty].add(points)
            scored += 1
        }
        for (name, points) in rule.pastPoints where points.possible > 0 && rule.weighted == !name.isEmpty {
            totals[name, default: .empty].add(points)
        }
    }

    var weights: [String: Double]? {
        guard rule.weighted else { return [Self.totalGroup: 1] }
        let parsed = rule.weights.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMapValues { GradePoints.number($0).map { $0 / 100 } }
        let configured = rule.weights.values.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        guard parsed.count == configured, abs(parsed.values.reduce(0, +) - 1) < 0.000001,
              Set(totals.keys).isSubset(of: Set(parsed.keys)) else { return nil }
        return parsed
    }

    func percent(additional: GradePoints = .empty, to group: String = totalGroup) -> Double? {
        percent(additions: additional.possible > 0 ? [group: additional] : [:])
    }

    func percent(additions: [String: GradePoints]) -> Double? {
        guard let weights, Set(additions.keys).isSubset(of: Set(weights.keys)) else { return nil }
        var points = totals
        for (name, additional) in additions { points[name, default: .empty].add(additional) }
        var result = 0.0
        for (name, weight) in weights where weight > 0 {
            guard let percent = points[name]?.percent else { return nil }
            result += weight * percent
        }
        return result
    }

    private func categoryTarget(_ target: Double, in group: String) -> Double? {
        guard let weights, let weight = weights[group], weight > 0 else { return nil }
        var other = 0.0
        for (name, fraction) in weights where name != group && fraction > 0 {
            guard let percent = totals[name]?.percent else { return nil }
            other += fraction * percent
        }
        return (target - other) / (weight * 100)
    }

    func requiredScore(target: Double, addedMaximum: Double, in group: String) -> Double? {
        guard addedMaximum > 0, let fraction = categoryTarget(target, in: group) else { return nil }
        let current = totals[group, default: .empty]
        return max(0, fraction * (current.possible + addedMaximum) - current.earned)
    }

    func minimumCount(target: Double, maximum: Double, expected: Double, in group: String) -> Int? {
        guard maximum > 0, (0...maximum).contains(expected), let fraction = categoryTarget(target, in: group) else { return nil }
        let current = totals[group, default: .empty]
        let gap = fraction * current.possible - current.earned
        if current.possible > 0 && gap <= 1e-9 { return 0 }
        let gain = expected - fraction * maximum
        if current.possible == 0 { return gain >= -1e-9 ? 1 : nil }
        guard gain > 1e-9 else { return nil }
        let count = ceil(gap / gain - 1e-9)
        return count <= Double(Int32.max) ? Int(max(1, count)) : nil
    }
}

struct GPAScale {
    struct Step { let minimum, points: Double }
    let steps: [Step]

    init?(_ text: String) {
        var steps: [Step] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2, let minimum = GradePoints.number(String(parts[0])), minimum <= 100,
                  let points = GradePoints.number(String(parts[1])), points <= 10 else { return nil }
            steps.append(Step(minimum: minimum, points: points))
        }
        steps.sort { $0.minimum < $1.minimum }
        guard steps.first?.minimum == 0,
              zip(steps, steps.dropFirst()).allSatisfy({ $0.minimum < $1.minimum && $0.points <= $1.points }) else { return nil }
        self.steps = steps
    }

    func points(at percent: Double) -> Double? { steps.last { $0.minimum <= percent + 1e-9 }?.points }
    func minimumPercent(for points: Double) -> Double? { steps.first { $0.points >= points - 1e-9 }?.minimum }

    static let example = "90=4.0\n80=3.0\n70=2.0\n60=1.0\n0=0.0"
}

struct GPACreditTotal {
    var weightedPoints = 0.0
    var credits = 0.0
    var courses = 0
    var average: Double? { credits > 0 ? weightedPoints / credits : nil }

    mutating func add(points: Double, credits: Double) {
        weightedPoints += points * credits
        self.credits += credits
        courses += 1
    }

    func pointsNeeded(to target: Double, courseCredits: Double) -> Double {
        ((credits + courseCredits) * target - weightedPoints) / courseCredits
    }
}

struct GradeSectionInput: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var weight = ""
    var score = ""

    static func projectedPercent(_ rows: [Self]) -> Double? {
        var totalWeight = 0.0
        var total = 0.0
        for row in rows {
            guard let weight = GradePoints.number(row.weight), weight > 0, weight <= 100,
                  let score = GradePoints.number(row.score), score <= 100 else { return nil }
            totalWeight += weight
            total += weight * score / 100
        }
        return abs(totalWeight - 100) < 0.000001 ? total : nil
    }
}

struct PriorGPA: Codable, Equatable {
    var average = ""
    var credits = ""
}

struct OverallEstimate {
    let total: GPACreditTotal
    let eligible: Int
    let maximum: Int
    let valid: Bool

    init(records: [SchoolGrade], courses: [String], term: String, preferences: GradePreferences, projected: Bool = false) {
        maximum = preferences.weightedEstimate == false ? 4 : 5
        let scale = GPAScale(GPAScale.example)!
        let groups = Dictionary(grouping: records, by: \.course)
        var aggregate = GPACreditTotal()
        var count = 0
        var validInputs = true
        for id in Set(courses).union(groups.keys).sorted() {
            let key = term + "\u{1f}" + id
            let rule = preferences.rules[key] ?? GradingRule()
            guard rule.excludedFromGPA != true else { continue }
            count += 1
            let percent: Double?
            if projected, let rows = preferences.sectionPlans?[key], !rows.isEmpty {
                percent = GradeSectionInput.projectedPercent(rows)
                if percent == nil { validInputs = false }
            } else {
                percent = CourseGrades(records: groups[id] ?? [], rule: rule, groups: preferences.groups,
                                       excluded: preferences.omitted).percent()
            }
            guard let percent, let points = scale.points(at: percent),
                  let credits = rule.credits.isEmpty ? 1.0 : GradePoints.number(rule.credits), credits > 0 else { continue }
            let bonus: Double
            if maximum == 5 && points > 0 {
                let names = [id, groups[id]?.first?.subject ?? ""]
                bonus = GradePoints.number(rule.bonus) ?? Self.defaultBonus(names)
            } else {
                bonus = 0
            }
            aggregate.add(points: min(Double(maximum), points + bonus), credits: credits)
        }
        total = aggregate
        eligible = count
        valid = validInputs
    }

    private static func defaultBonus(_ names: [String]) -> Double {
        for name in names {
            if name.range(of: #"(?i)(?:^|[^a-z])(?:ap(?=[^a-z]|$)|advanced placement\b)"#, options: .regularExpression) != nil { return 1 }
        }
        return names.contains { $0.localizedCaseInsensitiveContains("honors") || $0.contains("荣誉") } ? 0.5 : 0
    }

    func cumulative(prior: PriorGPA) -> Double? {
        guard valid, total.credits > 0, let previous = GradePoints.number(prior.average), previous <= Double(maximum),
              let credits = GradePoints.number(prior.credits), credits > 0 else { return nil }
        return (previous * credits + total.weightedPoints) / (credits + total.credits)
    }
}

enum CourseVisibility {
    static func includes(_ names: String...) -> Bool {
        let hidden = UserDefaults.standard.stringArray(forKey: "hiddenCourseNames") ?? []
        func normalized(_ value: String) -> String {
            value.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let aliases = Set(hidden.map(normalized))
        return names.allSatisfy { !aliases.contains(normalized($0)) }
    }
}
