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
    @AppStorage("interfaceLanguage") private var interfaceLanguage = "en"
    @StateObject private var store: AssignmentStore
    @StateObject private var assistant: HomeworkAssistant
    @Environment(\.openWindow) private var openWindow

    init() {
        signal(SIGPIPE, SIG_IGN)
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
                }
            }
            .sheet(isPresented: $store.settingsOpen) { AssignmentSettings(store: store, assistant: assistant) }
            .sheet(isPresented: $assistant.showPanel) { HomeworkAIPanel(assistant: assistant, store: store) }
            .environment(\.locale, Locale(identifier: interfaceLanguage))
            .onAppear(perform: connect)
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
                Toggle("Floating Timetable", isOn: $store.floatingTimetable)
            }
        }
        MenuBarExtra {
            TimetableMenu(store: store)
        } label: {
            TimetableMenuLabel(store: store)
                .environment(\.locale, Locale(identifier: interfaceLanguage))
            .onAppear(perform: connect)
        }
        .menuBarExtraStyle(.window)
    }

    private func connect() {
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
