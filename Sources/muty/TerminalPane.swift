import SwiftUI
import AppKit

struct TerminalPane: NSViewRepresentable {
    @ObservedObject var connection: SSHConnection
    var fontSize: Double
    var selected: Bool

    final class Coordinator { var selected = false }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let terminal = connection.terminal
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        connection.setFontSize(fontSize)
        DispatchQueue.main.async { connection.start() }
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        connection.setFontSize(fontSize)
        let becameSelected = selected && !context.coordinator.selected
        context.coordinator.selected = selected
        if becameSelected {
            DispatchQueue.main.async {
                guard !connection.showingSFTP else { return }
                if view.window?.firstResponder !== connection.terminal {
                    view.window?.makeFirstResponder(connection.terminal)
                }
            }
        }
    }
}
