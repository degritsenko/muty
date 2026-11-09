import SwiftUI
import AppKit

@MainActor
final class BackupOperationLog: ObservableObject {
    @Published private(set) var entries: [String] = []
    @Published private(set) var running = false
    @Published private(set) var failed = false
    @Published private(set) var title = ""
    @Published private(set) var path: String?

    var started: Bool { !entries.isEmpty }

    func start(_ title: String, path: String?) {
        self.title = title
        self.path = path
        entries = []
        failed = false
        running = true
        append("Starting…")
    }

    func append(_ message: String) { entries.append(message) }

    func finish(_ message: String) {
        append(message)
        running = false
    }

    func fail(_ error: Error) {
        append("Failed: " + error.localizedDescription)
        failed = true
        running = false
    }
}

struct BackupOperationLogView: View {
    @ObservedObject var log: BackupOperationLog
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(log.title).font(.title2.bold())
            if let path = log.path {
                Text(path).font(.caption).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.entries.joined(separator: "\n"))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(height: 300)
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: log.entries.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack {
                if log.running {
                    ProgressView().controlSize(.small)
                    Text(log.entries.last ?? "Working…").lineLimit(1)
                } else {
                    Label(log.failed ? "Failed" : "Completed",
                          systemImage: log.failed ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(log.failed ? Color.orange : Color.secondary)
                }
                Spacer()
                Button("Copy Log") {
                    let text = ([log.title] + (log.path.map { [$0] } ?? []) + log.entries).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Close", action: close).keyboardShortcut(.cancelAction).disabled(log.running)
            }.font(.callout)
        }
        .padding(22).frame(width: 680)
        .interactiveDismissDisabled(log.running)
    }
}
