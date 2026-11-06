import Foundation
import AppKit
import SwiftTerm
import Darwin
@testable import muty

private final class LockedCredentials: CredentialStore {
    var accesses = 0
    func read(id: UUID) throws -> String? { accesses += 1; throw MutyError("locked") }
    func write(id: UUID, password: String) throws { accesses += 1; throw MutyError("locked") }
    func delete(id: UUID) throws { accesses += 1; throw MutyError("locked") }
}

private final class DisposableCredentials: CredentialStore {
    var reads = 0
    func read(id: UUID) throws -> String? { reads += 1; return "throwaway-broker-secret" }
    func write(id: UUID, password: String) throws {}
    func delete(id: UUID) throws {}
}

private final class PTYObserver: NSObject, LocalProcessTerminalViewDelegate {
    var ended = false
    var status: Int32?
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { status = exitCode; ended = true }
}

final class RegressionTests {
    @MainActor func testIndependentKnownHosts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("muty host keys " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = directory.appendingPathComponent("host")
        let generate = Process()
        generate.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        generate.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", key.path]
        try generate.run(); generate.waitUntilExit()
        assert(generate.terminationStatus == 0)
        let publicKey = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = directory.appendingPathComponent("openssh")
        try Data(("host.invalid " + publicKey + "\n@revoked old.invalid " + publicKey +
                  "\n@cert-authority *.test.invalid " + publicKey + "\n").utf8).write(to: source)
        let hash = Process()
        hash.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        hash.arguments = ["-H", "-f", source.path]
        hash.standardOutput = FileHandle.nullDevice; hash.standardError = FileHandle.nullDevice
        try hash.run(); hash.waitUntilExit()
        assert(hash.terminationStatus == 0)
        let original = try Data(contentsOf: source)
        let file = directory.appendingPathComponent("muty/known_hosts")
        let store = KnownHostsStore(file: file)
        let imported = try store.importFrom(source)
        let repeated = try store.importFrom(source)
        let preserved = try Data(contentsOf: source)
        assert(imported == 3 && repeated == 0 && preserved == original)
        assert(store.entries.count == 3 && store.entries.contains { $0.marker == "@revoked" })
        assert(store.entries.contains { $0.marker == "@cert-authority" })
        assert(store.entries.contains { $0.hosts.hasPrefix("|1|") && $0.matches("host.invalid") })
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        assert(mode?.intValue == 0o600)
        let backup = try store.remove([store.entries[0].id])
        assert(FileManager.default.fileExists(atPath: backup.path))
        assert(store.entries.count == 2)
        let afterRemoval = try Data(contentsOf: source)
        assert(afterRemoval == original)
        var profile = SessionProfile(); profile.user = "tester"
        let options = try SSHNetworking.transportArguments(profile, knownHostsFile: file)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = options + ["-G", "host.invalid"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let config = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        assert(process.terminationStatus == 0)
        assert(config.contains("userknownhostsfile " + file.path))
        assert(config.contains("globalknownhostsfile /dev/null"))
        let link = directory.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        do { try KnownHostsStore.prepare(file: link); fatalError("Host-key symlinks must be rejected") }
        catch is POSIXError {}
    }
    @MainActor func testSwitchToIdentityDoesNotRequireOldKeychainPassword() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        var profile = SessionProfile()
        profile.host = "example.invalid"; profile.user = "tester"
        profile.savePassword = true; profile.authentication = .password
        try store.save([profile])
        let credentials = LockedCredentials()
        let model = AppModel(store: store, keychain: credentials)
        profile.authentication = .identityFile; profile.identityFile = "/tmp/test-key"
        // Keep the stale flag from the saved password profile.
        try model.save(profile, password: "", reuse: false)
        assert(credentials.accesses == 0)
        let loaded = try store.load()
        assert(loaded.first?.authentication == .identityFile)
    }
    @MainActor func testDragMoveAndFavoritePersist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        var p = SessionProfile(); p.host = "example.invalid"; p.user = "tester"
        try store.save([p])
        let model = AppModel(store: store, keychain: LockedCredentials())
        assert(model.dropSessions(["muty-session:" + p.id.uuidString], into: "Prod/DB"))
        assert(!model.dropSessions([UUID().uuidString], into: "Bad"))
        model.toggleFavorite(p)
        let saved = try store.load()
        assert(saved[0].folder == "Prod/DB" && saved[0].favorite)
        model.toggleFavorite(saved[0])
        let removed = try store.load()
        assert(!removed[0].favorite)
        assert(model.dropSessions(["muty-session:" + p.id.uuidString], into: nil))
        let root = try store.load()
        assert(root[0].folder == nil)
        assert(model.profiles(in: nil).contains { $0.id == p.id })
        model.createFolder("Source/Empty")
        model.createFolder("Target")
        assert(model.dropSessions(["muty-session:" + p.id.uuidString], into: "Source"))
        assert(!model.dropSessions(["muty-folder:Source"], into: "Source/Empty"))
        assert(model.dropSessions(["muty-folder:Source"], into: "Target"))
        assert(model.folders.contains("Target/Source/Empty"))
        assert(!model.folders.contains("Source"))
        let moved = try store.load()
        assert(moved[0].id == p.id && moved[0].folder == "Target/Source")
        let savedFolders = try store.loadFolders()
        assert(savedFolders.contains("Target/Source/Empty"))
    }
    @MainActor func testCorruptProfilesAreNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ProfileStore(directory: directory)
        let broken = Data("{broken-json".utf8)
        try broken.write(to: store.file)
        let model = AppModel(store: store, keychain: LockedCredentials())
        assert(model.readOnly)
        var p = SessionProfile(); p.host = "example.invalid"; p.user = "tester"
        do { try model.save(p, password: "", reuse: false); fatalError("save must fail") } catch {}
        let actual = try Data(contentsOf: store.file)
        assert(actual == broken)
    }

    @MainActor func testRepeatedSaveAsNeverOverwritesProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(store: ProfileStore(directory: directory), keychain: LockedCredentials())
        var p = SessionProfile(); p.host = "example.invalid"; p.user = "tester"
        let connection = SSHConnection(profile: p, manual: true, temporary: true)
        model.saveTemporaryProfile(connection)
        guard let first = model.editing?.profile else { fatalError("missing draft") }
        try model.save(first, password: "", reuse: false)
        model.saveTemporaryProfile(connection)
        guard let second = model.editing?.profile else { fatalError("missing draft") }
        assert(first.id != second.id && second.id != connection.profile.id)
        assert(!second.savePassword)
        assert(model.profiles.count == 1)
    }

    @MainActor func testRealBrokerAndHelper() throws {
        let credentials = DisposableCredentials()
        let broker = AskpassBroker(credentials: credentials)
        let env = try broker.start(connectionID: UUID(), profileID: UUID())
        defer { broker.stop() }
        let path = env["MUTY_ASKPASS_SOCKET"]!
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("muty-askpass")
        func invoke(_ prompt: String, token: String? = nil) throws -> (Int32, Data) {
            let process = Process()
            process.executableURL = helper
            process.arguments = [prompt]
            var environment = ProcessInfo.processInfo.environment
            environment.merge(env) { _, new in new }
            environment["SSH_ASKPASS_PROMPT"] = ""
            if let token { environment["MUTY_ASKPASS_TOKEN"] = token }
            process.environment = environment
            let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            guard !process.isRunning else {
                process.terminate(); broker.stop(); process.waitUntilExit()
                throw MutyError("Broker helper timed out")
            }
            return (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile())
        }
        let invalid = try invoke("tester@localhost's password: ", token: "wrong")
        assert(invalid.0 != 0 && invalid.1.isEmpty && credentials.reads == 0)
        let passphrase = try invoke("Enter passphrase for key '/tmp/key': ")
        assert(passphrase.0 != 0 && passphrase.1.isEmpty && credentials.reads == 0)
        let first = try invoke("tester@localhost's password: ")
        assert(first.0 == 0 && first.1 == Data("throwaway-broker-secret\n".utf8))
        assert(credentials.reads == 1)
        let replay = try invoke("tester@localhost's password: ")
        assert(replay.0 != 0 && replay.1.isEmpty && credentials.reads == 1)
        broker.stop()
        assert(!FileManager.default.fileExists(atPath: path))
        assert(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
    }

    @MainActor func testBrokerRestartRevokesSocket() throws {
        let broker = AskpassBroker(credentials: LockedCredentials())
        defer { broker.stop() }
        var previous: String?
        var tokens = Set<String>()
        for _ in 0..<50 {
            let environment = try broker.start(connectionID: UUID(), profileID: UUID())
            if let previous { assert(!FileManager.default.fileExists(atPath: previous)) }
            let path = environment["MUTY_ASKPASS_SOCKET"]!
            assert(FileManager.default.fileExists(atPath: path))
            let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber
            assert(mode.intValue == 0o600)
            assert(tokens.insert(environment["MUTY_ASKPASS_TOKEN"]!).inserted)
            previous = path
        }
        broker.stop(); broker.stop()
        assert(!FileManager.default.fileExists(atPath: previous!))
    }

    func testRealVaultRoundTrip() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("muty-vault-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VaultStore(directory: directory)
        try store.initialize(masterPassword: nil)
        let id = UUID()
        defer { try? store.delete(id: id) }
        let absent = try store.read(id: id)
        assert(absent == nil)
        try store.write(id: id, password: "disposable-first")
        let first = try store.read(id: id)
        assert(first == "disposable-first")
        try store.write(id: id, password: "disposable-updated")
        let second = try store.read(id: id)
        assert(second == "disposable-updated")
        try store.delete(id: id)
        let deleted = try store.read(id: id)
        assert(deleted == nil)
        try store.delete(id: id)
    }

    @MainActor func testPTYSSH() throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["MUTY_TEST_PORT"], let fixtures = env["MUTY_TEST_FIXTURES"] else {
            throw MutyError("PTY test requires disposable stand")
        }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let observer = PTYObserver(); view.processDelegate = observer
        view.startProcess(executable: "/usr/bin/ssh", args: [
            "-F", "/dev/null", "-tt", "-p", port, "-i", fixtures + "/client",
            "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3",
            "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + fixtures + "/known_hosts",
            "tester@127.0.0.1", "test -t 0 && stty size && printf 'MUTY_PTY_OK Привет\\n'"
        ], environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color", "LC_ALL=en_US.UTF-8"])
        let pid = view.process.shellPid
        defer { if !observer.ended { view.terminate() } }
        let deadline = Date().addingTimeInterval(12)
        while !observer.ended && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard observer.ended else { throw MutyError("PTY SSH timeout") }
        // Allow ordered terminal data callbacks to finish after process exit.
        for _ in 0..<10 { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        let output = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
        guard observer.status == 0, output.contains("MUTY_PTY_OK Привет") else {
            throw MutyError("PTY SSH failed: status \(observer.status.map(String.init) ?? "nil")")
        }
        assert(pid > 0)
        assert(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @MainActor func testIsolatedHostKeyConnections() throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["MUTY_TEST_PORT"].flatMap(Int.init), let fixtures = env["MUTY_TEST_FIXTURES"] else {
            throw MutyError("Host-key integration requires the disposable stand")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("muty host integration " + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trusted = try String(contentsOfFile: fixtures + "/known_hosts", encoding: .utf8)
        let source = KnownHostsStore(file: URL(fileURLWithPath: fixtures + "/known_hosts"))
        guard let first = source.entries.first else { throw MutyError("Missing test host key") }
        let line = trusted.components(separatedBy: "\n")[first.id]
        let fields = line.split(whereSeparator: \.isWhitespace)
        let actualKey = fields.dropFirst().joined(separator: " ")
        let wrongKeyFile = directory.appendingPathComponent("wrong")
        let generate = Process()
        generate.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        generate.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", wrongKeyFile.path]
        try generate.run(); generate.waitUntilExit()
        guard generate.terminationStatus == 0 else { throw MutyError("Test key generation failed") }
        let wrongKey = try String(contentsOf: wrongKeyFile.appendingPathExtension("pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for scenario in ["direct", "jump", "changedTarget", "changedJump"] {
            let throughJump = scenario != "direct"
            let file = directory.appendingPathComponent(scenario + "/known_hosts")
            try KnownHostsStore.prepare(file: file)
            let jumpKey = scenario == "changedJump" ? wrongKey : actualKey
            let targetKey = scenario == "changedTarget" ? wrongKey : actualKey
            try Data(("[127.0.0.1]:\(port) \(jumpKey)\n127.0.0.1 \(targetKey)\n").utf8).write(to: file)
            var jump = SessionProfile()
            jump.host = "127.0.0.1"; jump.port = port; jump.user = "tester"
            jump.authentication = .identityFile; jump.identityFile = fixtures + "/client"
            var target = jump
            target.id = UUID(); target.sftpEnabled = true
            if throughJump { target.port = 22; target.jumpHostID = jump.id }
            let connection = SSHConnection(profile: target, manual: false, knownHostsFile: file, sshOptions: ["-v"])
            connection.resolveJumpProfile = { _ in jump }
            defer {
                connection.disconnect()
                UserDefaults.standard.removeObject(forKey: "sftp-local-" + target.id.uuidString)
                UserDefaults.standard.removeObject(forKey: "sftp-remote-" + target.id.uuidString)
            }
            connection.start()
            let rejected = scenario.hasPrefix("changed")
            let deadline = Date().addingTimeInterval(12)
            while connection.running && !connection.transportReady && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            if rejected {
                let output = String(decoding: connection.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
                guard !connection.running, !connection.transportReady,
                      output.contains("HOST IDENTIFICATION HAS CHANGED") || output.contains("Host key verification failed") else {
                    throw MutyError("Changed host key was not rejected: " + scenario)
                }
            } else {
                guard connection.transportReady else {
                    let output = String(decoding: connection.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
                    throw MutyError("Isolated host-key SSH failed: \(scenario); \(connection.error ?? connection.status); \(output.suffix(3000))")
                }
                let app = AppModel(store: ProfileStore(directory: directory.appendingPathComponent(scenario + "/profile")), keychain: LockedCredentials())
                connection.openFileBrowser(app: app)
                let sftpDeadline = Date().addingTimeInterval(10)
                while connection.fileBrowser?.remotePath.isEmpty == true && connection.fileBrowser?.error == nil && Date() < sftpDeadline {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
                }
                guard let browser = connection.fileBrowser, !browser.remotePath.isEmpty, browser.error == nil else {
                    throw MutyError("SFTP over isolated host-key SSH failed: " + scenario)
                }
            }
            connection.disconnect()
        }
        guard try String(contentsOfFile: fixtures + "/known_hosts", encoding: .utf8) == trusted else {
            throw MutyError("Source known_hosts was modified")
        }
    }

    @MainActor func testFullPasswordConnection(wrongPassword: Bool = false) throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["MUTY_TEST_PORT"].flatMap(Int.init), let fixtures = env["MUTY_TEST_FIXTURES"] else {
            throw MutyError("Full connection test requires disposable stand")
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("muty-auth-vault-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VaultStore(directory: directory)
        try store.initialize(masterPassword: nil)
        var profile = SessionProfile()
        profile.host = "127.0.0.1"; profile.port = port; profile.user = "tester"
        profile.authentication = .password; profile.savePassword = true
        let password = try String(contentsOfFile: fixtures + "/password", encoding: .utf8)
        try store.write(id: profile.id, password: wrongPassword ? "deliberately-wrong-test-password" : password)
        defer { try? store.delete(id: profile.id) }
        let connection = SSHConnection(profile: profile, manual: false, credentials: store,
            knownHostsFile: URL(fileURLWithPath: fixtures + "/known_hosts"))
        defer { connection.disconnect() }
        connection.terminal.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        connection.start()
        let pid = connection.terminal.process.shellPid
        guard pid > 0 else { throw MutyError("SSHConnection failed to launch") }
        if wrongPassword {
            let application = NSApplication.shared
            var cancelledRetry = false
            let cancelRetry = Timer(timeInterval: 0.02, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let panel = application.modalWindow as? NativeSSHPasswordPanel else { return }
                    cancelledRetry = true
                    panel.cancel(nil)
                }
            }
            RunLoop.main.add(cancelRetry, forMode: .modalPanel)
            defer { cancelRetry.invalidate() }
            let deadline = Date().addingTimeInterval(10)
            while connection.running && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            guard cancelledRetry, !connection.running else {
                throw MutyError("Wrong saved password did not prompt for a retry and exit after cancellation")
            }
            assert(kill(pid, 0) == -1 && errno == ESRCH)
            return
        }
        // Input waits in the remote shell's PTY until authentication completes.
        connection.terminal.send(txt: "printf 'MUTY_FULL_CHAIN_OK\\n'\n")
        let deadline = Date().addingTimeInterval(12)
        var succeeded = false
        while connection.running && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            let text = String(decoding: connection.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
            // Marker alone is echoed before auth. Require a separate output line.
            if text.components(separatedBy: "\n").contains(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == "MUTY_FULL_CHAIN_OK"
            }) { succeeded = true; break }
        }
        guard succeeded else { throw MutyError("Full password chain did not produce command output: \(connection.status)") }
        connection.disconnect()
        let cleanupDeadline = Date().addingTimeInterval(4)
        while Date() < cleanupDeadline && kill(pid, 0) == 0 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        assert(!connection.running)
        assert(kill(pid, 0) == -1 && errno == ESRCH)
        assert(connection.status == "Disconnected")
    }

    @MainActor func testLifecycleStress() throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["MUTY_TEST_PORT"].flatMap(Int.init), let fixtures = env["MUTY_TEST_FIXTURES"] else {
            throw MutyError("Lifecycle test requires stand")
        }
        var profile = SessionProfile()
        profile.host = "127.0.0.1"; profile.port = port; profile.user = "tester"
        profile.authentication = .identityFile; profile.identityFile = fixtures + "/client"
        var connections: [SSHConnection] = []
        var pids: [pid_t] = []
        defer { connections.forEach { $0.disconnect() } }
        for _ in 0..<12 {
            let c = SSHConnection(profile: profile, manual: false,
                knownHostsFile: URL(fileURLWithPath: fixtures + "/known_hosts"))
            connections.append(c)
            c.start()
            let pid = c.terminal.process.shellPid
            guard pid > 0 else { throw MutyError("Lifecycle child did not start") }
            pids.append(pid)
            c.disconnect(); c.disconnect()
        }
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline && pids.contains(where: { kill($0, 0) == 0 }) {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        assert(connections.allSatisfy { !$0.running && $0.status == "Disconnected" })
        assert(pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH })
        // A subsequent session must still authenticate after cancellation stress.
        try testPTYSSH()
    }

    @MainActor func testAuthCancellationAndParallelSessions() throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["MUTY_TEST_PORT"].flatMap(Int.init), let fixtures = env["MUTY_TEST_FIXTURES"] else {
            throw MutyError("Parallel test requires stand")
        }
        let knownHosts = URL(fileURLWithPath: fixtures + "/known_hosts")
        var profile = SessionProfile()
        profile.host = "127.0.0.1"; profile.port = port; profile.user = "tester"
        profile.authentication = .password
        let waiting = SSHConnection(profile: profile, manual: true, knownHostsFile: knownHosts)
        profile.authentication = .identityFile; profile.identityFile = fixtures + "/client"
        let first = SSHConnection(profile: profile, manual: false, knownHostsFile: knownHosts)
        let second = SSHConnection(profile: profile, manual: false, knownHostsFile: knownHosts)
        let all = [waiting, first, second]
        defer { all.forEach { $0.disconnect() } }
        all.forEach { $0.start() }
        let pids = all.map { $0.terminal.process.shellPid }
        func output(_ c: SSHConnection) -> String {
            String(decoding: c.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
        }
        func wait(_ predicate: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while !predicate() && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return predicate()
        }
        first.terminal.send(txt: "printf 'PARALLEL_ONE\\n'\n")
        second.terminal.send(txt: "printf 'PARALLEL_TWO\\n'\n")
        func marker(_ c: SSHConnection, _ value: String) -> Bool {
            output(c).components(separatedBy: "\n").contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == value
            }
        }
        guard wait({ output(waiting).contains("password:") && marker(first, "PARALLEL_ONE") && marker(second, "PARALLEL_TWO") }) else {
            throw MutyError("Parallel/auth-prompt setup failed")
        }
        waiting.disconnect(); first.disconnect()
        guard wait({ kill(pids[0], 0) == -1 && kill(pids[1], 0) == -1 }) else {
            throw MutyError("Cancelled sessions leaked processes")
        }
        assert(second.running)
        second.terminal.send(txt: "printf 'STILL_ALIVE\\n'\n")
        guard wait({ marker(second, "STILL_ALIVE") }) else { throw MutyError("Neighbor session was disrupted") }
        second.terminal.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        let terminal = second.terminal.getTerminal()
        second.terminal.send(txt: "stty size; printf 'RESIZE_DONE\\n'\n")
        guard wait({ marker(second, "RESIZE_DONE") }) else { throw MutyError("Resize command stalled") }
        let expectedSize = "\(terminal.rows) \(terminal.cols)"
        assert(output(second).contains(expectedSize))
        second.terminal.send(txt: "sleep 30\n")
        let pause = Date().addingTimeInterval(0.3)
        while Date() < pause { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        second.terminal.send(txt: "\u{3}")
        second.terminal.send(txt: "printf 'CTRL_C_OK\\n'\n")
        guard wait({ marker(second, "CTRL_C_OK") }) else { throw MutyError("Ctrl-C did not restore shell input") }
        second.terminal.send(txt: "seq 1 5000; printf 'FLOOD_DONE\\n'\n")
        guard wait({ marker(second, "FLOOD_DONE") }) else { throw MutyError("Output flood stalled") }
        second.terminal.send(txt: "vim -Nu NONE -n /tmp/muty-vim-check\n")
        guard wait({ second.terminal.getTerminal().isCurrentBufferAlternate }) else { throw MutyError("vim did not open alternate screen") }
        second.terminal.send(txt: "iPTY_VIM_TEXT")
        guard wait({ output(second).contains("PTY_VIM_TEXT") }) else { throw MutyError("vim did not accept text") }
        second.terminal.send(txt: "\u{1b}")
        second.terminal.send(txt: ":wq\n")
        guard wait({ !second.terminal.getTerminal().isCurrentBufferAlternate }) else { throw MutyError("vim did not return to shell") }
        second.terminal.send(txt: "grep -qx PTY_VIM_TEXT /tmp/muty-vim-check && printf 'VIM_OK\\n'\n")
        guard wait({ marker(second, "VIM_OK") }) else { throw MutyError("vim saved text verification failed") }
        second.terminal.send(txt: "top -d 1\n")
        let topPause = Date().addingTimeInterval(0.5)
        while Date() < topPause { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        second.terminal.send(txt: "q")
        second.terminal.send(txt: "printf 'TOP_EXIT_OK\\n'\n")
        guard wait({ marker(second, "TOP_EXIT_OK") }) else { throw MutyError("top exit failed") }
        second.terminal.send(txt: "printf 'PASTE_ONE\\n'\nprintf 'PASTE_TWO\\n'\n")
        guard wait({ marker(second, "PASTE_ONE") && marker(second, "PASTE_TWO") }) else { throw MutyError("multiline terminal input failed") }
        second.disconnect()
        guard wait({ kill(pids[2], 0) == -1 }) else { throw MutyError("Final child leaked") }
    }

    @MainActor func testServerTermination(blackhole: Bool = false) throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["MUTY_TEST_PORT"].flatMap(Int.init), let fixtures = env["MUTY_TEST_FIXTURES"],
              let container = env["MUTY_TEST_CONTAINER"], container.hasPrefix("muty-test-") else {
            throw MutyError("Network test requires disposable container")
        }
        var profile = SessionProfile()
        profile.host = "127.0.0.1"; profile.port = port; profile.user = "tester"
        profile.authentication = .identityFile; profile.identityFile = fixtures + "/client"
        let c = SSHConnection(profile: profile, manual: false,
            knownHostsFile: URL(fileURLWithPath: fixtures + "/known_hosts"),
            sshOptions: ["-o", "ServerAliveInterval=1", "-o", "ServerAliveCountMax=2"])
        defer { c.disconnect() }
        c.start()
        let pid = c.terminal.process.shellPid
        c.terminal.send(txt: "printf 'NETWORK_READY\\n'\n")
        let deadline = Date().addingTimeInterval(10)
        var ready = false
        while c.running && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            let text = String(decoding: c.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
            if text.components(separatedBy: "\n").contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "NETWORK_READY" }) { ready = true; break }
        }
        guard ready else { throw MutyError("Network test did not authenticate") }
        let stop = Process()
        stop.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        stop.arguments = ["docker", blackhole ? "pause" : "kill", container]
        stop.standardOutput = FileHandle.nullDevice; stop.standardError = FileHandle.nullDevice
        try stop.run()
        let end = Date().addingTimeInterval(8)
        while (c.running || stop.isRunning) && Date() < end {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard !stop.isRunning, stop.terminationStatus == 0 else { throw MutyError("Could not stop disposable server") }
        assert(!c.running && c.error != nil)
        assert(pid > 0 && kill(pid, 0) == -1 && errno == ESRCH)
    }

    @MainActor func testManagedKeysPreserveEncryptionAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("encrypted-key")
        let generate = Process(); generate.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        generate.arguments = ["-q", "-t", "ed25519", "-N", "throwaway-test-passphrase", "-f", source.path]
        try generate.run(); generate.waitUntilExit(); assert(generate.terminationStatus == 0)
        let original = try Data(contentsOf: source)
        let library = SSHKeyLibrary(directory: directory.appendingPathComponent("library"))
        let imported = try library.add(file: source, copy: true)
        let stored = try library.path(for: imported.id)
        let actual = try Data(contentsOf: URL(fileURLWithPath: stored))
        assert(actual == original)
        let mode = try FileManager.default.attributesOfItem(atPath: stored)[.posixPermissions] as! NSNumber
        assert(mode.intValue == 0o600)
        let reloaded = SSHKeyLibrary(directory: library.directory)
        assert(reloaded.keys.count == 1 && reloaded.keys[0].fingerprint.hasPrefix("SHA256:"))
        var profile = SessionProfile(); profile.host = "example.invalid"; profile.user = "qa"
        profile.authentication = .identityFile; profile.keyID = imported.id
        let validated = try profile.validated(); assert(validated.keyID == imported.id)
        try library.remove(imported)
        assert(!FileManager.default.fileExists(atPath: stored))
        assert(FileManager.default.fileExists(atPath: source.path))
        let reference = try library.add(file: source, copy: false)
        try library.remove(reference)
        let remaining = try Data(contentsOf: source); assert(remaining == original)
        do { _ = try library.add(file: source.appendingPathExtension("pub"), copy: true); fatalError("public key accepted") } catch {}
    }

    func testQuickAddressAndPasteSafety() throws {
        let address = try ConnectionAddress.parse("ops@example.invalid:2222", defaultUser: "default", defaultPort: 22)
        assert(address.user == "ops" && address.host == "example.invalid" && address.port == 2222)
        let ipv6 = try ConnectionAddress.parse("ops@[::1]:2200", defaultUser: "default", defaultPort: 22)
        assert(ipv6.host == "::1" && ipv6.port == 2200)
        for input in ["user@@host", "host:bad", "host:70000", "[::1", "-oBad"] {
            do { _ = try ConnectionAddress.parse(input, defaultUser: "qa", defaultPort: 22); fatalError("Invalid address accepted") } catch {}
        }
        assert(!PasteSafety.needsConfirmation("echo safe"))
        assert(PasteSafety.needsConfirmation("echo one\necho two"))
        assert(PasteSafety.needsConfirmation("echo run\r"))
        var p = SessionProfile(); p.color = "Red"
        let decoded = try JSONDecoder().decode(SessionProfile.self, from: JSONEncoder().encode(p))
        assert(decoded.color == "Red")
    }

    func testLegacyProfilePreservesPasswordMode() throws {
        let json = "{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"old\",\"host\":\"example.invalid\",\"port\":22,\"user\":\"tester\",\"savePassword\":true}"
        let profile = try JSONDecoder().decode(SessionProfile.self, from: Data(json.utf8))
        assert(profile.authentication == .password)
        assert(!profile.favorite)
    }
    func testFavoriteRowIdentityIsDistinct() {
        let id = UUID()
        let tree = SessionRowID(profileID: id, location: .sessions)
        let favorite = SessionRowID(profileID: id, location: .favorites)
        assert(tree != favorite)
        assert(tree.profileID == favorite.profileID)
        assert(Set([tree, favorite]).count == 2)
    }
    @MainActor func testButtonSetsMigrationAndBackup() throws {
        let suite = "muty-button-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var legacy = SendStringButton()
        legacy.title = "Status"; legacy.string = "uptime\\r"
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "sendStringButtons")
        let store = SendStringButtonStore(defaults: defaults)
        assert(store.document.buttons.count == 1 && store.document.buttons[0].setID == nil)
        let set = try store.saveSet(name: "Linux")
        try store.assign(set, to: "Prod")
        assert(store.assignedSet(for: "Prod/DB") == set)
        legacy.setID = set; legacy.confirm = true; legacy.color = "Orange"
        try store.save(legacy)
        try store.duplicate(legacy)
        let copy = store.document.buttons[1]
        assert(copy.id != legacy.id && copy.confirm == true && copy.setID == set)
        let moved = try store.move(copy.id, before: legacy.id)
        assert(moved)
        assert(store.document.buttons.first?.id == copy.id)
        let document = try store.snapshot()
        let backup = FullBackup(configuration: ConfigurationBackup(sessions: [], folders: [], buttonBar: document), passwords: [])
        let decoded = try BackupArchive.decode(BackupArchive.encode(backup, masterPassword: nil))
        assert(decoded.buttonBar?.buttons.count == 2 && decoded.buttonBar?.folderSets["Prod"] == set)
        let movedFolders = try store.movingFolders(["Prod": "Archive/Prod"])
        try store.replace(movedFolders)
        assert(store.assignedSet(for: "Prod") == nil)
        assert(store.assignedSet(for: "Archive/Prod/DB") == set)
        let corruptData = Data("invalid-json".utf8)
        defaults.set(corruptData, forKey: "buttonBarDocument")
        let damaged = SendStringButtonStore(defaults: defaults)
        assert(damaged.loadError != nil)
        let checkpoint = damaged.checkpoint()
        try damaged.restore(document)
        assert(damaged.loadError == nil && damaged.document.buttons.count == 2)
        damaged.rollback(checkpoint)
        assert(damaged.loadError != nil && defaults.data(forKey: "buttonBarDocument") == corruptData)
        try damaged.restore(document)
        let reloaded = SendStringButtonStore(defaults: defaults)
        assert(reloaded.document.buttons.first?.id == copy.id)
        try store.removeSet(set)
        assert(store.document.buttons.allSatisfy { $0.setID == nil })
        assert(store.assignedSet(for: "Prod/DB") == nil)
    }
    @MainActor func testCurrentFolderAndAtomicProfileSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        var profile = SessionProfile()
        profile.host = "example.invalid"; profile.user = "tester"; profile.folder = "Prod"
        try store.save([profile])
        let model = AppModel(store: store, keychain: LockedCredentials())
        let connection = SSHConnection(profile: profile, manual: true, deferredStart: true)
        model.move(profile, to: nil)
        assert(model.currentFolder(for: connection) == nil)
        model.move(profile, to: "Archive/Prod")
        assert(model.currentFolder(for: connection) == "Archive/Prod")
        let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int
        assert(permissions == 0o600)
        let original = try Data(contentsOf: store.file)
        let blocked = ProfileStore(directory: directory.appendingPathComponent("blocked"))
        try FileManager.default.createDirectory(at: blocked.file, withIntermediateDirectories: true)
        let marker = blocked.file.appendingPathComponent("marker")
        try original.write(to: marker)
        do {
            try blocked.save([profile])
            fatalError("Replacing a directory must fail")
        } catch is POSIXError {}
        let preserved = try Data(contentsOf: marker)
        assert(preserved == original)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: blocked.directory.path)
        assert(!leftovers.contains(where: { $0.hasPrefix(".profiles-") }))
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        assert(!contents.contains(where: { $0.hasPrefix(".profiles-") }))
        assert(!original.isEmpty)
    }
    func testFolderCanonicalization() {
        assert(SessionProfile.canonicalFolder(" / Prod // DB / ") == "Prod/DB")
        assert(SessionProfile.canonicalFolder("///") == nil)
    }
    func testMobaXtermSessions() throws {
        let export = [
            "[Bookmarks]", "SubRep=", "ImgNum=42",
            "Root=#109#0%root.example%22%operator",
            "[Bookmarks_1]", "SubRep=Prod\\DB",
            "Database=#109#0%db.example%2222%",
            "Desktop=#91#4%desktop.example%3389%operator",
            "Bad port=#109#0%broken.example%70000%operator"
        ].joined(separator: "\r\n")
        let preview = try MobaXtermImport.parse(export)
        assert(preview.folders == ["Prod/DB"])
        assert(preview.sessions.count == 2 && preview.skipped == 2)
        assert(preview.sessions[0].folder == nil && preview.sessions[0].user == "operator")
        assert(preview.sessions[1].folder == "Prod/DB" && preview.sessions[1].user.isEmpty)
        assert(preview.sessions[1].host == "db.example" && preview.sessions[1].port == 2222)
        assert(preview.sessions.allSatisfy { !$0.savePassword && $0.credentialID == nil })
    }
    func testInvalidEndpointRejected() {
        var p = SessionProfile(); p.host = "-oProxyCommand=bad"; p.user = "tester"
        do { _ = try p.validated(); fatalError("Expected validation failure") } catch {}
    }
}

