import Foundation

struct SSHDiagnosticIssue: Equatable {
    enum Kind: Equatable {
        case hostname
        case timeout
        case refused
        case network
        case hostKey
        case authentication
        case keyFile
        case algorithms
        case jumpHost
        case closed
        case unknown
    }

    let kind: Kind
    let title: String
    let explanation: String
    let nextStep: String

    static func detect(in log: String, isJumpHost: Bool) -> Self? {
        let lines = log.components(separatedBy: .newlines)
        let authenticationSucceeded = lines.lastIndex(where: {
            $0.localizedCaseInsensitiveContains("authentication succeeded") ||
                $0.localizedCaseInsensitiveContains("entering interactive session")
        })
        for index in lines.indices.reversed() {
            let line = lines[index]
            let value = line.lowercased()
            if value.contains("could not resolve hostname") || value.contains("nodename nor servname") ||
                value.contains("name or service not known") || value.contains("temporary failure in name resolution") {
                return issue(.hostname, host: isJumpHost)
            }
            if value.contains("connection timed out") || value.contains("operation timed out") {
                return issue(.timeout, host: isJumpHost)
            }
            if value.contains("connection refused") {
                return issue(.refused, host: isJumpHost)
            }
            if value.contains("no route to host") || value.contains("network is unreachable") {
                return issue(.network, host: isJumpHost)
            }
            if value.contains("host key verification failed") || value.contains("remote host identification has changed") {
                return issue(.hostKey, host: isJumpHost)
            }
            if value.contains("permission denied") {
                if let authenticationSucceeded, authenticationSucceeded > index { continue }
                return issue(.authentication, host: isJumpHost)
            }
            if value.contains("choose a readable identity file") ||
                value.contains("load key") && (value.contains("error") || value.contains("invalid")) {
                return issue(.keyFile, host: isJumpHost)
            }
            if value.contains("no matching") && (value.contains("found") || value.contains("method")) {
                return issue(.algorithms, host: isJumpHost)
            }
            if value.contains("stdio forwarding failed") || value.contains("proxycommand") && value.contains("failed") {
                return issue(.jumpHost, host: true)
            }
            if value.contains("connection reset by peer") || value.contains("connection closed by remote host") {
                return issue(.closed, host: isJumpHost)
            }
        }
        return nil
    }

    private static func issue(_ kind: Kind, host isJumpHost: Bool) -> Self {
        let subject = isJumpHost ? "Jump host" : "Server"
        switch kind {
        case .hostname:
            return .init(kind: kind, title: "Could not find \(subject.lowercased())", explanation: "The host name did not resolve to an address.", nextStep: "Check the host name and DNS or VPN connection.")
        case .timeout:
            return .init(kind: kind, title: "\(subject) did not respond", explanation: "The SSH connection attempt timed out.", nextStep: "Check that the host is reachable and SSH is allowed on the selected port.")
        case .refused:
            return .init(kind: kind, title: "SSH connection was refused", explanation: "The host was reached, but the SSH port rejected the connection.", nextStep: "Check the port and confirm that the SSH service is running.")
        case .network:
            return .init(kind: kind, title: "Network path is unavailable", explanation: "The system could not route traffic to the host.", nextStep: "Check the network route, VPN, and firewall rules.")
        case .hostKey:
            return .init(kind: kind, title: "Host key verification failed", explanation: "The server key does not match the trusted key, or verification was rejected.", nextStep: "Verify the server identity before changing its trusted host key.")
        case .authentication:
            return .init(kind: kind, title: "Authentication was rejected", explanation: "The server did not accept the provided authentication method.", nextStep: "Check the username, password, or selected private key and the server's allowed methods.")
        case .keyFile:
            return .init(kind: kind, title: "Private key could not be read", explanation: "OpenSSH reported a problem loading the selected key.", nextStep: "Check that the key file is available and valid, and that its passphrase is correct.")
        case .algorithms:
            return .init(kind: kind, title: "SSH algorithms do not match", explanation: "The client and server could not agree on a supported SSH algorithm.", nextStep: "Update the server or review its SSH algorithm configuration.")
        case .jumpHost:
            return .init(kind: kind, title: "Jump host connection failed", explanation: "The SSH tunnel through the jump host could not be opened.", nextStep: "Check the jump host connection first, then confirm that it can reach the destination.")
        case .closed:
            return .init(kind: kind, title: "SSH connection was closed", explanation: "The remote side closed or reset the connection.", nextStep: "Reconnect and check the server's SSH logs if the problem continues.")
        case .unknown:
            return .init(kind: kind, title: "SSH connection failed", explanation: "OpenSSH ended the connection before it became ready.", nextStep: "Check the terminal output and server availability, then try again.")
        }
    }
}

