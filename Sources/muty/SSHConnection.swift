import AppKit
import SwiftUI
import Combine
import SwiftTerm
import Darwin

@MainActor
final class SSHConnection: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    nonisolated static let cleanup = DispatchGroup()
    let id = UUID()
    let transferQueueID: UUID
    @Published var profile: SessionProfile
    private(set) var connectedJumpProfile: SessionProfile?
    var resolveJumpProfile: ((UUID) throws -> SessionProfile)?
    var onSaveJumpPassword: ((SessionProfile, String) throws -> Void)?
    private var jumpBroker: AskpassBroker?
    private var proxyDirectory: URL?
    var onSavePassword: ((String) throws -> Void)?
    @Published var tabName: String?
    @Published var buttonBarSelection: ButtonBarSelection?
    let manual: Bool
    let temporary: Bool
    private let deferredStart: Bool
    private(set) var ignoreSavedPassword: Bool
    private var targetReceipt: SSHAuthenticationReceipt?
    private var jumpReceipt: SSHAuthenticationReceipt?
    private var pendingTargetPassword: (() throws -> Void)?
    private var pendingJumpPassword: (() throws -> Void)?
    @Published var showingSFTP = false { didSet { if !showingSFTP { onTerminalShown?() } } }
    @Published private(set) var fileBrowser: SFTPBrowserModel?
    private var tunnelObservation: AnyCancellable?
    @Published private(set) var activeTunnels: ActiveTunnelManager? {
        didSet { tunnelObservation = activeTunnels?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() } }
    }
    @Published private(set) var canOpenSFTP = false
    var transportReady: Bool { sharedTransport?.isReady == true }
    private var sharedTransport: SSHSharedTransport?
    @Published private(set) var status = "Not Started"
    @Published private(set) var negotiatedCipher: String?
    @Published private(set) var running = false
    @Published private(set) var error: String?
    @Published private(set) var remoteTitle: String?
    @Published var hasUnreadOutput = false
    var onTerminalOutput: (() -> Void)?
    var onTerminalShown: (() -> Void)?
    @Published private(set) var isLogging = false
    @Published private(set) var logURL: URL?
    private var outputLog: SessionOutputLog?
    private let startTime = Date()
    let terminal = ReconnectTerminalView(frame: .zero)
    private var broker: AskpassBroker?
    private var started = false
    private var stopping = false
    private var authenticationGeneration = UUID()
    private var childPID: pid_t = 0
    private var statusTimer: Timer?
    private let credentials: any CredentialStore
    private let sshOptions: [String]
    private let knownHostsFile: URL

    init(profile: SessionProfile, manual: Bool, temporary: Bool = false,
         credentials: any CredentialStore = VaultStore.shared, knownHostsFile: URL = SSHNetworking.knownHostsFile, sshOptions: [String] = [], deferredStart: Bool = false, ignoreSavedPassword: Bool = false, transferQueueID: UUID = UUID()) {
        self.transferQueueID = transferQueueID
        self.credentials = credentials
        self.sshOptions = sshOptions
        self.knownHostsFile = knownHostsFile
        self.profile = profile; self.manual = manual; self.temporary = temporary
        self.deferredStart = deferredStart
        self.ignoreSavedPassword = ignoreSavedPassword
        if deferredStart { status = "Restored" }
        super.init()
        terminal.processDelegate = self
        terminal.onOutput = { [weak self] data in
            guard let self, !data.isEmpty else { return }
            guard let log = self.outputLog else { return }
            do { try log.write(data) }
            catch { self.stopLogging(); self.error = "Logging stopped: " + error.localizedDescription }
        }
        terminal.onVisibleOutput = { [weak self] in self?.onTerminalOutput?() }
        terminal.optionAsMetaKey = UserDefaults.standard.object(forKey: "optionAsMetaKey") as? Bool ?? true
        applyColorScheme(TerminalColorScheme.resolve(profile.terminalTheme ?? UserDefaults.standard.string(forKey: "terminalTheme") ?? TerminalColorScheme.mutyDark.rawValue))
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    static func localShellHostName() -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN))
        guard gethostname(&buffer, buffer.count) == 0 else { return "Local Shell" }
        let hostname = String(cString: buffer)
        return hostname.isEmpty ? "Local Shell" : hostname
    }

    func start() {
        guard !started, !stopping, !deferredStart else { return }
        started = true
        do {
            var p = try profile.validated()
            if p.connectionType == .localShell {
                if tabName == nil && profile.name == "Local Shell" { tabName = Self.localShellHostName() }
                try startLocalShell()
                return
            }
            if p.authentication == .identityFile, let keyID = p.keyID {
                p.identityFile = try SSHKeyLibrary().path(for: keyID)
            }
            try KnownHostsStore.prepare(file: knownHostsFile)
            var args = sshOptions + (try SSHNetworking.transportArguments(p, knownHostsFile: knownHostsFile))
            if p.authentication == .password {
                targetReceipt = try SSHAuthenticationReceipt()
                args = targetReceipt!.arguments + args
            }
            args += (p.tunnelOnly || !p.sshEnabled) ? ["-N", "-T"] : ["-tt"]
            var env = ProcessInfo.processInfo.environment
            for key in Array(env.keys) where key.hasPrefix("MUTY_ASKPASS_") || key.hasPrefix("SSH_ASKPASS") {
                env.removeValue(forKey: key)
            }
            env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
            let targetAuth = try askpassEnvironment(for: p, jump: false)
            env.merge(targetAuth) { _, new in new }
            if let jumpID = p.jumpHostID {
                guard let resolveJumpProfile else { throw MutyError("Jump host is unavailable.") }
                var jump = try resolveJumpProfile(jumpID).validated()
                guard jump.connectionType == .ssh, jump.id != p.id, jump.jumpHostID == nil else {
                    throw MutyError("Select one SSH jump host without another jump host.")
                }
                connectedJumpProfile = jump
                if jump.authentication == .identityFile, let keyID = jump.keyID {
                    jump.identityFile = try SSHKeyLibrary().path(for: keyID)
                }
                let jumpAuth = try askpassEnvironment(for: jump, jump: true)
                let destination = PortForward.address(p.host) + ":" + String(p.port)
                var jumpArgs = try SSHNetworking.transportArguments(jump, knownHostsFile: knownHostsFile) + ["-W", destination, "--", jump.host]
                if jump.authentication == .password {
                    jumpReceipt = try SSHAuthenticationReceipt()
                    jumpArgs = jumpReceipt!.arguments + jumpArgs
                }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("muty-proxy-" + id.uuidString)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                proxyDirectory = dir
                let script = dir.appendingPathComponent("jump.sh")
                var contents = "#!/bin/sh\n"
                for (key, value) in jumpAuth.sorted(by: { $0.key < $1.key }) {
                    contents += "export " + key + "=" + SSHNetworking.quote(value) + "\n"
                }
                let proxyHelper = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
                    .deletingLastPathComponent().appendingPathComponent("muty-ssh-proxy").path
                guard FileManager.default.isExecutableFile(atPath: proxyHelper) else { throw MutyError("SSH proxy helper is missing. Rebuild muty.app.") }
                contents += "exec " + SSHNetworking.quote(proxyHelper) + " " + jumpArgs.map(SSHNetworking.quote).joined(separator: " ") + "\n"
                try Data(contents.utf8).write(to: script, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
                // ProxyCommand contains only our generated path; user data stays in the quoted launcher.
                args += ["-o", "ProxyCommand=/bin/sh " + SSHNetworking.quote(script.path).replacingOccurrences(of: "%", with: "%%")]
            }
            do {
                let transport = try SSHSharedTransport(profile: p)
                sharedTransport = transport
                args = transport.masterArguments + args
            }
            args += ["--", p.host]
            status = "Connecting"; running = true
            statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshStatus() }
            }
            terminal.startProcess(executable: "/usr/bin/ssh", args: args,
                                  environment: env.map { "\($0.key)=\($0.value)" },
                                  currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            childPID = terminal.process.shellPid
            if childPID <= 0 {
                broker?.stop(); broker = nil; stopJumpResources(); running = false
                throw MutyError("Could not start the system SSH process.")
            }
        } catch {
            discardPendingPasswords()
            releaseTransport()
            self.error = error.localizedDescription; status = "Start Failed"; running = false
            statusTimer?.invalidate(); statusTimer = nil
            broker?.stop(); broker = nil; stopJumpResources()
        }
    }

    func openFileBrowser(app: AppModel) {
        guard profile.connectionType == .ssh, profile.sftpEnabled, !profile.tunnelOnly,
              running, let transport = sharedTransport, transport.isReady else {
            showingSFTP = false
            app.errorMessage = "Wait for SSH authentication to finish, or reconnect first."
            return
        }
        if fileBrowser == nil {
            let args = transport.clientArguments() + ["-T", "-p", String(profile.port), "-l", profile.user, "-s", "--", profile.host, "sftp"]
            let queue = app.transferQueue(for: transferQueueID, endpoint: profile.endpoint, jump: connectedJumpProfile)
            fileBrowser = SFTPBrowserModel(client: SFTPClient(arguments: args), app: app, sessionID: profile.id, transferQueue: queue, endpoint: profile.endpoint, jumpEndpoint: connectedJumpProfile?.endpoint, temporary: temporary)
        }
        showingSFTP = true
        terminal.cancelPendingPaste()
        terminal.window?.makeFirstResponder(nil)
        fileBrowser?.start()
    }

    private func releaseTransport() {
        canOpenSFTP = false
        sharedTransport?.close()
        sharedTransport = nil
    }

    private func askpassEnvironment(for node: SessionProfile, jump: Bool) throws -> [String: String] {
        if manual { return ["SSH_ASKPASS_REQUIRE": "never"] }
        let helper = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("muty-askpass").path
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw MutyError("ASKPASS helper is missing.") }
        let server = AskpassBroker(credentials: credentials)
        let extra = try server.start(connectionID: jump ? UUID() : id, profileID: node.credentialID ?? node.id)
        server.useSavedPassword = node.authentication == .password && (node.savePassword || node.credentialID != nil) && !ignoreSavedPassword
        server.interactivePrompt = { [weak self] prompt, isPassword, replacingSavedPassword in
            guard let self else { return nil }
            // A new prompt means the preceding candidate was rejected.
            if jump { self.pendingJumpPassword = nil }
            else { self.pendingTargetPassword = nil }
            let save: ((String) throws -> Void)?
            if jump {
                if let handler = self.onSaveJumpPassword { save = { try handler(node, $0) } }
                else { save = nil }
            } else { save = self.onSavePassword }
            let stage: ((String) -> Void)? = save.map { action in
                { [weak self] secret in
                    if jump { self?.pendingJumpPassword = { try action(secret) } }
                    else { self?.pendingTargetPassword = { try action(secret) } }
                }
            }
            let replacing = self.ignoreSavedPassword || replacingSavedPassword
            return self.promptForSecret(prompt, allowSave: isPassword && node.authentication == .password,
                                        endpoint: node.endpoint, save: stage, canSave: jump || !self.temporary,
                                        replaceSaved: replacing && node.savePassword)

        }
        server.onError = { [weak self] message in
            guard let self, !self.stopping else { return }
            self.error = message
        }
        if jump { jumpBroker = server } else { broker = server }
        return extra.merging(["SSH_ASKPASS": helper, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": "muty:0", "LC_ALL": "C"]) { _, new in new }
    }

    private func stopJumpResources() {
        jumpBroker?.stop(); jumpBroker = nil
        if let directory = proxyDirectory { try? FileManager.default.removeItem(at: directory) }
        proxyDirectory = nil
    }

    private func promptForSecret(_ prompt: String, allowSave: Bool, endpoint: String,
                                 save saveAction: ((String) -> Void)?, canSave: Bool, replaceSaved: Bool) -> String? {
        let generation = authenticationGeneration
        let panel = NativeSSHPasswordPanel(endpoint: endpoint, prompt: allowSave ? "Password:" : prompt,
                                           canSave: allowSave && canSave && saveAction != nil, replaceSaved: replaceSaved)
        defer { panel.clearSecrets() }
        guard panel.run() == .OK, !stopping, generation == authenticationGeneration,
              let (secret, remember) = panel.result else { return nil }
        if remember { saveAction?(secret) }
        return secret
    }

    private func commitAuthenticatedPasswords() {
        if jumpReceipt?.authenticated == true, let action = pendingJumpPassword {
            pendingJumpPassword = nil
            do { try action() } catch { self.error = "Jump-host password was not saved: " + error.localizedDescription }
        }
        if targetReceipt?.authenticated == true, let action = pendingTargetPassword {
            pendingTargetPassword = nil
            do { try action(); ignoreSavedPassword = false }
            catch { self.error = "Password was not saved: " + error.localizedDescription }
        }
    }
    private func discardPendingPasswords() {
        pendingTargetPassword = nil; pendingJumpPassword = nil
        targetReceipt?.clear(); targetReceipt = nil
        jumpReceipt?.clear(); jumpReceipt = nil
    }

    private func startLocalShell() throws {
        let shell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) } ?? "/bin/zsh"
        guard shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else {
            throw MutyError("Your default shell is not executable: \(shell)")
        }
        let workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue, access(workingDirectory, R_OK | X_OK) == 0 else {
            throw MutyError("Working directory is unavailable or inaccessible: \(workingDirectory)")
        }
        var env = ProcessInfo.processInfo.environment
        for key in Array(env.keys) where key.hasPrefix("MUTY_ASKPASS_") || key.hasPrefix("SSH_ASKPASS") {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["USER"] = NSUserName(); env["LOGNAME"] = NSUserName(); env["SHELL"] = shell
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PWD"] = workingDirectory
        running = true; status = "Shell Running"
        terminal.startProcess(executable: shell, args: ["-l"],
                              environment: env.map { "\($0.key)=\($0.value)" },
                              currentDirectory: workingDirectory)
        childPID = terminal.process.shellPid
        guard childPID > 0 else { throw MutyError("Could not start the local shell.") }
    }

    func revokeAuthentication() {
        authenticationGeneration = UUID()
        discardPendingPasswords()
        broker?.stop(); broker = nil; stopJumpResources()
        if !started { stopping = true; status = "Settings Changed"; releaseTransport() }
    }

    func disconnect() {
        stopping = true
        if running { error = nil }
        fileBrowser?.disconnect()
        stopLogging()
        terminal.cancelPendingPaste()
        discardPendingPasswords()
        broker?.stop(); broker = nil; stopJumpResources()
        releaseTransport()
        guard running else { return }
        stopChildProcess()
        statusTimer?.invalidate(); statusTimer = nil
        running = false; status = profile.connectionType == .localShell ? "Shell Stopped" : "Disconnected"
        negotiatedCipher = nil
    }

    private func stopChildProcess() {
        let pid = childPID
        guard pid > 0 else { return }
        let ownsGroup = pid > 0 && getpgid(pid) == pid
        if ownsGroup { _ = kill(-pid, SIGHUP) }
        terminal.terminate()
        childPID = 0
        // Do not reap the leader before killing remaining group members: its PID
        // reserves the group ID while cleanup runs. terminate cancels SwiftTerm's monitor.
        Self.cleanup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { Self.cleanup.leave() }
            usleep(250_000)
            if ownsGroup { _ = kill(-pid, SIGKILL) }
            else { _ = kill(pid, SIGKILL) }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
    }

    func startLogging() {
        guard running, !isLogging else { return }
        let panel = NSSavePanel()
        panel.title = "Start Session Logging"
        let name = (tabName ?? profile.name).map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = String(name.prefix(80)) + "-" + timestamp + ".log"
        panel.message = "Records terminal output from now on, including ANSI escape sequences."
        guard panel.runModal() == .OK, let url = panel.url, running else { return }
        do { try beginLogging(to: url) }
        catch { self.error = "Cannot start logging: " + error.localizedDescription }
    }
    func beginLogging(to url: URL) throws {
        guard running, !isLogging else { throw MutyError("Start a session before enabling logging.") }
        outputLog = try SessionOutputLog(url: url)
        logURL = url; isLogging = true
    }
    func stopLogging() {
        do { try outputLog?.finish() }
        catch { self.error = "Cannot finish logging: " + error.localizedDescription }
        outputLog = nil; isLogging = false
    }
    func showLogFile() { if let logURL { NSWorkspace.shared.activateFileViewerSelecting([logURL]) } }

    func showFind() {
        let item = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        terminal.performFindPanelAction(item)
    }

    func setFontSize(_ size: Double) {
        let name = UserDefaults.standard.string(forKey: "terminalFontName") ?? ""
        let font = NSFont(name: name, size: CGFloat(size)) ?? .monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        guard terminal.font != font else { return }
        terminal.font = font
    }

    func setScrollback(_ lines: Int) {
        let bounded = max(1000, min(50000, lines))
        if terminal.getTerminal().options.scrollback != bounded {
            terminal.getTerminal().changeHistorySize(bounded)
        }
    }

    func setTheme(_ theme: String) {
        applyColorScheme(TerminalColorScheme.resolve(theme))
    }

    private func applyColorScheme(_ scheme: TerminalColorScheme) {
        terminal.nativeBackgroundColor = scheme.background
        terminal.nativeForegroundColor = scheme.foreground
        terminal.installColors(scheme.ansiColors)
    }

    func setOptionAsMeta(_ enabled: Bool) {
        terminal.optionAsMetaKey = enabled
    }

    private func refreshStatus() {
        guard running else { return }
        commitAuthenticatedPasswords()
        // A live child alone cannot prove SSH authentication. Do not infer success
        // by scanning shell prompts or remote-controlled terminal output.
        if activeTunnels == nil, let transport = sharedTransport, transport.isReady {
            if transport.tunnelManager == nil {
                transport.tunnelManager = ActiveTunnelManager(transport: transport, rules: profile.forwards)
                transport.tunnelManager?.startConfigured()
            }
            activeTunnels = transport.tunnelManager
        }
        canOpenSFTP = profile.sftpEnabled && !profile.tunnelOnly && transportReady
        if transportReady {
            negotiatedCipher = sharedTransport?.negotiatedCipher
            status = "Connected"
        }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { [weak self] in self?.remoteTitle = title }
    }
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in self?.didTerminate(exitCode: exitCode) }
    }

    private func didTerminate(exitCode: Int32?) {
        if let transport = sharedTransport {
            let diagnostics = transport.diagnosticOutput
            if !diagnostics.isEmpty { terminal.feed(byteArray: Array(diagnostics.utf8)[...]) }
        }
        negotiatedCipher = nil
        fileBrowser?.disconnect()
        // Keep the writer until Stop/Disconnect/tab close: SwiftTerm may deliver
        // queued PTY output after the child exit notification.
        terminal.cancelPendingPaste()
        if !stopping { commitAuthenticatedPasswords() }
        discardPendingPasswords()
        releaseTransport()
        broker?.stop(); broker = nil; stopJumpResources(); running = false; childPID = 0
        statusTimer?.invalidate(); statusTimer = nil
        guard !stopping else { status = profile.connectionType == .localShell ? "Shell Stopped" : "Disconnected"; return }
        status = profile.connectionType == .localShell ? "Shell Stopped" : "Disconnected"
    }
}

