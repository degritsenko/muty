import SwiftUI
import AppKit

struct SessionManagerCommands: NSViewRepresentable {
    var active: Bool
    var copy: () -> Void
    var cut: () -> Void
    var paste: () -> Void
    final class Coordinator {
        var monitor: Any?
        var parent: SessionManagerCommands
        weak var view: NSView?
        init(_ parent: SessionManagerCommands) { self.parent = parent }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator, coordinator.parent.active, event.window === coordinator.view?.window,
                  event.window?.firstResponder is NSTableView,
                  event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": coordinator.parent.copy()
            case "x": coordinator.parent.cut()
            case "v": coordinator.parent.paste()
            default: return event
            }
            return nil
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.parent = self }
}

struct TerminalSearchField: NSViewRepresentable {
    @Binding var text: String
    let request: UUID
    var submit: () -> Void
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: TerminalSearchField
        var lastRequest: UUID
        init(_ parent: TerminalSearchField) { self.parent = parent; self.lastRequest = parent.request }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.text = field.stringValue }
        }
        @objc func search(_ sender: NSSearchField) { parent.text = sender.stringValue; parent.submit() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(); field.placeholderString = "Find in terminal"; field.controlSize = .small
        field.delegate = context.coordinator; field.target = context.coordinator; field.action = #selector(Coordinator.search(_:))
        field.sendsSearchStringImmediately = false; field.sendsWholeSearchString = true
        field.setAccessibilityLabel("Find in terminal")
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastRequest != request {
            context.coordinator.lastRequest = request
            DispatchQueue.main.async { field.window?.makeFirstResponder(field); field.selectText(nil) }
        }
    }
}
