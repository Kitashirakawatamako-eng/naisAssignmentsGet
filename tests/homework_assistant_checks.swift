import AppKit
import Foundation
@main struct AssistantChecks {
    @MainActor static func main() throws {
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
        let imageFile = dir.appendingPathComponent("questions.jpg"); try Data([1,2,3]).write(to: imageFile)
        let imageParts = try HomeworkAIRequest.content(title:"T",subject:"S",instructions:"I",files:[imageFile])
        let attachment = imageParts.last!
        assert(attachment["type"] as? String == "image")
        assert(attachment["mime_type"] as? String == "image/jpeg")
        assert(Data(base64Encoded: attachment["data"] as! String) == Data([1,2,3]))
        let pages = (0..<9).map { _ in PageImages.Item.image(Data([1]), "image/jpeg") }
        assert(PageImages.batches(pages).map(\.count) == [4, 4, 3])
        for (name, data) in [("questions.zip", Data([1,2])), ("broken.docx", Data([1,2])), ("huge.pdf", Data(repeating:0, count:10_000_001))] {
            let bad = dir.appendingPathComponent(name); try data.write(to: bad)
            do { _ = try HomeworkAIRequest.content(title:"T",subject:"S",instructions:"I",files:[bad]); fatalError("Invalid file accepted") } catch is AssistantError {}
        }
        checkDeadlinesAndTimetable()
        try checkWidgetAndAttachmentLibrary(in: dir)
        checkGradeAnalysis()
        try checkGradeImport(in: dir)
        if let path = CommandLine.arguments.dropFirst().first, let app = Bundle(path: path) {
            checkIconVariants(in: app)
        }
        print("Passed: Gemini payloads, DOCX text and invalid files, due-date filters, reminder eligibility and capacity, same-day and next-day timetable formatting.")
    }

