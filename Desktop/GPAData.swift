import Foundation

struct SchoolGrade: Codable, Identifiable, Equatable {
    let id, course, subject, title, category: String
    let day, score, total, level: String?
    let exempt: Bool

    var group: String { category.isEmpty ? "Uncategorized" : category }
    var points: GradePoints? { GradePoints(earned: score, possible: total) }
}

struct PublishedCourseScore: Codable {
    let course, subject, value: String
}

struct SemesterGradeBook: Decodable {
    let semesterId, startDay, endDay, checkedAt: String?
    let lastAttemptAt, syncIssue: String?
    let sourcePublishedCount: Int?
    var schoolGpa: String?
    var schoolScores: [PublishedCourseScore]?
    var records: [SchoolGrade]
    let dynamic: SchoolDynamicGrades?
    let dynamicIssue: String?
}

struct SchoolDynamicGrades: Decodable {
    let checkedAt: String
    let gpa: Double?
    let archived: Bool
    let courses: [SchoolDynamicCourse]
    let fromDump: Bool?
}

struct SchoolDynamicCourse: Decodable, Identifiable {
    let id, name, englishName, className: String
    let percent, points: Double?
    let level: String?
    let ranges: [SchoolGPARange]
    let categories: [SchoolGradeCategory]?
    let includedInGpa: Bool?

    var aliases: Set<String> { Set([name, englishName].filter { !$0.isEmpty }) }

    var scale: GPAScale? { GPAScale(ranges: ranges) }
}

struct SchoolGPARange: Decodable {
    let minimum, maximum: Double
    let includesMinimum, includesMaximum: Bool
    let level: String
    let points: Double?
}

struct SchoolGradeCategory: Decodable {
    let name, englishName: String
    let weight, score: Double?
    let level: String?
    let children: [SchoolGradeCategory]
    let estimatedCount: Int?
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
    var ignoreUngradedCategories: Bool?
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
    private(set) var averagesItems = false
    private(set) var canProject = true
    private var fixedPercentages: [String: Double] = [:]

