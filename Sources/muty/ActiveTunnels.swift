import SwiftUI
import AppKit

@MainActor final class ActiveTunnelManager: ObservableObject {
    struct Entry: Identifiable {
        var rule: PortForward
        var state = "Stopped"
        var active = false
        var id: UUID { rule.id }
    }
    @Published var entries: [Entry]
    @Published private(set) var busy = false
    @Published private(set) var ended = false
    private weak var transport: SSHSharedTransport?
    init(transport: SSHSharedTransport, rules: [PortForward]) {
        self.transport = transport; entries = rules.map { Entry(rule: $0) }
    }
    func connectionEnded() { ended = true; for i in entries.indices { entries[i].active = false; entries[i].state = "Disconnected" } }
    func startConfigured() {
        Task { for id in entries.filter({ $0.rule.enabled != false }).map(\.id) { await change(id, start: true) } }
    }
    func validateListener(_ rule: PortForward) throws {
        if entries.contains(where: { $0.id != rule.id && $0.active && $0.rule.listenerKey == rule.listenerKey }) {
            throw MutyError("A tunnel is already listening on this address and port.")
        }
    }
    func change(_ id: UUID, start: Bool) async {
        guard !busy, !ended, let transport, transport.isReady, let i = entries.firstIndex(where: { $0.id == id }), entries[i].active != start else { return }
        var rule = entries[i].rule; rule.enabled = true
        busy = true; entries[i].state = start ? "Starting…" : "Stopping…"
        defer { busy = false }
        do {
            if start { try validateListener(rule) }
            let operation = start ? "forward" : "cancel"
            let args = transport.clientArguments() + ["-O", operation] + (try rule.arguments()) + ["-p", String(transport.profile.port), "-l", transport.profile.user, "--", transport.profile.host]
            try await Self.control(args)
            guard !ended, let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].active = start; entries[index].state = start ? "Listening" : "Stopped"
        } catch {
            if let index = entries.firstIndex(where: { $0.id == id }), !ended { entries[index].state = error.localizedDescription }
        }
    }
    private nonisolated static func control(_ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = args
                process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
                process.terminationHandler = { _ in }
                do {
                    try process.run()
                    try output.fileHandleForWriting.close()
                    let limit = Date().addingTimeInterval(15)
                    while process.isRunning && Date() < limit { Thread.sleep(forTimeInterval: 0.03) }
                    if process.isRunning { process.terminate(); throw MutyError("Tunnel control timed out.") }
                    let bytes = output.fileHandleForReading.readDataToEndOfFile()
                    guard process.terminationStatus == 0 else {
                        let message = String(decoding: bytes.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        throw MutyError(message.isEmpty ? "OpenSSH could not update this tunnel." : message)
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

struct ActiveTunnelsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: ActiveTunnelManager
    @ObservedObject var model: AppModel
    let profile: SessionProfile
    @ViewState private var editing: PortForward?
    @ViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Active Tunnels").font(.headline); Spacer()
                Button("Add…") { editing = PortForward() }.disabled(manager.busy || manager.ended)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Listening confirms the forwarding listener, not availability of the destination service.").font(.caption).foregroundStyle(.secondary)
            List(manager.entries) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(entry.rule.name ?? L(entry.rule.kind.title)).bold()
                        Text(L(entry.rule.kind.title)).foregroundStyle(.secondary)
                        Spacer()
                        Button(entry.active ? L("Stop") : L("Start / Retry")) { Task { await manager.change(entry.id, start: !entry.active) } }
                        Button("Edit…") { editing = entry.rule }
                        Button("Save to Session") { var rule = entry.rule; rule.enabled = entry.active; save(rule) }.disabled(model.readOnly || !model.profiles.contains(where: { $0.id == profile.id }))
                    }
                    Text(entry.rule.bindAddress + ":" + String(entry.rule.listenPort) + " → " + (entry.rule.kind == .socks ? "SOCKS" : entry.rule.destinationHost + ":" + String(entry.rule.destinationPort))).font(.system(size: 11, design: .monospaced))
                    Text(L(entry.state)).font(.caption).foregroundStyle(entry.active ? .green : .secondary).textSelection(.enabled)
                }.padding(.vertical, 4).disabled(manager.busy || manager.ended)
            }
            if let error { Text(L(error)).font(.caption).foregroundStyle(.red) }
        }.padding(16).frame(minWidth: 660, idealWidth: 750, minHeight: 330)
        .sheet(item: $editing) { rule in
            ActiveTunnelEditor(rule: rule, server: profile.host) { value in
                try manager.validateListener(value)
                Task {
                    guard !manager.busy, !manager.ended else { return }
                    do { try manager.validateListener(value) }
                    catch { self.error = error.localizedDescription; return }
                    if let old = manager.entries.first(where: { $0.id == value.id }), old.active {
                        await manager.change(value.id, start: false)
                        guard manager.entries.first(where: { $0.id == value.id })?.active == false else { return }
                    }
                    if let i = manager.entries.firstIndex(where: { $0.id == value.id }) { manager.entries[i] = .init(rule: value) }
                    else { manager.entries.append(.init(rule: value)) }
                    await manager.change(value.id, start: true)
                }
            }
        }
    }
    private func save(_ rule: PortForward) {
        guard var updated = model.profiles.first(where: { $0.id == profile.id }) else { return }
        if let i = updated.forwards.firstIndex(where: { $0.id == rule.id }) { updated.forwards[i] = rule }
        else { updated.forwards.append(rule) }
        do { try model.save(updated, password: "", reuse: false, revokeActiveAuthentication: false) }
        catch { self.error = error.localizedDescription }
    }
}
private struct ActiveTunnelEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState var rule: PortForward
    let server: String
    let apply: (PortForward) throws -> Void
    @ViewState private var error: String?
    var body: some View {
        VStack {
            ForwardRuleFields(rule: $rule, server: server)
            if let error { Text(L(error)).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Apply and Start") {
                do { rule.enabled = true; _ = try rule.arguments(); try apply(rule); dismiss() } catch { self.error = error.localizedDescription }
            } }
        }.padding(18).frame(width: 480, height: 420)
    }
}
