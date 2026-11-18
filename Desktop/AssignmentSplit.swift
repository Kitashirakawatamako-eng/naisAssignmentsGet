import AppKit
import SwiftUI

struct AssignmentSplit<Sidebar: View, Detail: View>: View {
    @AppStorage("assignmentListWidth") private var preferredWidth = 510.0
    @GestureState private var dragOffset: CGFloat = 0
    @State private var hovering = false
    let sidebar: Sidebar
    let detail: Detail

    init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.detail = detail()
    }

    var body: some View {
        GeometryReader { geometry in
            let handleWidth: CGFloat = 9
            let minimum: CGFloat = 320
            let maximum = max(minimum, geometry.size.width - 380 - handleWidth)
            let fixedWidth = CGFloat(preferredWidth).clamped(to: minimum...maximum)
            let width = (fixedWidth + dragOffset).clamped(to: minimum...maximum)
            HStack(spacing: 0) {
                sidebar.frame(width: width)
                Rectangle()
                    .fill(hovering || dragOffset != 0 ? Color.accentColor : Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .frame(width: handleWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.set() }
                        else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .updating($dragOffset) { value, offset, _ in
                                offset = value.translation.width
                            }
                            .onEnded { value in
                                guard abs(value.translation.width) >= 1 else { return }
                                preferredWidth = (fixedWidth + value.translation.width).clamped(to: minimum...maximum)
                            }
                    )
                    .accessibilityElement()
                    .accessibilityLabel("Resize assignment list")
                    .accessibilityValue("\(Int(width)) points")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: preferredWidth = (fixedWidth + 24).clamped(to: minimum...maximum)
                        case .decrement: preferredWidth = (fixedWidth - 24).clamped(to: minimum...maximum)
                        @unknown default: break
                        }
                    }
                detail.frame(width: max(0, geometry.size.width - width - handleWidth))
            }
            .frame(height: geometry.size.height)
        }
    }
}

private extension CGFloat {
    func clamped(to limits: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(limits.upperBound, Swift.max(limits.lowerBound, self))
    }
}
