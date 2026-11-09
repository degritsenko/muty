import SwiftUI

struct SFTPTransfer: Identifiable {
    enum Kind { case upload, download, uploadDirectory, downloadDirectory }
    enum State: String { case waiting = "Waiting", copying = "Copying", done = "Done", failed = "Failed", cancelled = "Cancelled", skipped = "Skipped" }
    let id = UUID()
    let kind: Kind
    let source: String
    var destination: String
    var state: State = .waiting
    var error: String?
}
@MainActor final class SFTPTransferQueue: ObservableObject {
    @Published var items: [SFTPTransfer] = []
    @Published var paused = false
    var owner = UUID()
    var localPath: String?
    var remotePath: String?
}
struct SFTPTransfersView: View {
    @ObservedObject var queue: SFTPTransferQueue
    @ObservedObject var browser: SFTPBrowserModel
    @ViewState private var expanded = false
    private var active: Bool { queue.items.contains { $0.state == .copying || ($0.state == .waiting && !queue.paused) } }
    private var failures: [UUID] { queue.items.filter { $0.state == .failed || $0.state == .cancelled }.map(\.id) }
    var body: some View {
        if !queue.items.isEmpty {
        VStack(spacing: 4) {
            HStack {
                Text(active ? "Transfers: \(queue.items.filter { $0.state == .done }.count)/\(queue.items.count)" :
                     "\(queue.items.filter { $0.state == .done }.count) transferred").font(.caption)
                if queue.paused { Text("Paused").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if queue.paused {
                    Button("Resume") { browser.resumeTransfers() }.disabled(browser.disconnected)
                } else if active {
                    Button("Pause") { browser.pauseTransfers() }
                        .help("Pause transfers")
                }
                if !failures.isEmpty {
                    Button("Retry Failed") { browser.retryTransfers() }.disabled(browser.busy || browser.disconnected)
                }
                Button(expanded ? "Hide" : "Show") { expanded.toggle() }
                Button("Clear") { queue.items.removeAll { [.done, .skipped, .failed, .cancelled].contains($0.state) } }.disabled(browser.busy)
            }
            if expanded {
            List(queue.items) { item in
                HStack {
                    Image(systemName: item.kind == .upload || item.kind == .uploadDirectory ? "arrow.up" : "arrow.down")
                    Text((item.source as NSString).lastPathComponent).lineLimit(1).help(item.source + " → " + item.destination)
                    Spacer()
                    Text(item.state.rawValue).font(.caption)
                    if let error = item.error { Image(systemName: "exclamationmark.triangle").help(error) }
                    if item.state == .failed || item.state == .cancelled {
                        Button("Retry") { browser.retryTransfers(id: item.id) }.disabled(browser.busy || browser.disconnected)
                    }
                }
            }.frame(height: 100)
            }
        }.controlSize(.small)
        .padding(.horizontal, 6).padding(.vertical, expanded ? 6 : 2)
        .onChange(of: active) { _, value in
            expanded = value || !failures.isEmpty
        }
        .onChange(of: failures) { _, value in if !value.isEmpty { expanded = true } }
        .onAppear { expanded = active || !failures.isEmpty }
        }
    }
}
