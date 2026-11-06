import Foundation

struct PortForward: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case local, remote, socks
        var id: String { rawValue }
        var title: String { switch self { case .local: return "Local"; case .remote: return "Remote"; case .socks: return "SOCKS" } }
    }
    var name: String?
    var enabled: Bool?
    var id = UUID()
    var kind: Kind = .local
    var bindAddress = "127.0.0.1"
    var listenPort = 8080
    var destinationHost = "localhost"
    var destinationPort = 80

    var listenerKey: String {
        let scope = kind == .remote ? "remote" : "local"
        return "\(scope):\(bindAddress):\(listenPort)"
    }

    static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:%").contains($0)
        } && !host.hasPrefix("-")
    }
    static func address(_ host: String) -> String { host.contains(":") ? "[\(host)]" : host }
    func arguments() throws -> [String] {
        guard enabled != false else { return [] }
        guard Self.validHost(bindAddress), (1...65535).contains(listenPort) else {
            throw MutyError("Enter a valid bind address and listening port (1–65535).")
        }
        let listener = "\(Self.address(bindAddress)):\(listenPort)"
        if kind == .socks { return ["-D", listener] }
        guard Self.validHost(destinationHost), (1...65535).contains(destinationPort) else {
            throw MutyError("Enter a destination hostname/IP and port (1–65535).")
        }
        return [kind == .local ? "-L" : "-R", "\(listener):\(Self.address(destinationHost)):\(destinationPort)"]
    }
}

enum SSHNetworking {
    static var knownHostsFile: URL { ProfileStore().directory.appendingPathComponent("known_hosts") }

    static func transportArguments(_ p: SessionProfile, knownHostsFile: URL = SSHNetworking.knownHostsFile) throws -> [String] {
        let path = knownHostsFile.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "%", with: "%%")
        var args = ["-F", "/dev/null", "-o", "UserKnownHostsFile=\"" + path + "\"",
                    "-o", "GlobalKnownHostsFile=/dev/null",
                    "-o", "StrictHostKeyChecking=ask", "-o", "ConnectTimeout=20",
                    "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
                    "-o", "HostKeyAlgorithms=+ssh-rsa", "-o", "KexAlgorithms=+diffie-hellman-group14-sha1",
                    "-o", "IdentityAgent=none",
                    "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ForwardAgent=no",
                    "-p", String(p.port), "-l", p.user]
        if p.authentication == .identityFile {
            guard let file = p.identityFile, FileManager.default.isReadableFile(atPath: file) else {
                throw MutyError("Choose a readable identity file.")
            }
            args += ["-i", file, "-o", "IdentitiesOnly=yes", "-o", "PreferredAuthentications=publickey",
                     "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no"]
        } else {
            args += ["-o", "PreferredAuthentications=password", "-o", "PasswordAuthentication=yes",
                     "-o", "PubkeyAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
                     "-o", "IdentityFile=none", "-o", "NumberOfPasswordPrompts=3"]
        }
        return args
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
