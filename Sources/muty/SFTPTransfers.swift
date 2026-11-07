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
    var body: some View {
        if !queue.items.isEmpty {
        VStack(spacing: 4) {
            HStack {
                Text("Transfers: \(queue.items.filter { $0.state == .done }.count)/\(queue.items.count)").font(.caption)
                Spacer()
                Button("Resume / Retry Failed") { browser.retryTransfers() }.disabled(browser.busy || browser.disconnected)
                Button("Clear Completed") { queue.items.removeAll { $0.state == .done || $0.state == .skipped } }.disabled(browser.busy)
            }
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
        }.padding(6)
        }
    }
}
