import AppKit
import Darwin
import MutyIPC

// Immutable descriptor ownership; shutdown is safe concurrently with socket IO.
private final class SocketClient: @unchecked Sendable {
    let fd: Int32
    let id = UUID()
    init(_ fd: Int32) {
        self.fd = fd
        Wire.configure(fd)
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
    }
    deinit { Darwin.close(fd) }
    func cancel() { _ = Darwin.shutdown(fd, SHUT_RDWR) }
}

// All broker state lives on the main queue. Only bounded socket IO runs off-main.
@MainActor
final class AskpassBroker {
    private var source: DispatchSourceRead?
    private var expiry: DispatchWorkItem?
    private var directory: String?
    private var clients: [UUID: SocketClient] = [:]
    private var token = ""
    private var connection = ""
    private var profileID = UUID()
    private var passwordAttempts = 0
    private var suppliedSavedPassword = false
    private var lastHostKeyQuestion: String?
    private var active = false
    var useSavedPassword = true
    var interactivePrompt: ((String, Bool, Bool) -> String?)?
    var onError: ((String) -> Void)?
    private let credentials: any CredentialStore

    init(credentials: any CredentialStore = VaultStore.shared) {
        self.credentials = credentials
    }

    func start(connectionID: UUID, profileID: UUID) throws -> [String: String] {
        stop()
        let dir = "/tmp/muty-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let path = dir + "/a"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { try? FileManager.default.removeItem(atPath: dir); throw MutyError("Could not create the ASKPASS socket.") }
        Wire.configure(fd)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        do {
            var addr = try Wire.address(path)
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard rc == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else { throw Wire.Failure.io }
        } catch {
            close(fd); try? FileManager.default.removeItem(atPath: dir)
            throw MutyError("Could not start the ASKPASS socket.")
        }
        directory = dir
        token = UUID().uuidString + UUID().uuidString
        connection = connectionID.uuidString
        self.profileID = profileID
        passwordAttempts = 0; suppliedSavedPassword = false
        lastHostKeyQuestion = nil; active = true
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        reader.setEventHandler { [weak self] in self?.acceptClients(listener: fd) }
        reader.setCancelHandler { Darwin.close(fd) }
        source = reader; reader.resume()
        let timeout = DispatchWorkItem { [weak self] in self?.stop() }
        expiry = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: timeout)
        return ["MUTY_ASKPASS_SOCKET": path, "MUTY_ASKPASS_TOKEN": token,
                "MUTY_ASKPASS_CONNECTION": connection]
    }

    private func acceptClients(listener: Int32) {
        while active {
            let fd = accept(listener, nil, nil)
            if fd < 0 { break }
            var uid: uid_t = 0; var gid: gid_t = 0
            guard clients.count < 8, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); continue }
            let client = SocketClient(fd)
            clients[client.id] = client
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let request = try? Wire.receive(AskpassRequest.self, fd: fd)
                DispatchQueue.main.async {
                    guard let self else { client.cancel(); return }
                    let response = request.map { self.respond($0) } ?? AskpassResponse(accepted: false)
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? Wire.send(response, fd: fd)
                        client.cancel()
                        DispatchQueue.main.async { self.clients.removeValue(forKey: client.id) }
                    }
                }
            }
        }
    }

    private func respond(_ request: AskpassRequest) -> AskpassResponse {
        guard active, request.token == token, request.connection == connection else { return .init(accepted: false) }
        let initial = HostKeyQuestion.isInitial(request.prompt)
        if (initial || HostKeyQuestion.isRetry(request.prompt)) && (request.kind.isEmpty || request.kind == "confirm") {
            if initial { lastHostKeyQuestion = request.prompt }
            let alert = NSAlert()
            alert.messageText = L("Trust Server Key?")
            alert.informativeText = L("Verify the server fingerprint before trusting this host.") + "\n\n" + (lastHostKeyQuestion ?? L("The fingerprint is displayed in the SSH terminal output."))
            alert.addButton(withTitle: L("Trust and Connect"))
            alert.addButton(withTitle: L("Cancel"))
            let approved = alert.runModal() == .alertFirstButtonReturn
            return .init(accepted: active && approved, value: approved ? "yes" : "no")
        }
        guard request.kind.isEmpty else { return .init(accepted: false) }
        let passwordPrompt = request.prompt.range(of: #"^[^\r\n]+@[^\r\n]+'s password: ?$"#, options: .regularExpression) != nil
        if passwordPrompt && passwordAttempts >= 3 { return .init(accepted: false) }
        if passwordPrompt { passwordAttempts += 1 }
        do {
            if passwordPrompt && passwordAttempts == 1 && useSavedPassword, let secret = try credentials.read(id: profileID) {
                suppliedSavedPassword = true
                return .init(accepted: true, value: secret)
            }
            guard let secret = interactivePrompt?(request.prompt, passwordPrompt, suppliedSavedPassword), active else {
                return .init(accepted: false)
            }
            return .init(accepted: true, value: secret)
        } catch {
            onError?(error.localizedDescription)
            return .init(accepted: false)
        }
    }

    func stop() {
        active = false; token = ""
        expiry?.cancel(); expiry = nil
        source?.cancel(); source = nil
        for client in clients.values { client.cancel() }
        clients.removeAll()
        if let directory { try? FileManager.default.removeItem(atPath: directory) }
        directory = nil
    }
}
