import SwiftUI
import AppKit

struct TerminalPane: NSViewRepresentable {
    @ObservedObject var connection: SSHConnection
    var fontSize: Double
    var selected: Bool
    var onSelect: () -> Void
    var isCurrentSelection: () -> Bool

    final class Container: NSView {
        var terminal: NSView?
        var freezeTerminalSize = false

        override func layout() {
            super.layout()
            guard !freezeTerminalSize, let terminal else { return }
            terminal.frame = bounds
        }
    }

    final class Coordinator { var selected = false }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = Container()
        let terminal = connection.terminal
        container.terminal = terminal
        container.addSubview(terminal)
        connection.setFontSize(fontSize)
        DispatchQueue.main.async { connection.start() }
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let container = view as? Container {
            container.freezeTerminalSize = connection.showingSFTP
            container.needsLayout = true
        }
        connection.setFontSize(fontSize)
        connection.terminal.onTerminalClick = onSelect
        let becameSelected = selected && !context.coordinator.selected
        context.coordinator.selected = selected
        if becameSelected {
            DispatchQueue.main.async {
                guard isCurrentSelection(), !connection.showingSFTP,
                      let window = view.window, window.isKeyWindow, window.attachedSheet == nil else { return }
                if window.firstResponder !== connection.terminal {
                    window.makeFirstResponder(connection.terminal)
                }
            }
        }
    }
}