@main struct Runner {
    @MainActor static func main() throws {
        let tests = RegressionTests()
        if CommandLine.arguments.dropFirst().first == "integration.isolatedHostKeys" {
            try tests.testIsolatedHostKeyConnections()
            print("PASS isolated host keys: direct/jump SSH and SFTP, changed target/jump rejection")
            return
        }
        let cases: [(String, () throws -> Void)] = [
            ("hosts.independentStorageAndImport", tests.testIndependentKnownHosts),
            ("profiles.legacy", tests.testLegacyProfilePreservesPasswordMode),
            ("ui.quickAddressPasteAndColor", tests.testQuickAddressAndPasteSafety),
            ("profiles.folderCanonicalization", tests.testFolderCanonicalization),
            ("profiles.currentFolderAndAtomicSave", tests.testCurrentFolderAndAtomicProfileSave),
            ("buttons.setsMigrationAndBackup", tests.testButtonSetsMigrationAndBackup),
            ("sessions.importMobaXterm", tests.testMobaXtermSessions),
            ("profiles.rejectInvalidEndpoint", tests.testInvalidEndpointRejected),
            ("credentials.switchToKeyWithLockedKeychain", tests.testSwitchToIdentityDoesNotRequireOldKeychainPassword),
            ("sessions.dragAndFavoritesPersistence", tests.testDragMoveAndFavoritePersist),
            ("sessions.distinctFavoriteRowIdentity", tests.testFavoriteRowIdentityIsDistinct),
            ("profiles.corruptionPreservesFile", tests.testCorruptProfilesAreNotOverwritten),
            ("credentials.saveAsNeverOverwrites", tests.testRepeatedSaveAsNeverOverwritesProfile),
            ("ipc.realBrokerHelperSingleUseAndCleanup", tests.testRealBrokerAndHelper),
            ("ipc.restartRevokesSocketAndCapability", tests.testBrokerRestartRevokesSocket),
            ("keys.encryptedImportReferenceAndPermissions", tests.testManagedKeysPreserveEncryptionAndPermissions)
        ]
        if CommandLine.arguments.dropFirst().first == "integration.blackhole" {
            try tests.testServerTermination(blackhole: true)
            print("PASS silent transport loss via paused test server and accelerated keepalive"); return
        }
        if CommandLine.arguments.dropFirst().first == "integration.parallel" {
            try tests.testAuthCancellationAndParallelSessions()
            print("PASS auth-prompt cancellation and parallel session isolation"); return
        }
        if CommandLine.arguments.dropFirst().first == "integration.lifecycle" {
            try tests.testLifecycleStress(); print("PASS 12 immediate/double disconnect cycles and fresh login"); return
        }
        if CommandLine.arguments.dropFirst().first == "integration.serverTermination" {
            try tests.testServerTermination(); print("PASS server termination detected and child reaped"); return
        }
        if CommandLine.arguments.dropFirst().first == "integration.fullWrongPassword" {
            try tests.testFullPasswordConnection(wrongPassword: true)
            print("PASS wrong-password SSHConnection exits without orphan"); return
        }
        if CommandLine.arguments.dropFirst().first == "integration.fullPassword" {
            try tests.testFullPasswordConnection(); print("PASS full SSHConnection password chain and disconnect"); return
        }
        if CommandLine.arguments.dropFirst().first == "integration.ptySSH" {
            try tests.testPTYSSH(); return
        }
        if CommandLine.arguments.dropFirst().first == "integration.realVault" {
            try tests.testRealVaultRoundTrip(); print("PASS isolated password-vault CRUD"); return
        }
        if CommandLine.arguments.dropFirst().first == "--list" {
            cases.forEach { print($0.0) }; return
        }
        guard let name = CommandLine.arguments.dropFirst().first,
              let test = cases.first(where: { $0.0 == name }) else {
            throw MutyError("Unknown or missing test case")
        }
        try test.1()
    }
}
