import AppKit
import Darwin
import SwiftUI

@MainActor
private final class AppLifecycle: NSObject, NSApplicationDelegate {
    weak var store: AssignmentStore?
    let timetablePanel = TimetablePanelController()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        timetablePanel.stop()
        store?.stop()
    }
}

@main
@MainActor
struct HomeworkApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @AppStorage("interfaceLanguage") private var interfaceLanguage = "zh-Hans"
    @AppStorage("appearanceTheme") private var theme = "otter"
    @AppStorage("showTimetableInMenuBar") private var showTimetableInMenuBar = false
    @State private var widgetEditor: EditableWidgetSlot?
    @StateObject private var store: AssignmentStore
    @StateObject private var assistant: HomeworkAssistant
    @Environment(\.openWindow) private var openWindow

    init() {
        signal(SIGPIPE, SIG_IGN)
        let preferences = UserDefaults.standard
        preferences.register(defaults: ["interfaceLanguage": "zh-Hans"])
        if !preferences.bool(forKey: "creatureThemesIntroduced") {
            if preferences.object(forKey: "appearanceTheme") == nil {
                preferences.set("otter", forKey: "appearanceTheme")
            }
            if preferences.object(forKey: "appearanceIcon") == nil {
                preferences.set("bookOtter", forKey: "appearanceIcon")
            }
            preferences.set(true, forKey: "creatureThemesIntroduced")
        }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/作业速览", isDirectory: true)
        let instance = AssignmentStore(root: root, resources: Bundle.main.resourceURL)
        _store = StateObject(wrappedValue: instance)
        _assistant = StateObject(wrappedValue: instance.assistant)
    }

    var body: some Scene {
        Window("Assignment Overview", id: "assignments") {
            Group {
                switch store.page {
                case .assignments: AssignmentWindow(store: store)
                case .timetable: TimetableWindow(store: store)
                case .grades: GPAWindow(store: store)
                }
            }
            .modifier(AppearanceSurface())
            .sheet(item: $widgetEditor) { slot in
                VStack(alignment: .leading, spacing: 16) {
                    WidgetContentPicker(slot: slot, store: store)
                    Button("Done") { widgetEditor = nil }.keyboardShortcut(.defaultAction)
                }.padding(24).frame(minWidth: 320)
            }
            .sheet(isPresented: $store.settingsOpen) { AssignmentSettings(store: store, assistant: assistant) }
            .sheet(isPresented: $assistant.showPanel) { HomeworkAIPanel(assistant: assistant, store: store) }
            .preferredColorScheme(theme == "classic" ? nil : .light)
            .tint(jade)
            .environment(\.locale, Locale(identifier: interfaceLanguage))
            .onAppear(perform: connect)
            .onOpenURL { url in
                guard url.scheme == "spassignments" else { return }
                if url.host == "edit-widget", let number = Int(url.lastPathComponent),
                   let slot = EditableWidgetSlot(rawValue: number) {
                    if !store.settingsOpen { widgetEditor = slot }
                } else if url.host == "grades" {
                    store.page = .grades
                } else if url.host == "timetable" {
                    store.page = .timetable
                } else if url.host == "assignments" {
                    let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
                    store.openWidgetAssignment(id)
                } else {
                    return
                }
                openWindow(id: "assignments")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .defaultSize(width: 1120, height: 710)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store.settingsOpen = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Overview") {
                Button("Assignments") { store.page = .assignments }.keyboardShortcut("1")
                Button("Timetable") { store.page = .timetable }.keyboardShortcut("2")
                Button("Grades") { store.page = .grades }.keyboardShortcut("3")
                Toggle("Floating Timetable", isOn: $store.floatingTimetable)
            }
        }
        MenuBarExtra(isInserted: $showTimetableInMenuBar) {
            TimetableMenu(store: store).modifier(AppearanceSurface())
                .environment(\.locale, Locale(identifier: interfaceLanguage))
        } label: {
            TimetableMenuLabel(store: store)
                .environment(\.locale, Locale(identifier: interfaceLanguage))
            .onAppear(perform: connect)
        }
        .menuBarExtraStyle(.window)
    }

    private func connect() {
        AppIconChoice.apply(UserDefaults.standard.string(forKey: "appearanceIcon") ?? "bookOtter", updateFinder: false)
        lifecycle.store = store
        let open = openWindow
        lifecycle.timetablePanel.attach(store: store) { [weak store] in
            store?.page = .timetable
            open(id: "assignments")
            NSApp.activate(ignoringOtherApps: true)
        }
        assistant.reveal = { open(id: "assignments"); NSApp.activate(ignoringOtherApps: true) }
        store.start()
    }
}
