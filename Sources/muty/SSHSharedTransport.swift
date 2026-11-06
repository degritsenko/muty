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
        ["-M", "-S", socketPath, "-o", profile.sshEnabled && !profile.tunnelOnly ? "ControlPersist=60" : "ControlPersist=no"]
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
