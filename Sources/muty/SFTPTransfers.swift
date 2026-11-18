import SwiftUI

struct SFTPTransfersView: View {
    @ObservedObject var queue: SFTPTransferQueue
    @ObservedObject var browser: SFTPBrowserModel
    @ViewState private var expanded = false

    private var interrupted: [UUID] { queue.items.filter { $0.state == .interrupted }.map(\.id) }
    private var failures: [UUID] { queue.items.filter { $0.state == .failed || $0.state == .cancelled }.map(\.id) }
    private var waiting: Int { queue.items.filter { $0.state == .waiting }.count }
    private var done: Int { queue.items.filter { $0.state == .done }.count }
    private var actionsDisabled: Bool { browser.busy || browser.disconnected }
    private var summary: String {
        var counts = ["\(done) transferred"]
        if waiting > 0 { counts.append("\(waiting) waiting") }
        if !interrupted.isEmpty { counts.append("\(interrupted.count) interrupted") }
        return counts.joined(separator: " · ")
    }

    var body: some View {
        if let store = queue.recoveryStore {
            SFTPQueueRecoveryView(store: store, queue: queue, browser: browser)
        }
        if !queue.items.isEmpty || queue.persistenceError != nil {
            VStack(spacing: 4) {
                if !queue.items.isEmpty {
                    HStack {
                        Text(summary).font(.caption)
                        if queue.paused { Text("Paused").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if queue.paused {
                            Button("Resume") { browser.resumeTransfers() }.disabled(browser.disconnected)
                        } else if queue.running {
                            Button("Pause") { browser.pauseTransfers() }.help("Pause transfers")
                        } else if queue.awaitingStart && waiting > 0 {
                            Button("Start Queue") { browser.startTransfers() }.disabled(actionsDisabled)
                        }
                        if !failures.isEmpty {
                            Button(queue.awaitingStart ? "Queue Failed" : "Retry Failed") { browser.retryTransfers() }
                                .disabled(actionsDisabled)
                                .help(queue.awaitingStart ? "Add failed transfers to the waiting queue. Use Start Queue to run them." :
                                      "Retry failed transfers now")
                        }
                        Button(expanded ? "Hide" : "Show") { expanded.toggle() }
                        Button("Clear") { queue.clearFinished() }.disabled(browser.busy || !queue.items.contains(where: \.isFinished))
                    }
                    if expanded {
                        List(queue.items) { item in
                            HStack {
                                Image(systemName: item.isUpload ? "arrow.up" : "arrow.down")
                                Text((item.source as NSString).lastPathComponent).lineLimit(1).help(item.source + " → " + item.destination)
                                Spacer()
                                Text(item.state.rawValue).font(.caption)
                                if let error = item.error { Image(systemName: "exclamationmark.triangle").help(error) }
                                if item.canRetry {
                                    Button(item.state == .interrupted ? "Restart" : "Retry") { browser.retryTransfers(id: item.id) }
                                        .disabled(actionsDisabled)
                                        .help("Transfer this item from the beginning")
                                }
                            }
                        }.frame(height: 100)
                    }
                }
                if let error = queue.persistenceError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.controlSize(.small)
                .padding(.horizontal, 6).padding(.vertical, expanded ? 6 : 2)
                .onChange(of: queue.running) { _, running in
                    expanded = running || !failures.isEmpty || !interrupted.isEmpty || queue.awaitingStart
                }
                .onChange(of: failures) { _, value in if !value.isEmpty { expanded = true } }
                .onChange(of: interrupted) { _, value in if !value.isEmpty { expanded = true } }
                .onAppear { expanded = queue.running || !failures.isEmpty || !interrupted.isEmpty || queue.awaitingStart }
        }
    }
}

private struct SFTPQueueRecoveryView: View {
    @ObservedObject var store: SFTPTransferQueueStore
    @ObservedObject var queue: SFTPTransferQueue
    @ObservedObject var browser: SFTPBrowserModel

    var body: some View {
        if store.hasRecoverableTransfers && !browser.disconnected {
            HStack {
                Text("Saved SFTP queue available").font(.caption)
                Spacer()
                Button("Restore Queue") { queue.restore(owner: browser.id) }
                    .disabled(browser.busy)
            }
            .controlSize(.small)
            .padding(.horizontal, 6)
        }
    }
}
