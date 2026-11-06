import Foundation
import Darwin

public struct AskpassRequest: Codable {
    public let token: String
    public let connection: String
    public let prompt: String
    public let kind: String
    public init(token: String, connection: String, prompt: String, kind: String) {
        self.token = token; self.connection = connection; self.prompt = prompt; self.kind = kind
    }
}

public struct AskpassResponse: Codable {
    public let accepted: Bool
    public let value: String
    public init(accepted: Bool, value: String = "") { self.accepted = accepted; self.value = value }
}

public enum Wire {
    public static let maxBytes = 65_536
    public enum Failure: Error { case invalidAddress, io, invalidPacket }

    public static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure.invalidAddress }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            for (i, byte) in bytes.enumerated() { dest[i] = UInt8(bitPattern: byte) }
        }
        return addr
    }

    public static func configure(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    public static func send<T: Encodable>(_ value: T, fd: Int32) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maxBytes else { throw Failure.invalidPacket }
        var size = UInt32(data.count).bigEndian
        var packet = withUnsafeBytes(of: &size) { Data($0) }
        packet.append(data)
        try packet.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.io }
                offset += count
            }
        }
    }

    public static func receive<T: Decodable>(_ type: T.Type, fd: Int32) throws -> T {
        let header = try read(4, fd: fd)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0 && size <= maxBytes else { throw Failure.invalidPacket }
        return try JSONDecoder().decode(type, from: read(Int(size), fd: fd))
    }

    private static func read(_ count: Int, fd: Int32) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Failure.io }
                offset += n
            }
        }
        return data
    }
}
