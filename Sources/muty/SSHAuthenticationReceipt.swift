import Foundation

// OpenSSH executes LocalCommand only after authentication. The command and path
// are generated locally; no server text, hostname or user input is interpolated.
@MainActor
protocol AuthenticationReceipt: AnyObject {
    var authenticated: Bool { get }
    var arguments: [String] { get }
    func clear()
}

@MainActor
final class SSHAuthenticationReceipt: AuthenticationReceipt {
    private let directory: URL
    let path: String
    init() throws {
        directory = URL(fileURLWithPath: "/tmp/muty-auth-" + UUID().uuidString, isDirectory: true)
        path = directory.appendingPathComponent("authenticated").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    var arguments: [String] {
        ["-o", "PermitLocalCommand=yes", "-o", "LocalCommand=/usr/bin/touch " + SSHNetworking.quote(path)]
    }
    var authenticated: Bool { FileManager.default.fileExists(atPath: path) }
    func clear() { try? FileManager.default.removeItem(at: directory) }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
final class SSHAuthenticationAttempt {
    typealias ReceiptFactory = () throws -> any AuthenticationReceipt

    private let makeReceipt: ReceiptFactory
    private(set) var generation = UUID()
    private(set) var targetReceipt: (any AuthenticationReceipt)?
    private(set) var jumpReceipt: (any AuthenticationReceipt)?
    private var targetPassword: (() throws -> Void)?
    private var jumpPassword: (() throws -> Void)?

    init(makeReceipt: ReceiptFactory? = nil) {
        self.makeReceipt = makeReceipt ?? { try SSHAuthenticationReceipt() }
    }

    func createReceipt(forJump jump: Bool) throws -> any AuthenticationReceipt {
        let receipt = try makeReceipt()
        if jump { jumpReceipt = receipt } else { targetReceipt = receipt }
        return receipt
    }

    func stagePassword(forJump jump: Bool, save: @escaping () throws -> Void) {
        if jump { jumpPassword = save } else { targetPassword = save }
    }

    func rejectedPrompt(forJump jump: Bool) {
        if jump { jumpPassword = nil } else { targetPassword = nil }
    }

    @discardableResult
    func commit(onError: (String) -> Void) -> Bool {
        _ = commit(jumpReceipt, password: &jumpPassword, failure: "Jump-host password was not saved: ", onError: onError)
        let savedTarget = commit(targetReceipt, password: &targetPassword, failure: "Password was not saved: ", onError: onError)
        return savedTarget
    }

    func invalidate() {
        generation = UUID()
        discard()
    }

    func discard() {
        targetPassword = nil; jumpPassword = nil
        targetReceipt?.clear(); targetReceipt = nil
        jumpReceipt?.clear(); jumpReceipt = nil
    }

    private func commit(
        _ receipt: (any AuthenticationReceipt)?, password: inout (() throws -> Void)?,
        failure: String, onError: (String) -> Void
    ) -> Bool {
        guard let receipt, receipt.authenticated, let action = password else { return false }
        password = nil
        do { try action(); return true }
        catch { onError(failure + error.localizedDescription); return false }
    }
}

enum HostKeyQuestion {
    static func isInitial(_ prompt: String) -> Bool {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("The authenticity of host '") && value.contains("key fingerprint is") && value.contains("Are you sure you want to continue connecting")
    }
    static func isRetry(_ prompt: String) -> Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines) == "Please type 'yes', 'no' or the fingerprint:"
    }
}
