import Foundation

// OpenSSH executes LocalCommand only after authentication. The command and path
// are generated locally; no server text, hostname or user input is interpolated.
final class SSHAuthenticationReceipt {
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
    deinit { clear() }
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
