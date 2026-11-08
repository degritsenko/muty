import Foundation
import Darwin

@MainActor
final class SSHSharedTransport {
    let directory: URL
    let socketPath: String
    let profile: SessionProfile
    var tunnelManager: ActiveTunnelManager?
    private var closed = false

    init(profile: SessionProfile) throws {
        self.profile = profile
        directory = URL(fileURLWithPath: "/tmp/muty-mux-" + UUID().uuidString, isDirectory: true)
        socketPath = directory.appendingPathComponent("c").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    var isReady: Bool { !closed && FileManager.default.fileExists(atPath: socketPath) }
    var masterArguments: [String] {
        ["-M", "-S", socketPath, "-v", "-E", directory.appendingPathComponent("transport.log").path,
         "-o", profile.sshEnabled && !profile.tunnelOnly ? "ControlPersist=60" : "ControlPersist=no"]
    }
    var negotiatedCipher: String? {
        guard isReady,
              let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent("transport.log")) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 131072) else { return nil }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        func cipher(_ direction: String) -> String? {
            guard let line = lines.last(where: { $0.hasPrefix("debug1: kex: " + direction + " cipher: ") }),
                  let range = line.range(of: " cipher: ") else { return nil }
            let value = String(line[range.upperBound...].prefix(while: { !$0.isWhitespace }))
            guard !value.isEmpty, value.count < 100,
                  value.utf8.allSatisfy({ (45...57).contains($0) || (64...90).contains($0) || (97...122).contains($0) }) else { return nil }
            return value
        }
        guard let incoming = cipher("server->client"), let outgoing = cipher("client->server") else { return nil }
        return incoming == outgoing ? incoming : "↓ \(incoming) · ↑ \(outgoing)"
    }
    var diagnosticOutput: String {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("transport.log")) else { return "" }
        return String(decoding: data.prefix(131072), as: UTF8.self)
            .components(separatedBy: "\n").filter { !$0.hasPrefix("debug") }.joined(separator: "\r\n")
    }
    func close() {
        guard !closed else { return }
        closed = true
        tunnelManager?.connectionEnded(); tunnelManager = nil
        let directory = self.directory
        let args = ["-F", "/dev/null", "-S", socketPath, "-p", String(profile.port), "-l", profile.user, "-O", "exit", "--", profile.host]
        SSHConnection.cleanup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? FileManager.default.removeItem(at: directory)
                SSHConnection.cleanup.leave()
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = args
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < deadline { usleep(10_000) }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            } catch {}
        }
    }
    func clientArguments() -> [String] {
        // A missing/dead master must fail instead of silently making a new connection.
        ["-F", "/dev/null", "-o", "ControlPath=" + socketPath, "-o", "ControlMaster=no",
         "-o", "ControlPersist=no", "-o", "ProxyCommand=/usr/bin/false", "-o", "BatchMode=yes",
         "-o", "IdentityAgent=none", "-o", "IdentityFile=none", "-o", "PubkeyAuthentication=no",
         "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no"]
    }
}