final class ReconnectTerminalView: LocalProcessTerminalView {
    private var highlightTransformer = OutputHighlightTransformer()
    /// Overridable in tests; the app always uses the shared store.
    var highlightStore: OutputHighlightStore?
    var onTerminalClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onTerminalClick?()
        super.mouseDown(with: event)
    }
    var onFindRequested: (() -> Void)?
    override func performFindPanelAction(_ sender: Any?) {
        if let item = sender as? NSMenuItem, item.tag == Int(NSFindPanelAction.showFindPanel.rawValue), let onFindRequested {
            onFindRequested(); return
        }
        super.performFindPanelAction(sender)
    }
    var onOutput: ((Data) -> Void)?
    var onVisibleOutput: (() -> Void)?
    override func dataReceived(slice: ArraySlice<UInt8>) {
        guard !slice.isEmpty else { return }
        onOutput?(Data(slice))
        // SwiftTerm delivers process output on LocalProcess's dispatch queue, which defaults to
        // the main queue; the highlight store is main-actor isolated.
        MainActor.assumeIsolated {
            let store = highlightStore ?? OutputHighlightStore.shared
            guard store.enabled, !store.ruleSet.isEmpty else {
                // Keep the parser state in sync while disabled, so enabling in the middle of
                // an escape sequence cannot inject SGR bytes into it.
                highlightTransformer.consume(slice)
                if highlightTransformer.containsVisibleText { onVisibleOutput?() }
                super.dataReceived(slice: slice)
                return
            }
            let segments = highlightTransformer.process(slice, ruleSet: store.ruleSet)
            if highlightTransformer.containsVisibleText { onVisibleOutput?() }
            OutputHighlightApplier.feed(segments,
                currentForeground: { self.getTerminal().currentAttribute.fg },
                feed: { self.feed(byteArray: $0[...]) })
        }
    }
    var reconnectOnReturn: (() -> Bool)?
    private var keyMonitor: Any?
    private var pasteTask: Task<Void, Never>?
    private var pasteGeneration = UUID()
    private var pasteBracketPID: pid_t?

    func cancelPendingPaste() {
        pasteTask?.cancel(); pasteTask = nil; pasteGeneration = UUID()
        if let pid = pasteBracketPID, process.running, process.shellPid == pid {
            send(txt: "\u{1b}[201~")
        }
        pasteBracketPID = nil
    }
    override func paste(_ sender: Any) {
        guard process.running, let text = NSPasteboard.general.string(forType: .string) else { return }
        cancelPendingPaste()
        guard PasteSafety.needsConfirmation(text) else { super.paste(sender); return }
        let pid = process.shellPid
        var pastedText = text
        var options = MultilinePasteOptions.load()
        if options.confirm {
            let panel = MultilinePastePanel(text: text, options: options)
            defer { panel.clearContents() }
            guard panel.run() == .OK, let result = panel.result, let edited = panel.pastedText else { return }
            pastedText = edited
            options = result
            options.save()
        }
        // Send the confirmed editor contents, never a newer clipboard value or a new process.
        guard process.running, process.shellPid == pid else { return }
        sendConfirmedPaste(pastedText, options: options)
    }
    func sendConfirmedPaste(_ text: String, options: MultilinePasteOptions) {
        cancelPendingPaste()
        guard process.running, !text.isEmpty else { return }
        let pid = process.shellPid
        let bracketed = getTerminal().bracketedPasteMode
        if bracketed { send(txt: "\u{1b}[200~") }
        guard options.delayEnabled && options.delayMilliseconds > 0 else {
            send(txt: text)
            if bracketed { send(txt: "\u{1b}[201~") }
            return
        }
        if bracketed { pasteBracketPID = pid }
        let generation = pasteGeneration
        let milliseconds = options.delayMilliseconds
        let chunks = PasteSafety.lineChunks(text)
        pasteTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.pasteGeneration == generation { self.cancelPendingPaste() } }
            for (index, chunk) in chunks.enumerated() {
                guard !Task.isCancelled, self.pasteGeneration == generation,
                      self.process.running, self.process.shellPid == pid else { return }
                self.send(txt: chunk)
                if index < chunks.count - 1 {
                    do { try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000) }
                    catch { return }
                }
            }
        }
    }
    func sendButtonActions(_ actions: [SendStringAction]) {
        cancelPendingPaste()
        guard process.running else { return }
        let pid = process.shellPid
        let generation = pasteGeneration
        pasteTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.pasteGeneration == generation { self.cancelPendingPaste() } }
            for action in actions {
                guard !Task.isCancelled, self.pasteGeneration == generation,
                      self.process.running, self.process.shellPid == pid else { return }
                switch action {
                case .text(let text): self.send(txt: text)
                case .pause:
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                    catch { return }
                }
            }
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelPendingPaste() }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        guard window != nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  self.window?.firstResponder === self else { return event }
            if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "f", let onFindRequested = self.onFindRequested {
                onFindRequested(); return nil
            }
            if self.pasteTask != nil { self.cancelPendingPaste() }
            guard (event.keyCode == 36 || event.keyCode == 76),
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  self.reconnectOnReturn?() == true else { return event }
            return nil
        }
    }
    deinit { pasteTask?.cancel(); if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
}
