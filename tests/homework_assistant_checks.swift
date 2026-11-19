import Foundation
@main struct AssistantChecks {
    static func main() throws {
        let content = try HomeworkAIRequest.content(title: "Math", subject: "Algebra", instructions: "Solve x + 2 = 5", files: [])
        assert(content.count == 1 && content[0]["type"] as? String == "text")
        let answer = try HomeworkAIRequest.output(["status":"completed", "steps":[["type":"thought","content":[["type":"text","text":"hidden"]]], ["type":"model_output","content":[["type":"text","text":"x = 3"]]]]])
        assert(answer == "x = 3")
        for response: [String: Any] in [["status":"incomplete"], ["status":"requires_continuation"], ["status":"failed"], ["status":"completed","steps":[["type":"model_output","content":[["type":"refusal"]]]]], ["status":"completed","steps":[]]] {
            do { _ = try HomeworkAIRequest.output(response); fatalError("Invalid response accepted") } catch is AssistantError {}
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let txt = dir.appendingPathComponent("questions.txt")
        try "Question 1: 2+2?".write(to: txt, atomically: true, encoding: .utf8)
        let items = try HomeworkAIRequest.content(title:"Test",subject:"Math",instructions:"See file",files:[txt])
        assert(items.count == 2 && (items[1]["text"] as? String)?.contains("2+2") == true)
        let docx = dir.appendingPathComponent("assignment questions.docx")
        let makeDocx = Process()
        makeDocx.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        makeDocx.arguments = ["-convert", "docx", "-output", docx.path, txt.path]
        try makeDocx.run()
        makeDocx.waitUntilExit()
        assert(makeDocx.terminationStatus == 0)
        let word = try HomeworkAIRequest.content(title: "T", subject: "S", instructions: "I", files: [docx])
        assert(word.count == 2 && word[1]["type"] as? String == "text")
        assert((word[1]["text"] as? String)?.contains("Question 1: 2+2?") == true)
        for (ext, mime, type) in [("pdf", "application/pdf", "document"), ("jpg", "image/jpeg", "image")] {
            let file = dir.appendingPathComponent("questions." + ext); try Data([1,2,3]).write(to: file)
            let parts = try HomeworkAIRequest.content(title:"T",subject:"S",instructions:"I",files:[file])
            let attachment = parts.last!
            assert(attachment["type"] as? String == type)
            assert(attachment["mime_type"] as? String == mime)
            assert(Data(base64Encoded: attachment["data"] as! String) == Data([1,2,3]))
        }
        for (name, data) in [("questions.zip", Data([1,2])), ("broken.docx", Data([1,2])), ("huge.pdf", Data(repeating:0, count:10_000_001))] {
            let bad = dir.appendingPathComponent(name); try data.write(to: bad)
            do { _ = try HomeworkAIRequest.content(title:"T",subject:"S",instructions:"I",files:[bad]); fatalError("Invalid file accepted") } catch is AssistantError {}
        }
        checkDeadlinesAndTimetable()
        print("Passed: Gemini payloads, DOCX text and invalid files, due-date filters, reminder eligibility and capacity, same-day and next-day timetable formatting.")
    }

    static func checkDeadlinesAndTimetable() {
        let now = Beijing.parse("2026-11-19T12:00:00+08:00")!
        func sample(_ id: String, _ due: Date, _ pending: Bool = true) -> Assignment {
            let date = ISO8601DateFormatter().string(from: due)
            return Assignment(id: id, course: "math", subject: "Math", title: id, brief: id,
                              kind: "assignment", status: "未提交", submissionBucket: "unsubmitted",
                              originalTitle: id, original: "", taskType: "", submission: nil, grade: nil,
                              assignedDay: "2026-11-18", due: date, actions: [], attachments: [],
                              pending: pending, translated: false, detailPending: false)
        }
        let yesterday = sample("due-today", now.addingTimeInterval(3_600))
        var filters = AssignmentFilters()
        assert(filters.effectiveRange == .today && filters.apply(to: [yesterday], now: now).isEmpty)
        filters.quickFilters = [.dueToday]
        assert(filters.effectiveRange == .all && filters.apply(to: [yesterday], now: now).map(\.id) == [yesterday.id])
        let export = MarkdownChecklist.text(tasks: filters.apply(to: [yesterday], now: now), range: filters.effectiveRange, now: now)
        assert(export.contains("All Dates") && export.contains("- [ ] **Math**: due-today"))
        let chineseExport = MarkdownChecklist.text(tasks: [yesterday], range: .all, now: now, inChinese: true)
        assert(chineseExport.hasPrefix("# 作业待办\n") && chineseExport.contains("截止 2026-11-19 13:00"))
        filters.quickFilters = []
        filters.deadlineView = true
        assert(filters.usesAllAssignedDates && filters.apply(to: [yesterday], now: now).count == 1)
        filters.deadlineView = false
        assert(filters.effectiveRange == .today)

        let past = (1...50).map { sample("past-\($0)", now.addingTimeInterval(-Double($0))) }
        let future = (1...50).reversed().map { sample("future-\($0)", now.addingTimeInterval(Double($0))) }
        let excluded = [sample("completed", now.addingTimeInterval(1), false), sample("due-now", now)]
        assert(HomeworkReminders.upcoming(past + future + excluded, at: now).map(\.task.id) == (1...48).map { "future-\($0)" })

        let next = Beijing.parse("2026-11-20T08:00:00+08:00")!
        let lesson = SchoolLesson(id: "math", title: "Math", startAt: next, endAt: next.addingTimeInterval(2700),
                                  room: nil, teacher: nil, temporary: false)
        assert(lesson.compactStart(relativeTo: now) == Beijing.shortDay(next) + " 08:00")
        assert(lesson.compactStart(relativeTo: next) == "08:00")
        let preferences = UserDefaults.standard
        let original = preferences.object(forKey: "interfaceLanguage")
        defer { preferences.set(original, forKey: "interfaceLanguage") }
        preferences.set("zh-Hans", forKey: "interfaceLanguage")
        assert(Beijing.dayLabel(now) == "11月19日 星期四" && Beijing.dueLabel(next, relativeTo: now) == "明天 08:00")
        preferences.set("en", forKey: "interfaceLanguage")
        assert(Beijing.dayLabel(now) == "Nov 19, Thursday" && Beijing.dueLabel(next, relativeTo: now) == "Tomorrow 08:00")
    }
}
