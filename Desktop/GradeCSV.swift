import CryptoKit
import Foundation

struct ImportedGrade: Codable, Equatable {
    let sourceID: String?
    let grade: SchoolGrade
}

struct GradeImportStorage: Codable {
    var terms: [String: [ImportedGrade]] = [:]

    static func url(in root: URL) -> URL { root.appendingPathComponent("data/grade-imports.json") }

    static func read(in root: URL) -> Self {
        guard let data = try? Data(contentsOf: url(in: root)) else { return Self() }
        return (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }

    func save(in root: URL) throws {
        let url = Self.url(in: root)
        let files = FileManager.default
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        if files.fileExists(atPath: url.path) {
            _ = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

enum GradeCSV {
    struct Row: Identifiable {
        let id: Int
        let entry: ImportedGrade
    }

    enum Disposition: String {
        case add = "Add Score", update = "Update Imported Score", supplement = "Fill Missing Score"
        case same = "Already Present", conflict = "Conflicting or Ambiguous Score", outside = "Outside This Semester"

        var imports: Bool { self == .add || self == .update || self == .supplement }
    }

    struct Preview: Identifiable {
        let id: Int
        let grade: SchoolGrade
        let disposition: Disposition
    }

    struct Plan {
        let preview: [Preview]
        let records: [ImportedGrade]
    }

    enum ImportError: LocalizedError {
        case format, columns, invalidRow(Int), empty

        var errorDescription: String? {
            switch self {
            case .format: "Select a UTF-8 CSV file under 5 MB with valid quoting."
            case .columns: "The CSV needs Course, Title and Score or Level columns."
            case .invalidRow(let row): "Invalid grade or date in CSV record \(row)."
            case .empty: "The CSV contains no grade rows."
            }
        }
    }

    private static let fields: [String: String] = [
        "course": "course", "课程": "course", "科目": "course", "subject": "course",
        "category": "category", "类别": "category", "类型": "category",
        "title": "title", "项目": "title", "项目名称": "title",
        "score": "score", "得分": "score", "分数": "score",
        "total": "total", "maximum": "total", "满分": "total",
        "date": "date", "日期": "date", "id": "id", "项目id": "id", "任务id": "id",
        "level": "level", "等级": "level"
    ]

    static func parse(_ data: Data) throws -> [Row] {
        guard data.count <= 5_000_000, var text = String(data: data, encoding: .utf8) else { throw ImportError.format }
        if text.first == "\u{feff}" { text.removeFirst() }
        let lines = try readRows(text)
        guard let header = lines.first else { throw ImportError.empty }
        var columns: [String: Int] = [:]
        for (index, item) in header.enumerated() {
            if let field = fields[key(item)], columns.updateValue(index, forKey: field) != nil { throw ImportError.columns }
        }
        guard columns["course"] != nil, columns["title"] != nil,
              columns["score"] != nil || columns["level"] != nil else { throw ImportError.columns }
        return try lines.dropFirst().enumerated().map { offset, line in
            let row = offset + 2
            func value(_ name: String) -> String? {
                guard let position = columns[name], line.indices.contains(position) else { return nil }
                let result = line[position].trimmingCharacters(in: .whitespacesAndNewlines)
                return result.isEmpty ? nil : result
            }
            guard let course = value("course"), let title = value("title") else { throw ImportError.invalidRow(row) }
            let score = value("score"), total = value("total"), level = value("level"), date = value("date")
            guard score != nil || level != nil,
                  score == nil || GradePoints.number(score) != nil,
                  total == nil || (GradePoints.number(total) ?? 0) > 0,
                  date == nil || date.flatMap(Beijing.parseDay).map(Beijing.day) == date else {
                throw ImportError.invalidRow(row)
            }
            let category = value("category") ?? ""
            let source = value("id")
            let grade = makeGrade(course: course, subject: course, title: title, category: category,
                                  date: date, score: score, total: total, level: level, sourceID: source)
            return Row(id: row, entry: ImportedGrade(sourceID: source, grade: grade))
        }
    }

    private static func readRows(_ text: String) throws -> [[String]] {
        var result: [[String]] = [], row: [String] = [], cell = ""
        var quoted = false, closed = false
        func endCell() { row.append(cell); cell = ""; closed = false }
        func endRow() {
            endCell()
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { result.append(row) }
            row = []
        }
        for character in text {
            if quoted {
                if character == "\"" { quoted = false; closed = true }
                else { cell.append(character) }
            } else if closed && character == "\"" {
                quoted = true; closed = false; cell.append(character)
            } else if character == "," {
                endCell()
            } else if character.isNewline {
                endRow()
            } else if character == "\"" && cell.isEmpty {
                quoted = true
            } else if closed || character == "\"" {
                throw ImportError.format
            } else {
                cell.append(character)
            }
        }
        guard !quoted else { throw ImportError.format }
        endRow()
        guard result.count > 1 else { throw ImportError.empty }
        return result
    }

    static func plan(_ rows: [Row], school: [SchoolGrade], stored: [ImportedGrade],
                     aliases: [String: Set<String>], start: String?, end: String?) -> Plan {
        var records = stored
        var preview: [Preview] = []
        let lookup = Dictionary(grouping: aliases.keys, by: key)
        let duplicates = Dictionary(grouping: rows) { row in
            row.entry.sourceID.map { "school:" + $0 } ?? row.entry.grade.id
        }
        let conflictingRows = Set(duplicates.values.flatMap { matches -> [Int] in
            guard let first = matches.first?.entry.grade,
                  matches.dropFirst().contains(where: { !sameValues(first, $0.entry.grade) || key(first.course) != key($0.entry.grade.course) }) else { return [] }
            return matches.map(\.id)
        })
        for row in rows {
            let original = row.entry.grade
            let matches = lookup[key(original.course), default: []].reduce(into: Set<String>()) {
                $0.formUnion(aliases[$1] ?? [])
            }
            let course = matches.count == 1 ? (matches.first ?? original.course) : original.course
            let input = makeGrade(course: course, subject: original.subject, title: original.title, category: original.category,
                                  date: original.day, score: original.score, total: original.total, level: original.level,
                                  sourceID: row.entry.sourceID)
            let entry = ImportedGrade(sourceID: row.entry.sourceID, grade: input)
            let source = possibleMatches(for: entry, in: school)
            let local = records.indices.filter { old in
                if let a = entry.sourceID, let b = records[old].sourceID { return a == b }
                return sameItem(input, records[old].grade)
            }
            let disposition: Disposition
            if let day = input.day, (start.map { day < $0 } == true || end.map { day > $0 } == true) {
                disposition = .outside
            } else if conflictingRows.contains(row.id) || matches.count > 1 || source.count > 1 || local.count > 1 {
                disposition = .conflict
            } else if let published = source.first {
                if key(published.course) != key(course) || !compatible(published, input) {
                    disposition = .conflict
                } else if supplement(published, from: input) == published {
                    disposition = .same
                } else {
                    let merged = ImportedGrade(sourceID: published.id, grade: input)
                    if let old = local.first { records[old] = merged }
                    else { records.append(merged) }
                    disposition = .supplement
                }
            } else if let old = local.first {
                if sameValues(records[old].grade, input) { disposition = .same }
                else {
                    let before = records[old]
                    let stable = SchoolGrade(id: before.grade.id, course: input.course, subject: input.subject,
                                             title: input.title, category: input.category, day: input.day, score: input.score,
                                             total: input.total, level: input.level, exempt: false)
                    records[old] = ImportedGrade(sourceID: entry.sourceID ?? before.sourceID, grade: stable)
                    disposition = .update
                }
            } else {
                records.append(entry)
                disposition = .add
            }
            preview.append(Preview(id: row.id, grade: input, disposition: disposition))
        }
        return Plan(preview: preview, records: records)
    }

    static func merged(school: [SchoolGrade], imported: [ImportedGrade]) -> [SchoolGrade] {
        var result = school
        for item in imported {
            let matching = Set(possibleMatches(for: item, in: school).map(\.id))
            if matching.isEmpty {
                if !result.contains(where: { $0.id == item.grade.id }) { result.append(item.grade) }
            } else if matching.count == 1, let position = result.firstIndex(where: { matching.contains($0.id) }),
                      key(result[position].course) == key(item.grade.course), compatible(result[position], item.grade) {
                result[position] = supplement(result[position], from: item.grade)
            }
        }
        return result.sorted {
            if $0.day == $1.day { return $0.id < $1.id }
            return ($0.day ?? "") > ($1.day ?? "")
        }
    }

    private static func makeGrade(course: String, subject: String, title: String, category: String, date: String?,
                                  score: String?, total: String?, level: String?, sourceID: String?) -> SchoolGrade {
        let parts = [sourceID ?? "", key(course), key(title), key(category), date ?? ""]
        let id = "csv:" + SHA256.hash(data: Data(parts.joined(separator: "\u{1f}").utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
        return SchoolGrade(id: id, course: course, subject: subject, title: title, category: category, day: date,
                           score: score, total: total, level: level, exempt: false)
    }

    private static func possibleMatches(for entry: ImportedGrade, in grades: [SchoolGrade]) -> [SchoolGrade] {
        if let source = entry.sourceID, let exact = grades.first(where: { $0.id == source }) { return [exact] }
        return grades.filter { sameItem($0, entry.grade) }
    }

    private static func sameItem(_ a: SchoolGrade, _ b: SchoolGrade) -> Bool {
        key(a.course) == key(b.course) && key(a.title) == key(b.title)
            && (a.category.isEmpty || b.category.isEmpty || key(a.category) == key(b.category))
            && (a.day == nil || b.day == nil || a.day == b.day)
    }

    private static func sameValues(_ a: SchoolGrade, _ b: SchoolGrade) -> Bool {
        GradePoints.number(a.score) == GradePoints.number(b.score) &&
            GradePoints.number(a.total) == GradePoints.number(b.total) && a.level == b.level &&
            a.day == b.day && a.category == b.category
    }

    private static func compatible(_ a: SchoolGrade, _ b: SchoolGrade) -> Bool {
        (a.score == nil || b.score == nil || GradePoints.number(a.score) == GradePoints.number(b.score)) &&
            (a.total == nil || b.total == nil || GradePoints.number(a.total) == GradePoints.number(b.total)) &&
            (a.level == nil || b.level == nil || a.level.map(key) == b.level.map(key))
    }

    private static func supplement(_ official: SchoolGrade, from imported: SchoolGrade) -> SchoolGrade {
        SchoolGrade(id: official.id, course: official.course, subject: official.subject, title: official.title,
                    category: official.category.isEmpty ? imported.category : official.category,
                    day: official.day ?? imported.day, score: official.score ?? imported.score, total: official.total ?? imported.total,
                    level: official.level ?? (official.score == nil && imported.score == nil ? imported.level : nil),
                    exempt: official.exempt)
    }

    private static func key(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