    static func checkGradeImport(in root: URL) throws {
        let sample = "\u{feff}科目,项目,类别,日期,得分,满分,项目ID\r\n" +
            #"进阶数学,"Quiz, ""A""",测验,2026-11-03,0,20,one"# + "\r\n" +
            "进阶数学,Homework,作业,2026-11-05,18,20,two\r\n" +
            "进阶数学,Old,作业,2026-01-05,19,20,old\r\n"
        let input = try GradeCSV.parse(Data(sample.utf8))
        assert(input.count == 3 && input[0].entry.grade.score == "0")
        assert(input[0].entry.grade.title == #"Quiz, "A""#)
        let incomplete = SchoolGrade(id: "one", course: "Advanced Math", subject: "进阶数学", title: "Quiz, A", category: "测验",
                                     day: "2026-11-03", score: "0", total: nil, level: nil, exempt: false)
        let aliases: [String: Set<String>] = ["进阶数学": ["Advanced Math"]]
        let plan = GradeCSV.plan(input, school: [incomplete], stored: [], aliases: aliases,
                                 start: "2026-08-01", end: "2027-01-01")
        assert(plan.preview.map(\.disposition) == [.supplement, .add, .outside])
        let stored = GradeImportStorage(terms: ["t": plan.records])
        try stored.save(in: root)
        assert(GradeImportStorage.read(in: root).terms["t"] == plan.records)
        let joined = GradeCSV.merged(school: [incomplete], imported: plan.records)
        assert(joined.count == 2 && joined.first(where: { $0.id == "one" })?.total == "20")
        let repeated = GradeCSV.plan(input, school: joined, stored: plan.records, aliases: aliases,
                                     start: "2026-08-01", end: "2027-01-01")
        assert(repeated.preview.map(\.disposition) == [.same, .same, .outside])
        let malformed = Data("course,title,score\nmath,\"Unclosed,2".utf8)
        do { _ = try GradeCSV.parse(malformed); fatalError("Malformed CSV accepted") } catch is GradeCSV.ImportError {}
        let conflicting = try GradeCSV.parse(Data("course,title,score,id\nMath,Quiz,12,same\nMath,Quiz,14,same".utf8))
        let conflicts = GradeCSV.plan(conflicting, school: [], stored: [], aliases: [:], start: nil, end: nil)
        assert(conflicts.records.isEmpty && conflicts.preview.map(\.disposition) == [.conflict, .conflict])
        let oldPreferences = Data("{\"rules\":{},\"groups\":{},\"omitted\":[],\"scale\":\"\"}".utf8)
        let upgraded = try JSONDecoder().decode(GradePreferences.self, from: oldPreferences)
        assert(upgraded.reported == nil && upgraded.scenarios == nil)
        print("Passed: grade CSV, merge preview, zero score, idempotency, local storage, semester boundaries and settings migration.")
    }

    static func checkGradeAnalysis() {
        let score = SchoolGrade(id: "1", course: "math", subject: "Math", title: "Grade", category: "Work",
                                day: "2026-11-20", score: "340", total: "400", level: nil, exempt: false)
        var preferences = GradePreferences()
        let actual = OverallEstimate(records: [score], courses: ["math", "art"], term: "fall", preferences: preferences)
        assert(actual.total.average == 3 && actual.total.courses == 1 && actual.eligible == 2)
        assert(actual.maximum == 5)
        let ap = SchoolGrade(id: "ap", course: "AP物理", subject: "Physics", title: "Exam", category: "",
                             day: nil, score: "85", total: "100", level: nil, exempt: false)
        assert(OverallEstimate(records: [score, ap], courses: [], term: "fall", preferences: preferences).total.average == 3.5)
        preferences.weightedEstimate = false
        assert(OverallEstimate(records: [score, ap], courses: [], term: "fall", preferences: preferences).total.average == 3)
        preferences.weightedEstimate = true
        let key = "fall\u{1f}math"
        let plan = [GradeSectionInput(weight: "60", score: "100"), GradeSectionInput(weight: "40", score: "75")]
        preferences.sectionPlans = [key: plan]
        let projected = OverallEstimate(records: [score], courses: ["math"], term: "fall", preferences: preferences, projected: true)
        assert(projected.valid && projected.total.average == 4)
        assert(projected.cumulative(prior: PriorGPA(average: "3", credits: "3")) == 3.25)
        let observed = OverallEstimate(records: [score], courses: [], term: "fall", preferences: preferences)
        assert(observed.total.average == 3)
        preferences.sectionPlans = [key: Array(plan.prefix(1))]
        assert(!OverallEstimate(records: [score], courses: [], term: "fall", preferences: preferences, projected: true).valid)
        let points = CourseGrades(records: [score], rule: GradingRule())
        assert(points.percent() == 85)
        assert(near(points.requiredScore(target: 85, addedMaximum: 100, in: ""), 85))
        assert(near(points.requiredScore(target: 90, addedMaximum: 100, in: ""), 110))
        assert(points.minimumCount(target: 90, maximum: 100, expected: 100, in: "") == 2)
        assert(points.minimumCount(target: 90, maximum: 100, expected: 95, in: "") == 4)
        assert(points.minimumCount(target: 90, maximum: 100, expected: 90, in: "") == nil)

        let zero = SchoolGrade(id: "2", course: "math", subject: "Math", title: "Zero", category: "Quiz",
                               day: nil, score: "0", total: "100", level: nil, exempt: false)
        assert(CourseGrades(records: [score, zero], rule: GradingRule()).percent() == 68)
        assert(CourseGrades(records: [score, zero], rule: GradingRule(), excluded: [zero.id]).percent() == 85)
        var weighted = GradingRule()
        weighted.weighted = true
        weighted.weights = ["Work": "60", "Quiz": "40"]
        weighted.pastPoints = ["Quiz": GradePoints(earned: 80, possible: 100), "": GradePoints(earned: 5, possible: 100)]
        let course = CourseGrades(records: [score], rule: weighted)
        assert(near(course.percent(), 83))
        assert(near(course.requiredScore(target: 84.8, addedMaximum: 100, in: "Work"), 100))
        weighted.weights["Quiz"] = "35"
        assert(CourseGrades(records: [score], rule: weighted).percent() == nil)

        weighted.weights = ["Work": "20", "Quiz": "15", "Project": "20", "Exam": "30", "Participation": "15"]
        weighted.pastPoints = [
            "Work": GradePoints(earned: 96, possible: 100),
            "Quiz": GradePoints(earned: 100, possible: 100),
            "Exam": GradePoints(earned: 98, possible: 100),
            "Participation": GradePoints(earned: 100, possible: 100)
        ]
        assert(CourseGrades(records: [], rule: weighted).percent() == nil)
        weighted.ignoreUngradedCategories = true
        let missingProject = CourseGrades(records: [], rule: weighted)
        assert(near(missingProject.percent(), 98.25))
        assert(near(missingProject.percent(additional: GradePoints(earned: 90, possible: 100), to: "Project"), 96.6))
        assert(near(missingProject.requiredScore(target: 97, addedMaximum: 100, in: "Project"), 92))
        assert(near(missingProject.requiredScore(target: 98.75, addedMaximum: 100, in: "Work"), 100))
        assert(missingProject.minimumCount(target: 98.75, maximum: 100, expected: 100, in: "Work") == 1)
        weighted.pastPoints["Project"] = GradePoints(earned: 0, possible: 100)
        assert(near(CourseGrades(records: [], rule: weighted).percent(), 78.6))

        let schoolJSON = """
        {"id":"c","name":"Synthetic","englishName":"","className":"","percent":88.2,"points":3.3,
         "ranges":[{"minimum":87,"maximum":89.9,"includesMinimum":true,"includesMaximum":true,"level":"B+","points":3.3},
                   {"minimum":90,"maximum":100,"includesMinimum":true,"includesMaximum":true,"level":"A","points":4}],
         "categories":[{"name":"Work","englishName":"","weight":60,"score":86,"children":[],"estimatedCount":4},
                       {"name":"Exam","englishName":"","weight":40,"score":91.5,"children":[]}]}
        """
        let school = try! JSONDecoder().decode(SchoolDynamicCourse.self, from: Data(schoolJSON.utf8))
        let reconciled = CourseGrades(school: school, rule: GradingRule())!
        assert(near(reconciled.percent(), 88.2))
        assert(near(reconciled.percent(additional: GradePoints(earned: 9, possible: 10), to: "Work"), 88.68))
        assert(near(reconciled.percent(additional: GradePoints(earned: 90, possible: 100), to: "Work"), 88.68))
        assert(near(reconciled.requiredScore(target: 90, addedMaximum: 20, in: "Work", count: 2), 19))
        assert(reconciled.minimumCount(target: 90, maximum: 10, expected: 9.5, in: "Work") == 2)
        assert(reconciled.requiredScore(target: 90, addedMaximum: 100, in: "Exam") == nil)
        assert(near(reconciled.neededCategoryPercent(target: 90, in: "Exam"), 96))
        assert(school.scale?.points(at: 89.94) == 3.3 && school.scale?.points(at: 89.96) == 4)
        assert(school.scale?.minimumPercent(for: 4) == 90)

        let work = PlannedGrade(course: "c", category: "Work", maximum: "10", expected: "10")
        let secondWork = PlannedGrade(course: "c", category: "Work", maximum: "100", expected: "95")
        let exam = PlannedGrade(course: "c", category: "Exam", maximum: "20", expected: "20")
        let single = reconciled.impact(of: [work])!
        assert(near(single.categories[0].before, 86) && near(single.categories[0].after, 88.8))
        assert(near(single.coursePercent, 89.88))
        assert(reconciled.impact(of: [work, exam]) == nil)
        let combined = reconciled.impact(of: [work, secondWork, exam], assumedCounts: ["Exam": 2])!
        assert(combined.categories.map(\.id) == ["Exam", "Work"])
        assert(near(combined.categories[0].after, 94.33333333333333))
        assert(near(combined.categories[1].after, 89.83333333333333))
        assert(near(combined.coursePercent, 91.63333333333333))
        assert(school.scale?.points(at: combined.coursePercent) == 4)
        let missing = PlannedGrade(course: "c", category: "Work", maximum: "10", expected: "0")
        assert(near(reconciled.impact(of: [missing])?.categories.first?.after, 68.8))
        let invalid = PlannedGrade(course: "c", category: "Manual label", maximum: "10", expected: "9")
        assert(reconciled.impact(of: [invalid]) == nil)

        let scale = GPAScale("90=4.0\n85=3.5\n80=3.0\n0=0")!
        assert(scale.points(at: 89.999) == 3.5 && scale.points(at: 90) == 4)
        assert(GPAScale("0=4\n90=3") == nil)
        var other = GPACreditTotal()
        other.add(points: 3, credits: 3)
        other.add(points: 4, credits: 3)
        assert(scale.minimumPercent(for: other.pointsNeeded(to: 3.7, courseCredits: 4)) == 90)
        other.add(points: 3.5, credits: 4)
        assert(other.average == 3.5)
        print("Passed: GPA thresholds, honors rules inputs, weighted categories, published zero, next score and minimum count.")
    }

    static func near(_ value: Double?, _ target: Double) -> Bool {
        value.map { abs($0 - target) < 1e-8 } ?? false
    }

    @MainActor static func checkIconVariants(in bundle: Bundle) {
        for choice in ["otter", "creature"] {
            let transparent = AppIconChoice.image(choice, background: false, bundle: bundle)!
            let backdrop = AppIconChoice.image(choice, background: true, bundle: bundle)!
            let corner = alpha(of: backdrop, x: 0, y: 0)
            let tile = alpha(of: backdrop, x: 0.50, y: 0.13)
            let revealsBackground = [0.15, 0.25, 0.50, 0.75, 0.85].contains { x in
                [0.15, 0.25, 0.50, 0.75, 0.85].contains { y in
                    alpha(of: backdrop, x: x, y: y) >= 250 && alpha(of: transparent, x: x, y: y) < 15
                }
            }
            assert(corner == 0 && tile >= 250 && revealsBackground, "Invalid background for \(choice)")

        }
        let classic = AppIconChoice.image("classic", bundle: bundle)!
        assert(alpha(of: classic, x: 0, y: 0) == 0)
        assert(alpha(of: classic, x: 0.10, y: 0.10) == 0)
        assert(alpha(of: classic, x: 0.50, y: 0.50) > 250)
        let bundled = NSImage(contentsOf: bundle.url(forResource: "AppIcon", withExtension: "icns")!)!
        assert(alpha(of: bundled, x: 0, y: 0) == 0, "Bundled Finder icon must have transparent corners")
        print("Passed: separate themed icon backgrounds, fully transparent corners, and original icon.")
    }

    static func alpha(of image: NSImage, x: Double, y: Double) -> UInt8 {
        let width = 128
        var bytes = [UInt8](repeating: 0, count: width * width * 4)
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let ctx = CGContext(data: &bytes, width: width, height: width, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: width))
        return bytes[(Int(y * Double(width)) * width + Int(x * Double(width))) * 4 + 3]
    }

