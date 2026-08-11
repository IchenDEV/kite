import AppKit
import SwiftUI

/// Keeps macOS's source-list implementation on its only valid horizontal origin.
///
/// `List(.sidebar)` is vertically scrollable, but its private `NSScrollView` can
/// retain a horizontal rubber-band offset after a trackpad gesture. SwiftUI does
/// not expose the scroll view or a horizontal-elasticity setting, so this bridge
/// confines the AppKit workaround to the sidebar row hierarchy.
struct SidebarHorizontalScrollGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> SidebarHorizontalScrollGuardView {
        SidebarHorizontalScrollGuardView(frame: .zero)
    }

    func updateNSView(_ nsView: SidebarHorizontalScrollGuardView, context: Context) {
        nsView.installIfNeeded()
    }
}

final class SidebarHorizontalScrollGuardView: NSView {
    private weak var guardedScrollView: NSScrollView?
    private var boundsObservation: NSObjectProtocol?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        installAfterLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installAfterLayout()
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            removeBoundsObservation()
            guardedScrollView = nil
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    func installIfNeeded() {
        guard let scrollView = enclosingSidebarScrollView() else { return }
        guard guardedScrollView !== scrollView else {
            clampHorizontalOffset(in: scrollView)
            return
        }

        removeBoundsObservation()
        guardedScrollView = scrollView
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentView.postsBoundsChangedNotifications = true

        boundsObservation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self, weak scrollView] _ in
            Task { @MainActor in
                guard let self, let scrollView else { return }
                self.clampHorizontalOffset(in: scrollView)
            }
        }

        clampHorizontalOffset(in: scrollView)
    }

    private func installAfterLayout() {
        DispatchQueue.main.async { [weak self] in
            self?.installIfNeeded()
        }
    }

    private func enclosingSidebarScrollView() -> NSScrollView? {
        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView {
                return scrollView
            }
            ancestor = current.superview
        }
        return nil
    }

    private func clampHorizontalOffset(in scrollView: NSScrollView) {
        let clipView = scrollView.contentView
        guard abs(clipView.bounds.origin.x) > .ulpOfOne else { return }
        clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func removeBoundsObservation() {
        if let boundsObservation {
            NotificationCenter.default.removeObserver(boundsObservation)
        }
        boundsObservation = nil
    }
}