struct SSHConnectionDiagnostics: Equatable {
    enum Phase: String, Equatable {
        case preparing
        case resolving
        case connecting
        case negotiating
        case verifyingHost
        case authenticating
        case openingSession
        case connected
        case disconnected

        var title: String {
            switch self {
            case .preparing: return "Preparing SSH connection"
            case .resolving: return "Resolving host"
            case .connecting: return "Connecting to host"
            case .negotiating: return "Negotiating SSH"
            case .verifyingHost: return "Verifying host key"
            case .authenticating: return "Authenticating"
            case .openingSession: return "Opening session"
            case .connected: return "Connected"
            case .disconnected: return "Disconnected"
            }
        }
    }

    enum Host: String, Equatable {
        case target
        case jump

        var title: String { self == .jump ? "Jump host" : "Destination" }
    }

    let targetEndpoint: String
    let jumpEndpoint: String?
    var phase: Phase
    var host: Host
    var issue: SSHDiagnosticIssue?

    var currentStep: String {
        guard jumpEndpoint != nil else { return phase.title }
        return host.title + " · " + phase.title
    }

    var copyableReport: String {
        var lines = ["Muty SSH diagnostics", "Result: " + (issue?.title ?? phase.title), "Destination: " + targetEndpoint]
        if let jumpEndpoint { lines.append("Jump host: " + jumpEndpoint) }
        if issue != nil { lines.append("Stage: " + currentStep) }
        if let issue {
            lines.append("Details: " + issue.explanation)
            lines.append("Suggested next step: " + issue.nextStep)
        }
        return lines.joined(separator: "\n")
    }

    static func initial(target: String, jump: String?) -> Self {
        .init(targetEndpoint: target, jumpEndpoint: jump, phase: .preparing, host: .target, issue: nil)
    }

    static func parse(target: String, jump: String?, targetLog: String, jumpLog: String,
                      transportReady: Bool, running: Bool) -> Self {
        var result = initial(target: target, jump: jump)
        if let issue = SSHDiagnosticIssue.detect(in: jumpLog, isJumpHost: true) {
            result.host = .jump
            result.issue = issue
        } else if let issue = SSHDiagnosticIssue.detect(in: targetLog, isJumpHost: false) {
            result.host = issue.kind == .jumpHost ? .jump : .target
            result.issue = issue
        } else if jump != nil && !jumpLog.isEmpty &&
                    !jumpLog.localizedCaseInsensitiveContains("authentication succeeded") &&
                    !jumpLog.localizedCaseInsensitiveContains("stdio forwarding to") {
            result.host = .jump
        }

        if transportReady {
            result.phase = .connected
            result.issue = nil
            return result
        }

        if !running && result.issue == nil {
            result.phase = .disconnected
            return result
        }
        result.phase = .resolving

        let phaseLog = result.host == .jump && !jumpLog.isEmpty ? jumpLog : targetLog
        let markers: [(String, Phase)] = [
            ("connecting to ", .connecting),
            ("connection established", .negotiating),
            ("remote protocol version", .negotiating),
            ("ssh2_msg_kexinit", .negotiating),
            ("server host key:", .verifyingHost),
            ("host '", .verifyingHost),
            ("authenticating to ", .authenticating),
            ("authentications that can continue", .authenticating),
            ("next authentication method", .authenticating),
            ("authentication succeeded", .openingSession),
            ("entering interactive session", .openingSession),
            ("sending subsystem: sftp", .openingSession)
        ]
        let lines = phaseLog.lowercased().components(separatedBy: .newlines)
        var latestMarker: (index: Int, phase: Phase)?
        for (token, phase) in markers {
            guard let index = lines.lastIndex(where: { $0.contains(token) }) else { continue }
            if let current = latestMarker, index > current.index {
                latestMarker = (index, phase)
            } else if latestMarker == nil {
                latestMarker = (index, phase)
            }
        }
        if let marker = latestMarker {
            result.phase = marker.1
        } else if result.host == .target && jump != nil && !targetLog.isEmpty && targetLog.lowercased().contains("proxycommand") {
            result.host = .jump
            result.phase = .connecting
        }

        return result
    }
}
