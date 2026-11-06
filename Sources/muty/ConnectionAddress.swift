import Foundation

struct ConnectionAddress {
    let host: String
    let user: String
    let port: Int

    static func parse(_ input: String, defaultUser: String, defaultPort: Int) throws -> ConnectionAddress {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var user = defaultUser
        var port = defaultPort
        if let at = host.firstIndex(of: "@") {
            user = String(host[..<at]); host = String(host[host.index(after: at)...])
            guard !host.contains("@") else { throw MutyError("Use user@host:port.") }
        }
        if host.hasPrefix("[") {
            guard let end = host.firstIndex(of: "]") else { throw MutyError("Close the IPv6 address with ].") }
            let suffix = String(host[host.index(after: end)...])
            let address = String(host[host.index(after: host.startIndex)..<end])
            guard address.contains(":"), !address.isEmpty else { throw MutyError("Invalid bracketed IPv6 address.") }
            host = address
            if !suffix.isEmpty {
                guard suffix.hasPrefix(":"), let value = Int(suffix.dropFirst()) else { throw MutyError("Invalid port.") }
                port = value
            }
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.lastIndex(of: ":") {
            guard let value = Int(host[host.index(after: colon)...]) else { throw MutyError("Invalid port.") }
            port = value; host = String(host[..<colon])
        }
        var profile = SessionProfile(); profile.host = host; profile.user = user; profile.port = port
        let checked = try profile.validated()
        return Self(host: checked.host, user: checked.user, port: checked.port)
    }
}

enum PasteSafety {
    static func lineChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var line = ""
        for character in text {
            line.append(character)
            if character.isNewline { chunks.append(line); line = "" }
        }
        if !line.isEmpty { chunks.append(line) }
        return chunks
    }
    static func needsConfirmation(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
    }
}
