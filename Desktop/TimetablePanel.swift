import AppKit
import Combine
import SwiftUI

@MainActor
final class TimetablePanelController: NSObject, NSWindowDelegate {
    private static let size = NSSize(width: 304, height: 138)
    private static let positionKey = "floatingTimetablePosition"
    private var panel: TimetablePanel?
    private var visibility: AnyCancellable?
    private weak var store: AssignmentStore?
    private var openTimetable: (() -> Void)?

    func attach(store: AssignmentStore, openTimetable: @escaping () -> Void) {
        self.openTimetable = openTimetable
        guard self.store !== store else { return }
        self.store = store
        visibility = store.$floatingTimetable.removeDuplicates().sink { [weak self] visible in
            DispatchQueue.main.async { self?.setVisible(visible) }
        }
    }

    func stop() {
        visibility?.cancel()
        visibility = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func setVisible(_ visible: Bool) {
        guard visible, let store else {
            panel?.orderOut(nil)
            return
        }
        let window = panel ?? makePanel(store: store)
        panel = window
        if !window.isVisible {
            window.setFrameOrigin(preferredOrigin(size: window.frame.size))
            window.orderFrontRegardless()
        }
    }

    private func makePanel(store: AssignmentStore) -> TimetablePanel {
        let window = TimetablePanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        window.title = "课表小窗"
        window.identifier = NSUserInterfaceItemIdentifier("floating-timetable")
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.canHide = false
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary,
                                     .stationary, .ignoresCycle]
        window.isExcludedFromWindowsMenu = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.animationBehavior = .none
        window.contentView = TimetableHostingView(rootView: TimetablePanelCard(
            store: store, openTimetable: { [weak self] in self?.openTimetable?() }
        ).frame(width: Self.size.width, height: Self.size.height))
        window.delegate = self
        return window
    }

    private func preferredOrigin(size: NSSize) -> NSPoint {
        let screens = NSScreen.screens
        if let saved = UserDefaults.standard.array(forKey: Self.positionKey) as? [Double],
           saved.count == 2, saved.allSatisfy(\.isFinite) {
            let point = NSPoint(x: saved[0], y: saved[1])
            let center = NSPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
            if let screen = screens.first(where: { $0.frame.contains(center) }) {
                let frame = screen.visibleFrame
                return NSPoint(x: min(max(point.x, frame.minX), max(frame.minX, frame.maxX - size.width)),
                               y: min(max(point.y, frame.minY), max(frame.minY, frame.maxY - size.height)))
            }
        }
        guard let screen = NSScreen.main ?? screens.first else { return .zero }
        let frame = screen.visibleFrame
        return NSPoint(x: max(frame.minX, frame.maxX - size.width - 16), y: frame.minY + 16)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.isVisible else { return }
        let origin = window.frame.origin
        UserDefaults.standard.set([Double(origin.x), Double(origin.y)], forKey: Self.positionKey)
    }
}

private final class TimetablePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class TimetableHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct TimetablePanelCard: View {
    @ObservedObject var store: AssignmentStore
    let openTimetable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                ZStack(alignment: .leading) {
                    Label("课表", systemImage: "calendar").font(.caption.weight(.semibold)).foregroundStyle(jade)
                    PanelDragArea().accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                panelButton("打开完整课表", icon: "arrow.up.right", action: openTimetable)
                panelButton("隐藏课表小窗", icon: "xmark") { store.floatingTimetable = false }
            }
            .frame(height: 20)
            lessonRow("本节", lesson: store.currentLesson, empty: store.timetableCoversToday ? "当前无课" : "等待课表")
            Divider()
            lessonRow("下节", lesson: store.nextLesson,
                      empty: store.timetableCoversToday ? "暂无安排" : "打开课表查看")
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.14))
                .allowsHitTesting(false)
        }
    }

    private func lessonRow(_ caption: String, lesson: SchoolLesson?, empty: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(caption)
                .font(.caption.weight(.semibold))
                .foregroundStyle(jade)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(jade.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(lesson?.title ?? empty)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(lesson == nil ? .secondary : .primary)
                    .lineLimit(1)
                if let lesson {
                    Text(lesson.timeAndRoom(relativeTo: store.now))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 32, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .help(lesson?.title ?? empty)
    }

    private func panelButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 21, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }
}

private struct PanelDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> PanelDragView { PanelDragView() }
    func updateNSView(_ nsView: PanelDragView, context: Context) {}
}

private final class PanelDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
