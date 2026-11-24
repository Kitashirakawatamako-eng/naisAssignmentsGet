import Foundation

struct WidgetAssignment: Codable, Identifiable {
    let id, title, subject: String
    let due: Date?
    let pending: Bool

    var url: URL {
        var components = URLComponents(url: WidgetSnapshot.assignmentURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url ?? WidgetSnapshot.assignmentURL
    }
}

struct WidgetSnapshot: Codable {
    let theme, language: String
    let timetable: Timetable?
    let pins: [WidgetAssignment]
    let pinCount: Int

    var deadlines: [WidgetAssignment]?
    var gpa: WidgetGPA?
    var preferredContent: String?
    var secondContent: String?
    var slots: [String: WidgetSlotAppearance]?


    static let gradesURL = URL(string: "spassignments://grades")!
    static let timetableURL = URL(string: "spassignments://timetable")!
    static let assignmentURL = URL(string: "spassignments://assignments")!

    static func file(in root: URL) -> URL { root.appendingPathComponent("data/widgets.json") }

    /// Widgets read the active account folder so one account never shows another's data.
    static func activeRoot() -> URL {
        guard let home = FileManager.default.homeDirectoryForCurrentUser as URL? else { return URL(fileURLWithPath: NSHomeDirectory()) }
        let base = home.appendingPathComponent("Library/Application Support/作业速览", isDirectory: true)
        guard let data = try? Data(contentsOf: base.appendingPathComponent("accounts.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["active"] as? String, !id.isEmpty else { return base }
        return base.appendingPathComponent("Users", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(from data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: data)
    }
}

struct WidgetGPA: Codable {
    var schoolValue: String?
}

struct WidgetSlotAppearance: Codable {
    let color: String
    let pins: [WidgetAssignment]
    let count: Int
}