    static func checkWidgetAndAttachmentLibrary(in root: URL) throws {
        let when = Beijing.parse("2026-11-20T10:00:00+08:00")!
        let pin = WidgetAssignment(id: "task & review/2", title: "Review notes", subject: "Math", due: when, pending: true)
        let day = Beijing.day(when)
        let widget = WidgetSnapshot(theme: "paleo", language: "en",
                                    timetable: Timetable(checkedAt: when, startDay: day, endDay: day, courses: []),
                                    pins: [pin], pinCount: 1)
        let restored = try WidgetSnapshot.decode(from: widget.encoded())
        assert(restored.theme == "paleo" && restored.timetable?.covers(when) == true && restored.pins.first?.due == when)
        assert(URLComponents(url: pin.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == pin.id)

        // Old snapshots omit both slot settings and GPA; they must still load after upgrading.
        assert(restored.preferredContent == nil && restored.secondContent == nil && restored.gpa == nil)
        var configuredSnapshot = restored
        configuredSnapshot.preferredContent = "deadlines"
        configuredSnapshot.secondContent = "gpa"
        configuredSnapshot.deadlines = [pin]
        configuredSnapshot.gpa = WidgetGPA(schoolValue: "3.65")
        configuredSnapshot.slots = [
            "1": WidgetSlotAppearance(color: "blue", pins: [pin], count: 1),
            "2": WidgetSlotAppearance(color: "lavender", pins: [], count: 0)
        ]
        let saved = try WidgetSnapshot.decode(from: configuredSnapshot.encoded())
        assert(saved.slots?["1"]?.pins.first?.id == pin.id && saved.slots?["1"]?.color == "blue")
        assert(saved.slots?["2"]?.count == 0 && saved.slots?["2"]?.color == "lavender")
        assert(saved.preferredContent == "deadlines" && saved.secondContent == "gpa")
        assert(saved.deadlines?.first?.id == pin.id && saved.gpa?.schoolValue == "3.65")

        let files = FileManager.default
        let filenames = ["data/tasks/sample/one/notes.txt", "data/tasks/sample/two/notes.txt"]
        for filename in filenames {
            let url = root.appendingPathComponent(filename)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(filename.utf8).write(to: url)
        }
        let attachments = (filenames + ["questions.txt"]).map {
            Attachment(name: "notes.txt", url: nil, localPath: $0, downloadStatus: nil)
        }
        let task = Assignment(id: pin.id, course: "math", subject: "Math", title: pin.title, brief: pin.title,
                              kind: "assignment", status: "未提交", submissionBucket: "unsubmitted",
                              originalTitle: "../ Review: 剩余练习", original: "", taskType: "", submission: nil, grade: nil,
                              assignedDay: day, due: nil, actions: [], attachments: attachments, pending: true,
                              translated: false, detailPending: false)
        let base = root.appendingPathComponent("Selected Folder", isDirectory: true)
        let copies = AttachmentLibrary.copies(for: task, in: root, to: base)
        assert(copies.count == 2 && Set(copies.map(\.destination)).count == 2)
        assert(copies.allSatisfy { $0.folder.deletingLastPathComponent() == base && $0.folder.lastPathComponent.hasPrefix(day) })
        for copy in copies {
            try AttachmentLibrary.makeCopy(copy, in: base)
            assert(AttachmentLibrary.readableCopy(copy, in: base) == copy.destination)
            let saved = try Data(contentsOf: copy.destination)
            assert(saved == (try? Data(contentsOf: copy.source)))
        }
        let edited = Data("local edits".utf8)
        try edited.write(to: copies[0].destination)
        try AttachmentLibrary.makeCopy(copies[0], in: base)
        let after = try Data(contentsOf: copies[0].destination)
        assert(after == edited)

        let redirectedBase = root.appendingPathComponent("Redirected Folder", isDirectory: true)
        let redirected = AttachmentLibrary.copies(for: task, in: root, to: redirectedBase)[0]
        try files.createDirectory(at: redirectedBase, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: redirected.folder, withDestinationURL: root)
        do {
            try AttachmentLibrary.makeCopy(redirected, in: redirectedBase)
            fatalError("A symlink redirected the export outside its folder")
        } catch let error as CocoaError { assert(error.code == .fileWriteNoPermission) }
        print("Passed: widget snapshot and deep-link round-trip; attachment folder, duplicate names, local edits and traversal checks.")
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
        var offline = yesterday
        offline.pending = false
        var completion = AssignmentFilters()
        completion.range = .all
        completion.completion = .unfinished
        assert(completion.apply(to: [offline], now: now).isEmpty)
        completion.completion = .finished
        assert(completion.apply(to: [offline], now: now).first?.submissionBucket == "unsubmitted")
        assert(HomeworkReminders.upcoming([offline], at: now).isEmpty)
        assert(HomeworkReminders.upcoming([yesterday], at: now).count == 1)
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
