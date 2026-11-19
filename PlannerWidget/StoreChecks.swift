import Foundation

@main
enum StoreChecks {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fieldnotes-store-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PlannerStore(directory: folder, completionDuration: 0.15)
        var first = PlanTask(title: "Completion timeout test")
        store.put(first)
        precondition(store.completion == nil)
        first.done = true
        store.put(first)
        precondition(store.completion?.title == first.title)
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(store.completion == nil, "Completion banner failed to expire")
        store.put(first)
        precondition(store.completion == nil, "Saving a completed task replayed the animation")

        first.done = false; store.put(first)
        first.done = true; store.put(first)
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = PlanTask(title: "Newer completion", done: true)
        store.put(second)
        let newerID = store.completion!.id
        try await Task.sleep(nanoseconds: 90_000_000)
        precondition(store.completion?.id == newerID, "Older expiry cleared a newer completion")
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(store.completion == nil)
        let reopened = PlannerStore(directory: folder)
        precondition(reopened.completion == nil && reopened.data.tasks.count == 2)
        let wed = PlanLogic.date("2026-11-18T08:10:00")!
        let thu = PlanLogic.date("2026-11-19T09:05:00")!
        store.put(PlanTask(title: "Wednesday class", planned: wed, sourceID: "timetable:wed"))
        store.put(PlanTask(title: "Thursday class", planned: thu, sourceID: "timetable:thu"))
        store.put(PlanTask(title: "Personal plan", planned: wed))
        store.setSchoolDay(false, on: wed)
        precondition(PlanLogic.entries(in: PlanLogic.dayInterval(wed), data: store.data).map(\.title) == ["Personal plan"])
        store.setSchoolSchedule(on: wed, weekday: 5)
        let switched = PlanLogic.entries(in: PlanLogic.dayInterval(wed), data: store.data)
        precondition(Set(switched.map(\.title)) == Set(["Personal plan", "Thursday class"]))
        precondition(PlanLogic.label(switched.first { $0.title == "Thursday class" }!.start, format: "HH:mm") == "09:05")
        precondition(PlanLogic.entries(in: PlanLogic.dayInterval(thu), data: store.data).count == 1)
        store.setSchoolSchedule(on: wed, weekday: 5)
        precondition(PlanLogic.entries(in: PlanLogic.dayInterval(wed), data: store.data).count == 2)
        let loaded = PlannerStore(directory: folder)
        precondition(loaded.data.schoolScheduleSources == store.data.schoolScheduleSources)
        store.setSchoolDay(false, on: wed)
        precondition(PlanLogic.entries(in: PlanLogic.dayInterval(wed), data: store.data).count == 1)
        store.setSchoolSchedule(on: wed, weekday: nil)
        precondition(Set(PlanLogic.entries(in: PlanLogic.dayInterval(wed), data: store.data).map(\.title)) == Set(["Wednesday class", "Personal plan"]))
        print("Passed: school-day visibility, weekday substitution, exact times, original-date preservation, repeated selection, persistence, and restoration.")
        print("Passed: automatic banner dismissal, rapid completions, no replay on save, and persistence without transient banners.")
    }
}
