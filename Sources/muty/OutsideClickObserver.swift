import SwiftUI
import AppKit

struct OutsideClickObserver: NSViewRepresentable {
    let active: Bool
    let dismiss: (Int) -> Void
    final class ObserverView: NSView {
        var active = false
        var dismiss: ((Int) -> Void)?
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard let window else { return }
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                guard let self, self.active else { return }
                self.dismiss?(-1)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self, self.active, event.window === self.window,
                      !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.dismiss?(event.eventNumber)
                return event
            }
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        }
    }
    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) { view.active = active; view.dismiss = dismiss }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.removeMonitor(); view.dismiss = nil }
}
