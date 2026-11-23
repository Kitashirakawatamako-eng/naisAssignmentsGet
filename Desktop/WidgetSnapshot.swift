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
    var transcript: String?
    var estimate: Double?
    var included: Int
    var eligible: Int
    var maximum: Int?
    var exampleScale: Bool
}

struct WidgetSlotAppearance: Codable {
    let color: String
    let pins: [WidgetAssignment]
    let count: Int
}
