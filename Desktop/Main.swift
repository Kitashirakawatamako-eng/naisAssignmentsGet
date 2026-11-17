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
    @StateObject private var store: AssignmentStore
    @Environment(\.openWindow) private var openWindow

    init() {
        signal(SIGPIPE, SIG_IGN)
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/作业速览", isDirectory: true)
        _store = StateObject(wrappedValue: AssignmentStore(root: root, resources: Bundle.main.resourceURL))
    }

    var body: some Scene {
        Window("作业速览", id: "assignments") {
            Group {
                switch store.page {
                case .assignments: AssignmentWindow(store: store)
                case .timetable: TimetableWindow(store: store)
                }
            }
            .sheet(isPresented: $store.settingsOpen) { AssignmentSettings(store: store) }
            .onAppear(perform: connect)
        }
        .defaultSize(width: 1120, height: 710)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.settingsOpen = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("速览") {
                Button("作业") { store.page = .assignments }.keyboardShortcut("1")
                Button("课表") { store.page = .timetable }.keyboardShortcut("2")
                Toggle("课表小窗", isOn: $store.floatingTimetable)
            }
        }
        MenuBarExtra {
            TimetableMenu(store: store)
        } label: {
            TimetableMenuLabel(store: store)
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
        store.start()
    }
}