    init(records: [SchoolGrade], rule: GradingRule, groups: [String: String] = [:], excluded: Set<String> = [],
         canProject: Bool = true) {
        self.rule = rule
        self.canProject = canProject
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

    init?(school: SchoolDynamicCourse, rule: GradingRule) {
        guard let parts = school.categories, let published = school.percent, !parts.isEmpty,
              Set(parts.map(\.name)).count == parts.count,
              parts.allSatisfy({ !$0.name.isEmpty && $0.children.isEmpty && $0.weight != nil }) else { return nil }
        var rule = rule
        rule.weighted = true
        rule.ignoreUngradedCategories = true
        rule.weights = Dictionary(uniqueKeysWithValues: parts.compactMap { part in
            part.weight.map { (part.name, String($0)) }
        })
        self.rule = rule
        averagesItems = true
        for part in parts {
            guard let score = part.score else { continue }
            if let count = part.estimatedCount, count > 0 {
                totals[part.name] = GradePoints(earned: score / 100 * Double(count), possible: Double(count))
                scored += count
            } else {
                fixedPercentages[part.name] = score
            }
        }
        guard let calculated = percent(), abs(calculated - published) <= 0.011 else { return nil }
    }

    func needsItemCount(in group: String) -> Bool { fixedPercentages[group] != nil }

    var weights: [String: Double]? {
        guard canProject else { return nil }
        guard rule.weighted else { return [Self.totalGroup: 1] }
        let parsed = rule.weights.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMapValues { GradePoints.number($0).map { $0 / 100 } }
        let configured = rule.weights.values.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        guard parsed.count == configured, abs(parsed.values.reduce(0, +) - 1) < 0.000001,
              Set(totals.keys).isSubset(of: Set(parsed.keys)) else { return nil }
        return parsed
    }

    func itemTotals(_ points: GradePoints, count: Int = 1) -> GradePoints {
        guard averagesItems, let percent = points.percent else { return points }
        let count = Double(count)
        return GradePoints(earned: percent / 100 * count, possible: count)
    }

    func percent(additional: GradePoints = .empty, to group: String = totalGroup, count: Int = 1) -> Double? {
        percent(additions: additional.possible > 0 ? [group: itemTotals(additional, count: count)] : [:])
    }

    func percent(additions: [String: GradePoints]) -> Double? {
        guard let weights, Set(additions.keys).isSubset(of: Set(weights.keys)),
              additions.keys.allSatisfy({ !needsItemCount(in: $0) }) else { return nil }
        var points = totals
        for (name, additional) in additions { points[name, default: .empty].add(additional) }
        guard let result = weightedResult(points, weights: weights), result.weight > 0 else { return nil }
        return result.sum / result.weight
    }

    private func weightedResult(_ points: [String: GradePoints], weights: [String: Double])
        -> (sum: Double, weight: Double)? {
        var sum = 0.0
        var activeWeight = 0.0
        for (name, weight) in weights where weight > 0 {
            guard let percent = points[name]?.percent ?? fixedPercentages[name] else {
                if rule.ignoreUngradedCategories == true { continue }
                return nil
            }
            sum += weight * percent
            activeWeight += weight
        }
        return (sum, activeWeight)
    }

    private func categoryTarget(_ target: Double, in group: String) -> Double? {
        guard var weights, let weight = weights.removeValue(forKey: group), weight > 0,
              let other = weightedResult(totals, weights: weights) else { return nil }
        return (target * (weight + other.weight) - other.sum) / (weight * 100)
    }

    func neededCategoryPercent(target: Double, in group: String) -> Double? {
        categoryTarget(target, in: group).map { max(0, $0 * 100) }
    }

    func requiredScore(target: Double, addedMaximum: Double, in group: String, count: Int = 1) -> Double? {
        guard addedMaximum > 0, count > 0, !needsItemCount(in: group),
              let fraction = categoryTarget(target, in: group) else { return nil }
        let current = totals[group, default: .empty]
        if averagesItems {
            let units = Double(count)
            return max(0, fraction * (current.possible + units) - current.earned) * addedMaximum / units
        }
        return max(0, fraction * (current.possible + addedMaximum) - current.earned)
    }

    func minimumCount(target: Double, maximum: Double, expected: Double, in group: String) -> Int? {
        guard maximum > 0, (0...maximum).contains(expected), !needsItemCount(in: group),
              let fraction = categoryTarget(target, in: group) else { return nil }
        let current = totals[group, default: .empty]
        let gap = fraction * current.possible - current.earned
        if let currentPercent = percent(), currentPercent + 1e-9 >= target { return 0 }
        let next = itemTotals(GradePoints(earned: expected, possible: maximum))
        let gain = next.earned - fraction * next.possible
        if current.possible == 0 { return gain >= -1e-9 ? 1 : nil }
        guard gain > 1e-9 else { return nil }
        let count = ceil(gap / gain - 1e-9)
        return count <= Double(Int32.max) ? Int(max(1, count)) : nil
    }
}

struct GPAScale {
    struct Step { let minimum, points: Double }
    let steps: [Step]
    private let ranges: [SchoolGPARange]

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
        ranges = []
    }

    init?(ranges: [SchoolGPARange]) {
        let usable = ranges.filter { $0.points != nil }
        guard !usable.isEmpty else { return nil }
        self.ranges = usable
        steps = usable.compactMap { range in
            guard let points = range.points else { return nil }
            var minimum = ceil(range.minimum * 10 - 1e-9)
            if !range.includesMinimum && abs(minimum / 10 - range.minimum) < 1e-9 { minimum += 1 }
            let value = minimum / 10
            guard value < range.maximum || (value == range.maximum && range.includesMaximum) else { return nil }
            return Step(minimum: value, points: points)
        }.sorted { $0.minimum < $1.minimum }
    }

    func points(at percent: Double) -> Double? {
        if ranges.isEmpty { return steps.last { $0.minimum <= percent + 1e-9 }?.points }
        let scaled = percent * 10
        let floorValue = floor(scaled)
        let half = floorValue + 0.5
        let aboveHalf = scaled > half || (scaled == half && (-scaled).addingProduct(percent, 10) >= 0)
        let rounded = (floorValue + (aboveHalf ? 1 : 0)) / 10
        return ranges.last {
            (rounded > $0.minimum || (rounded == $0.minimum && $0.includesMinimum)) &&
                (rounded < $0.maximum || (rounded == $0.maximum && $0.includesMaximum))
        }?.points
    }

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
