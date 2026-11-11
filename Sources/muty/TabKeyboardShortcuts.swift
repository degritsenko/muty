import SwiftUI
import AppKit

struct TabKeyboardShortcuts: NSViewRepresentable {
    @ObservedObject var model: AppModel

    final class MonitorView: NSView {
        weak var model: AppModel?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
                      let model = self.model, !model.tabs.isEmpty else { return event }
                let modifiers = event.modifierFlags.intersection([.command, .control, .shift, .option])
                let index: Int
                if event.keyCode == 48, modifiers == .control || modifiers == [.control, .shift] {
                    model.cycleTab(modifiers.contains(.shift) ? -1 : 1)
                    return nil
                } else if modifiers == .command,
                          let number = [UInt16(18): 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9][event.keyCode] {
                    index = number - 1
                    guard model.tabs.indices.contains(index) else { return nil }
                } else { return event }
                model.selectTab(model.tabs[index].id)
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.model = model
        return view
    }
    func updateNSView(_ view: MonitorView, context: Context) { view.model = model }
}
