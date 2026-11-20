import SwiftUI

enum PlannerEditor: Identifiable {
    case task(PlanTask), regular(RegularArrangement), occurrence(CalendarEntry)
    var id: String {
        switch self {
        case .task(let task): return "edit/" + task.id
        case .regular(let series): return "series/" + series.id
        case .occurrence(let entry): return "occurrence/" + entry.id
        }
    }
}

struct CompletionMoment: Identifiable {
    let id = UUID()
    let title: String
}

@MainActor
final class PlannerStore: ObservableObject {
    @Published var data = PlannerData()
    @Published var message: String?
    @Published var editor: PlannerEditor?
    @Published var jumpDate: Date?
    @Published var completion: CompletionMoment?
    @Published var desktopVisible: Bool = UserDefaults.standard.object(forKey: "todayCalendarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(desktopVisible, forKey: "todayCalendarVisible") }
    }
    private let file: URL
    private let completionDuration: TimeInterval
    private var readable = true

    init(directory: URL? = nil, completionDuration: TimeInterval = 2.2) {
        self.completionDuration = completionDuration
        let custom = ProcessInfo.processInfo.environment["FIELDNOTES_DATA_DIR"]
        let folder = directory ?? custom.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Fieldnotes")
        file = folder.appendingPathComponent("planner.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                data = try JSONDecoder().decode(PlannerData.self, from: Data(contentsOf: file))
                translateScheduleToEnglish()
            }
            catch { readable = false; message = "Your saved planner could not be read. The original file has been preserved. \(error.localizedDescription)" }
        }
    }
    private func translateScheduleToEnglish() {
                let translations = ["AP 物理 1": "AP Physics 1", "AP物理C": "AP Physics C", "AP计算机科学 A": "AP Computer Science A", "品格教育": "Character Education", "天文学社团": "Astronomy Club", "竞赛社团-数学建模": "Mathematical Modeling Club", "英语语言12": "English Language 12", "语言12": "Language 12", "高中体育 （羽毛球）": "PE — Badminton", "刘点特": "Liu Diante", "隋元": "Sui Yuan", "秦丹": "Qin Dan", "伍丽云": "Wu Liyun", "刘汗青": "Liu Hanqing", "张建伟": "Zhang Jianwei", "钟阳": "Zhong Yang"]
                var changed = false
                for i in data.tasks.indices {
                    for (original, english) in translations.sorted(by: { $0.key.count > $1.key.count }) {
                        if data.tasks[i].title.contains(original) { data.tasks[i].title = data.tasks[i].title.replacingOccurrences(of: original, with: english); changed = true }
                        if data.tasks[i].subject.contains(original) { data.tasks[i].subject = data.tasks[i].subject.replacingOccurrences(of: original, with: english); changed = true }
                        if data.tasks[i].isSchoolClass && data.tasks[i].nextStep.contains(original) { data.tasks[i].nextStep = data.tasks[i].nextStep.replacingOccurrences(of: original, with: english); changed = true }
                    }
                }
                if changed { save() }
    }
    func setSchoolDay(_ enabled: Bool, on day: Date) {
        if enabled && !data.tasks.contains(where: { $0.isSchoolClass && $0.planned.map { PlanLogic.calendar.isDate($0, inSameDayAs: day) } == true }) {
            setSchoolSchedule(on: day, weekday: PlanLogic.calendar.component(.weekday, from: day))
            return
        }
        data.schoolDays[PlanLogic.dayKey(day)] = enabled
        save()
    }
    func setSchoolSchedule(on day: Date, weekday: Int?) {
        let key = PlanLogic.dayKey(day)
        let template = weekday.map { PlanLogic.schoolTemplate(for: $0, near: day, data: data) } ?? []
        if weekday != nil && template.isEmpty {
            message = "No imported classes are available for that weekday. Your schedule was not changed."
            return
        }
        data.tasks.removeAll { $0.sourceID?.hasPrefix("timetable-special:" + key + ":") == true }
        data.schoolScheduleSources.removeValue(forKey: key)
        if let weekday {
            data.schoolScheduleSources[key] = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][weekday - 1]
            for var task in template {
                let original = task.planned!
                task.id = UUID().uuidString
                task.sourceID = "timetable-special:" + key + ":" + task.id
                task.planned = PlanLogic.atMinute(PlanLogic.calendar.component(.hour, from: original) * 60 + PlanLogic.calendar.component(.minute, from: original), on: day)
                task.done = false
                data.tasks.append(task)
            }
            data.schoolDays[key] = true
        } else { data.schoolDays.removeValue(forKey: key) }
        save()
    }
    func save() {
        guard readable else { message = "Saving is paused because the existing planner file could not be read."; return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(data).write(to: file, options: .atomic)
        } catch { message = "Could not save your changes: \(error.localizedDescription)" }
    }
    private func celebrate(_ title: String) {
        let moment = CompletionMoment(title: title)
        completion = moment
        // The store owns expiration; view redraws and sheet transitions cannot restart it.
        DispatchQueue.main.asyncAfter(deadline: .now() + completionDuration) { [weak self] in
            guard let self, self.completion?.id == moment.id else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.completion = nil }
        }
    }
    func put(_ task: PlanTask) {
        let newlyCompleted = task.done && data.tasks.first(where: { $0.id == task.id })?.done != true
        if let index = data.tasks.firstIndex(where: { $0.id == task.id }) { data.tasks[index] = task }
        else { data.tasks.append(task) }
        save()
        if newlyCompleted { celebrate(task.title) }
    }
    func put(_ series: RegularArrangement) {
        if let index = data.arrangements.firstIndex(where: { $0.id == series.id }) { data.arrangements[index] = series }
        else { data.arrangements.append(series) }
        save()
    }
    func toggle(_ task: PlanTask) { var copy = task; copy.done.toggle(); put(copy) }
    func prioritize(_ task: PlanTask) { data.priorityID = data.priorityID == task.id ? nil : task.id; save() }
    func remove(_ task: PlanTask) {
        data.tasks.removeAll { $0.id == task.id }
        if data.priorityID == task.id { data.priorityID = nil }
        save()
    }
    func remove(_ series: RegularArrangement) {
        data.arrangements.removeAll { $0.id == series.id }
        data.exceptions.removeAll { $0.seriesID == series.id }
        save()
    }
    func change(_ exception: ArrangementException) {
        let newlyCompleted = exception.done && !exception.skipped && data.exceptions.first(where: { $0.id == exception.id })?.done != true
        PlanLogic.setException(exception, data: &data); save()
        if newlyCompleted {
            celebrate(exception.title ?? data.arrangements.first(where: { $0.id == exception.seriesID })?.title ?? "Arrangement")
        }
    }
    func restore(_ entry: CalendarEntry) {
        data.exceptions.removeAll { $0.seriesID == entry.seriesID && $0.originalDay == entry.originalDay }; save()
    }
    func move(_ token: String, to date: Date) -> Bool {
        guard PlanLogic.move(token, to: date, data: &data) else { return false }
        save(); return true
    }
    func edit(_ entry: CalendarEntry) {
        if let id = entry.taskID, let task = data.tasks.first(where: { $0.id == id }) { editor = .task(task) }
        else { editor = .occurrence(entry) }
    }
    func importSchool() {
        let report = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/作业速览/reports/latest.json")
        do {
            let added = try PlanLogic.importReport(Data(contentsOf: report), into: &data)
            translateScheduleToEnglish()
            save()
            if message == nil { message = "Imported \(added) new assignments and refreshed matching deadlines. Drag tasks from the list into the calendar to plan them. Sync 作业速览 first for current records; completion here does not submit schoolwork." }
        } catch { message = "Could not import school assignments. Open 作业速览 and sync first. \(error.localizedDescription)" }
    }
    var pending: [PlanTask] {
        data.tasks.filter { !$0.done }.sorted {
            if $0.due != $1.due { return ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

