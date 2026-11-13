import Foundation
import Darwin

struct SFTPStatus: LocalizedError {
    let code: UInt32
    let message: String
    var errorDescription: String? { message.isEmpty ? "SFTP error \(code)." : message }
}
struct SFTPAttributes: Equatable {
    var size: UInt64?
    var permissions: UInt32?
    var owner: UInt32?
    var group: UInt32?
    var modified: Date?
    var isDirectory: Bool { permissions.map { $0 & 0o170000 == 0o040000 } ?? false }
    var isSymlink: Bool { permissions.map { $0 & 0o170000 == 0o120000 } ?? false }
    var isRegular: Bool { permissions.map { $0 & 0o170000 == 0o100000 } ?? false }
}
struct BrowserFile: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    var isDirectory: Bool
    var isSymlink: Bool
    var size: UInt64?
    var modified: Date?
    var ownerName: String? = nil
    var groupName: String? = nil
    var sortSize: UInt64 { size ?? 0 }
    var sortModified: Date { modified ?? .distantPast }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
    static func join(_ directory: String, _ name: String) throws -> String {
        guard validName(name) else { throw MutyError("Invalid filename.") }
        return (directory == "/" ? "/" : directory + "/") + name
    }
    static func sorted(_ values: [Self]) -> [Self] {
        values.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct SFTPPacket {
    var data = Data()
    mutating func byte(_ v: UInt8) { data.append(v) }
    mutating func u32(_ v: UInt32) { var n = v.bigEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { var n = v.bigEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
    mutating func string(_ value: Data) { u32(UInt32(value.count)); data.append(value) }
    mutating func string(_ value: String) { string(Data(value.utf8)) }
}
private struct SFTPReader {
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw MutyError("Malformed SFTP response.") }
        defer { offset += count }; return data.subdata(in: offset..<(offset + count))
    }
    mutating func byte() throws -> UInt8 { try bytes(1)[0] }
    mutating func u32() throws -> UInt32 { try bytes(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func u64() throws -> UInt64 { try bytes(8).reduce(0) { $0 << 8 | UInt64($1) } }
    mutating func string() throws -> Data { let count = try u32(); return try bytes(Int(count)) }
    mutating func text() throws -> String {
        guard let value = String(data: try string(), encoding: .utf8), !value.contains("\0") else { throw MutyError("SFTP returned a non-UTF-8 name or invalid text.") }
        return value
    }
    mutating func attributes() throws -> SFTPAttributes {
        let flags = try u32()
        guard flags & ~UInt32(0x8000000f) == 0 else { throw MutyError("Unsupported SFTP attributes.") }
        var value = SFTPAttributes()
        if flags & 1 != 0 { value.size = try u64() }
        if flags & 2 != 0 { value.owner = try u32(); value.group = try u32() }
        if flags & 4 != 0 { value.permissions = try u32() }
        if flags & 8 != 0 { _ = try u32(); value.modified = Date(timeIntervalSince1970: TimeInterval(try u32())) }
        if flags & 0x80000000 != 0 {
            let count = try u32(); guard count <= 10000 else { throw MutyError("Too many SFTP attributes.") }
            for _ in 0..<count { _ = try string(); _ = try string() }
        }
        return value
    }
}

// The serial queue owns all protocol/handle state. The lock protects cancellation
// and process lifetime only. No SSH credentials or shell commands are used here.
final class SFTPClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "muty.sftp.channel", qos: .userInitiated)
    private let lock = NSCondition()
    private let executable: URL
    private let arguments: [String]
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var initiated = false
    private var serial: UInt32 = 0
    private var paused = false
    private var cancelled = false
    private var closed = false
    private var busy = false
    private var generation = UUID()
    private var posixRename = false
    private var copyData = false
    private var pendingCleanup: [(String, Bool)] = []
    init(executable: URL = URL(fileURLWithPath: "/usr/bin/ssh"), arguments: [String]) {
        self.executable = executable; self.arguments = arguments
    }
    func independentChannel() -> SFTPClient {
        SFTPClient(executable: executable, arguments: arguments)
    }

    func perform<T>(_ action: @escaping (SFTPClient) throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock(); cancelled = false; busy = true; generation = UUID(); lock.unlock()
            queue.async { [self] in
                do {
                    try checkCancellation(); try connect(); try cleanup()
                    let result = try action(self)
                    lock.lock(); busy = false; lock.unlock()
                    continuation.resume(returning: result)
                } catch {
                    disconnectProcess()
                    lock.lock(); let wasCancelled = cancelled || closed; busy = false; lock.unlock()
                    continuation.resume(throwing: wasCancelled ? CancellationError() : error)
                }
            }
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; paused = false; lock.broadcast(); let token = generation; lock.unlock()
        // Healthy transfers stop cooperatively and remove their staged files.
        // A stalled network read gets its own mux client killed, never the master.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let pid = self.busy && self.cancelled && self.generation == token ? self.process?.processIdentifier : nil
            self.lock.unlock()
            if let pid, pid > 0 { _ = kill(pid, SIGKILL) }
        }
    }
    func shutdown() {
        lock.lock(); closed = true; cancelled = true; paused = false; lock.broadcast(); let pid = process?.processIdentifier; lock.unlock()
        if let pid, pid > 0 { _ = kill(pid, SIGTERM) }
        queue.async { [self] in disconnectProcess() }
    }
    deinit { if let process, process.isRunning { process.terminate() } }
    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        if !value { lock.broadcast() }
        lock.unlock()
    }
    func checkCancellation() throws {
        lock.lock()
        while paused && !cancelled && !closed { lock.wait() }
        let stop = cancelled || closed
        lock.unlock()
        if stop { throw CancellationError() }
    }
    private func connect() throws {
        if initiated { return }
        try checkCancellation()
        let process = Process(), incoming = Pipe(), outgoing = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = incoming; process.standardOutput = outgoing; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("MUTY_") || key.hasPrefix("SSH_ASKPASS") { environment.removeValue(forKey: key) }
        environment["SSH_ASKPASS_REQUIRE"] = "never"; process.environment = environment
        lock.lock()
        if closed || cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run(); self.process = process; lock.unlock() }
        catch { lock.unlock(); throw error }
        input = incoming.fileHandleForWriting; output = outgoing.fileHandleForReading
        var packet = SFTPPacket(); packet.byte(1); packet.u32(3); try send(packet)
        var response = try receive()
        guard try response.byte() == 2, try response.u32() == 3 else { throw MutyError("This server does not support SFTP v3.") }
        while response.remaining > 0 {
            let name = try response.text(), version = try response.string()
            if name == "posix-rename@openssh.com" && version == Data("1".utf8) { posixRename = true }
            if name == "copy-data" && version == Data("1".utf8) { copyData = true }
        }
        initiated = true
    }
    private func disconnectProcess() {
        lock.lock(); let process = self.process; self.process = nil; lock.unlock()
        if let process, process.isRunning { process.terminate() }
        try? input?.close(); try? output?.close(); input = nil; output = nil; initiated = false; posixRename = false; copyData = false
        if let process {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            // Foundation reaps via terminationHandler. waitUntilExit on this
            // dispatch worker can deadlock its task-notification run loop.
        }
    }
    private func readExactly(_ count: Int) throws -> Data {
        guard let output else { throw MutyError("SFTP channel is closed.") }
        var value = Data()
        var lastProgress = ProcessInfo.processInfo.systemUptime
        while value.count < count {
            try checkCancellation()
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready < 0 {
                if errno == EINTR { continue }
                throw MutyError("Could not read the SFTP response.")
            }
            if ready == 0 {
                guard ProcessInfo.processInfo.systemUptime - lastProgress < 30 else {
                    throw MutyError("The SFTP server did not respond for 30 seconds. The operation may be partially completed; refresh the folder before retrying.")
                }
                continue
            }
            guard let next = try output.read(upToCount: count - value.count), !next.isEmpty else {
                throw MutyError("SFTP channel ended. The server may not provide SFTP, or the SSH connection ended.")
            }
            value.append(next)
            lastProgress = ProcessInfo.processInfo.systemUptime
        }
        return value
    }
    private func send(_ packet: SFTPPacket) throws {
        guard let input else { throw MutyError("SFTP channel is closed.") }
        var framed = SFTPPacket(); framed.u32(UInt32(packet.data.count)); framed.data.append(packet.data)
        try input.write(contentsOf: framed.data)
    }
    private func receive() throws -> SFTPReader {
        var length = SFTPReader(data: try readExactly(4)); let count = Int(try length.u32())
        guard (1...4_194_304).contains(count) else { throw MutyError("Invalid SFTP packet size.") }
        return SFTPReader(data: try readExactly(count))
    }
    private func request(_ type: UInt8, _ build: (inout SFTPPacket) -> Void) throws -> (UInt8, SFTPReader) {
        serial &+= 1
        var packet = SFTPPacket(); packet.byte(type); packet.u32(serial); build(&packet); try send(packet)
        var response = try receive(); let type = try response.byte()
        guard try response.u32() == serial else { throw MutyError("SFTP response ID mismatch.") }
        if type == 101 {
            let code = try response.u32(), message = try response.text(); _ = try response.string()
            if code != 0 { throw SFTPStatus(code: code, message: message) }
        }
        return (type, response)
    }
    // Only the protocol queue calls this method. Drain ordinary failures before
    // returning so the next request cannot consume another operation's reply.
    private func pipeline(_ requests: [(UInt8, SFTPPacket)],
                          response: (Int, UInt8, inout SFTPReader) throws -> Void) throws {
        guard requests.count <= 32 else { throw MutyError("SFTP request window exceeded.") }
        // Long path requests and REALPATH replies must fit the pipe window.
        // WRITE bodies are large, but their replies contain only status.
        let controlBytes = requests.reduce(0) { $0 + ($1.0 == 6 ? 128 : $1.1.data.count + 9) }
        if controlBytes > 8192 && requests.count > 1 {
            let middle = requests.count / 2
            try pipeline(Array(requests[..<middle]), response: response)
            try pipeline(Array(requests[middle...])) { index, kind, reply in
                try response(index + middle, kind, &reply)
            }
            return
        }
        var pending: [UInt32: Int] = [:]
        var firstFailure: Error?
        do {
            for (index, request) in requests.enumerated() {
                try checkCancellation()
                serial &+= 1
                var packet = SFTPPacket()
                packet.byte(request.0); packet.u32(serial)
                packet.data.append(request.1.data)
                try send(packet)
                pending[serial] = index
            }
            while !pending.isEmpty {
                var reply = try receive()
                let kind = try reply.byte()
                let id = try reply.u32()
                guard let index = pending.removeValue(forKey: id) else {
                    throw MutyError("Unexpected SFTP response ID.")
                }
                do {
                    if kind == 101 {
                        let code = try reply.u32()
                        let message = try reply.text()
                        _ = try reply.string()
                        if code != 0 { throw SFTPStatus(code: code, message: message) }
                    }
                    try response(index, kind, &reply)
                } catch {
                    if firstFailure == nil { firstFailure = error }
                }
            }
        } catch {
            // Cancellation, framing and I/O errors can leave replies outstanding.
            // Invalidate the channel before handle/temporary-file cleanup runs.
            disconnectProcess()
            throw error
        }
        if let firstFailure { throw firstFailure }
    }
    private func handle(_ type: UInt8, _ build: (inout SFTPPacket) -> Void) throws -> Data {
        var (kind, value) = try request(type, build)
        guard kind == 102 else { throw MutyError("Invalid SFTP handle response.") }
        return try value.string()
    }
    private func status(_ type: UInt8, _ build: (inout SFTPPacket) -> Void) throws {
        guard try request(type, build).0 == 101 else { throw MutyError("Invalid SFTP status response.") }
    }
    private func handleAttributes(_ handle: Data) throws -> SFTPAttributes {
        var (kind, reply) = try request(8) { $0.string(handle) }
        guard kind == 105 else { throw MutyError("Invalid SFTP handle attributes.") }
        return try reply.attributes()
    }
    private func close(_ handle: Data) throws { try status(4) { $0.string(handle) } }
    func canonical(_ path: String) throws -> String {
        try checkCancellation()
        var (kind, response) = try request(16) { $0.string(path) }
        guard kind == 104, try response.u32() == 1 else { throw MutyError("Invalid SFTP path response.") }
        let path = try response.text()
        guard path.hasPrefix("/"), !path.contains("\0") else { throw MutyError("Invalid server directory.") }
        return path == "/" ? path : path.trimmingCharacters(in: CharacterSet(charactersIn: "/" )).withLeadingSlash
    }
    func attributes(_ path: String, followLinks: Bool = false) throws -> SFTPAttributes? {
        do {
            var (kind, response) = try request(followLinks ? 17 : 7) { $0.string(path) }
            guard kind == 105 else { throw MutyError("Invalid SFTP attributes response.") }
            return try response.attributes()
        } catch let error as SFTPStatus where error.code == 2 { return nil }
    }
    func list(_ path: String) throws -> [BrowserFile] {
        try checkCancellation()
        let directory = try handle(11) { $0.string(path) }
        defer { try? close(directory) }
        var files: [BrowserFile] = []
        while true {
            try checkCancellation()
            do {
                var (kind, response) = try request(12) { $0.string(directory) }
                guard kind == 104 else { throw MutyError("Invalid SFTP directory response.") }
                let count = try response.u32()
                guard count > 0, count <= 100000, files.count + Int(count) <= 100000 else { throw MutyError("Directory is too large or invalid.") }
                for _ in 0..<count {
                    let name = try response.text(); let longName = try response.string(); let attrs = try response.attributes()
                    let fields = String(data: longName, encoding: .utf8)?.split(whereSeparator: \.isWhitespace) ?? []
                    let hasUnixFormat = fields.count >= 9 && fields[0].count >= 10 && "-dlcbps".contains(fields[0].first ?? "?") && UInt64(fields[1]) != nil
                    let ownerName = hasUnixFormat ? String(fields[2]) : nil
                    let groupName = hasUnixFormat ? String(fields[3]) : nil
                    if name == "." || name == ".." { continue }
                    let file = try BrowserFile.join(path, name)
                    files.append(BrowserFile(name: name, path: file, isDirectory: attrs.isDirectory,
                                             isSymlink: attrs.isSymlink, size: attrs.size, modified: attrs.modified,
                                             ownerName: ownerName, groupName: groupName))
                }
            } catch let error as SFTPStatus where error.code == 1 { break }
        }
        return BrowserFile.sorted(files)
    }
    func mkdir(_ path: String) throws { try checkCancellation(); try status(14) { $0.string(path); $0.u32(4); $0.u32(0o700) } }
    func createFile(_ path: String) throws {
        try validateDirectoryAncestors(path)
        try close(openNewFile(path))
    }
    private func openNewFile(_ path: String) throws -> Data {
        try checkCancellation()
        return try handle(3) { $0.string(path); $0.u32(2 | 8 | 32); $0.u32(4); $0.u32(0o600) }
    }
    func remove(_ path: String, directory: Bool) throws { try status(directory ? 15 : 13) { $0.string(path) } }
    private func removeFiles(_ paths: [String], expected: [String: BrowserFile]?,
                             progress: (String) -> Void) throws {
        for start in stride(from: 0, to: paths.count, by: 32) {
            let batch = Array(paths[start..<min(start + 32, paths.count)])
            // The parent may have changed while recursive child removal ran.
            // Recheck immediately before each mutation window.
            try validateDirectoryAncestors(batch[0])
            if let expected {
                for path in batch {
                    guard let original = expected[path], let current = try attributes(path),
                          current.isRegular, !current.isSymlink,
                          current.size == original.size, current.modified == original.modified else {
                        throw MutyError("The move source changed: " + path)
                    }
                }
            }
            let requests: [(UInt8, SFTPPacket)] = batch.map { path in
                var packet = SFTPPacket(); packet.string(path)
                return (13, packet)
            }
            try pipeline(requests) { index, kind, _ in
                guard kind == 101 else { throw MutyError("Invalid SFTP removal response.") }
                progress(batch[index])
            }
        }
    }

    func removeTree(_ path: String, depth: Int = 0, expected: [String: BrowserFile]? = nil,
                    progress: (String) -> Void = { _ in }) throws {
        try checkCancellation()
        guard path.hasPrefix("/"), path != "/", depth <= 128 else { throw MutyError("Invalid path or excessive directory depth: " + path) }
        do {
            progress(path)
            try validateDirectoryAncestors(path)
            guard let attrs = try attributes(path), attrs.permissions != nil else { throw MutyError("Cannot determine file type") }
            if let expected {
                guard let original = expected[path], !attrs.isSymlink,
                      attrs.isDirectory == original.isDirectory,
                      original.isDirectory || (attrs.isRegular && attrs.size == original.size && attrs.modified == original.modified) else {
                    throw MutyError("The move source changed: " + path)
                }
            }
            if attrs.isDirectory && !attrs.isSymlink {
                guard try canonical(path) == path else { throw MutyError("Directory changed or became a symbolic link") }
                let entries = try list(path)
                if let expected, entries.contains(where: { expected[$0.path] == nil }) {
                    throw MutyError("New files appeared in the move source: " + path)
                }
                for entry in entries where entry.isDirectory && !entry.isSymlink {
                    try removeTree(entry.path, depth: depth + 1, expected: expected, progress: progress)
                }
                // REMOVE unlinks the entry itself, including symbolic links.
                let files = entries.filter { !$0.isDirectory || $0.isSymlink }.map(\.path)
                try removeFiles(files, expected: expected, progress: progress)
                try validateDirectoryAncestors(path)
                guard let current = try attributes(path), current.isDirectory, !current.isSymlink,
                      try canonical(path) == path else { throw MutyError("Directory changed during removal") }
                try remove(path, directory: true)
            } else {
                try remove(path, directory: false)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw MutyError("Could not remove " + path + ": " + error.localizedDescription) }
    }
    func moveSourceSnapshot(_ path: String, depth: Int = 0) throws -> [String: BrowserFile] {
        try checkCancellation()
        guard depth < 128 else { throw MutyError("Folder nesting exceeds 128 levels.") }
        try validateDirectoryAncestors(path)
        guard let attrs = try attributes(path) else { return [:] }
        guard !attrs.isSymlink, attrs.isDirectory || attrs.isRegular else { throw MutyError("The move source changed: " + path) }
        let entry = BrowserFile(name: (path as NSString).lastPathComponent, path: path,
                                isDirectory: attrs.isDirectory, isSymlink: false,
                                size: attrs.size, modified: attrs.modified)
        var entries = [path: entry]
        if attrs.isDirectory {
            for child in try list(path) {
                entries.merge(try moveSourceSnapshot(child.path, depth: depth + 1)) { _, latest in latest }
            }
        }
        return entries
    }
    func rename(_ old: String, _ new: String, replace: Bool = false) throws {
        try checkCancellation()
        if replace {
            guard posixRename else { throw MutyError("This server cannot safely replace a file atomically. Rename or remove the existing file first.") }
            try status(200) { $0.string("posix-rename@openssh.com"); $0.string(old); $0.string(new) }
        } else { try status(18) { $0.string(old); $0.string(new) } }
    }
    private func cleanup() throws {
        var remaining: [(String, Bool)] = []
        for (path, directory) in pendingCleanup.reversed() {
            do { try remove(path, directory: directory) }
            catch let error as SFTPStatus where error.code == 2 {}
            catch { remaining.append((path, directory)) }
        }
        pendingCleanup = remaining.reversed()
    }
    private func forgetTemporary(_ path: String) { pendingCleanup.removeAll { $0.0 == path || $0.0.hasPrefix(path + "/") } }
    func upload(_ local: URL, to remote: String, replace: Bool, preserveOwnership: Bool = false, beforeCommit: (() throws -> Void)? = nil, progress: (String, UInt64, UInt64?) -> Void) throws {
        let values = try local.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw MutyError("Symbolic links are not transferred: " + local.lastPathComponent) }
        let existing = try attributes(remote)
        if values.isDirectory == true {
            guard existing == nil else { throw MutyError("A folder already exists: " + remote + ". Folder merging is not supported.") }
        } else {
            guard values.isRegularFile == true else { throw MutyError("Only regular files and folders can be uploaded.") }
            guard existing == nil || (replace && existing!.isRegular && !existing!.isSymlink) else { throw MutyError("Destination exists or is not a regular file: " + remote) }
        }
        let parent = (remote as NSString).deletingLastPathComponent
        let temporary = try BrowserFile.join(parent.isEmpty ? "/" : parent, ".muty-upload-" + UUID().uuidString)
        do {
            if values.isDirectory == true { try uploadDirectory(local, to: temporary, depth: 0, progress: progress) }
            else { try uploadFile(local, to: temporary, permissions: existing?.permissions, ownership: preserveOwnership ? existing : nil, progress: progress) }
            try checkCancellation()
            try beforeCommit?()
            try rename(temporary, remote, replace: existing != nil)
            forgetTemporary(temporary)
        } catch { try? cleanup(); throw error }
    }
    private func uploadDirectory(_ local: URL, to remote: String, depth: Int, progress: (String, UInt64, UInt64?) -> Void) throws {
        guard depth < 64 else { throw MutyError("Folder nesting exceeds 64 levels.") }
        try mkdir(remote); pendingCleanup.append((remote, true))
        for local in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
            try checkCancellation()
            let attrs = try local.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard attrs.isSymbolicLink != true else { throw MutyError("Symbolic links are not transferred: " + local.lastPathComponent) }
            let path = try BrowserFile.join(remote, local.lastPathComponent)
            if attrs.isDirectory == true { try uploadDirectory(local, to: path, depth: depth + 1, progress: progress) }
            else if attrs.isRegularFile == true { try uploadFile(local, to: path, permissions: nil, progress: progress) }
            else { throw MutyError("Unsupported local file: " + local.lastPathComponent) }
        }
    }
    private func uploadFile(_ local: URL, to remote: String, permissions: UInt32?, ownership: SFTPAttributes? = nil, progress: (String, UInt64, UInt64?) -> Void) throws {
        let fd = open(local.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw MutyError("Source is not a regular file.") }
        let handle = try openNewFile(remote)
        pendingCleanup.append((remote, false))
        var handleClosed = false
        defer { if !handleClosed { try? close(handle) } }
        var offset: UInt64 = 0
        progress(local.lastPathComponent, 0, UInt64(info.st_size))
        var acknowledged: UInt64 = 0
        while true {
            var requests: [(UInt8, SFTPPacket)] = []
            var lengths: [UInt64] = []
            for _ in 0..<32 {
                try checkCancellation()
                guard let data = try file.read(upToCount: 32768), !data.isEmpty else { break }
                var packet = SFTPPacket()
                packet.string(handle); packet.u64(offset); packet.string(data)
                requests.append((6, packet)); lengths.append(UInt64(data.count))
                offset += UInt64(data.count)
            }
            if requests.isEmpty { break }
            try pipeline(requests) { index, kind, _ in
                guard kind == 101 else { throw MutyError("Invalid SFTP write response.") }
                acknowledged += lengths[index]
                progress(local.lastPathComponent, acknowledged, UInt64(info.st_size))
            }
        }
        guard offset == UInt64(info.st_size) else { throw MutyError("Source file changed while uploading. Try again.") }
        if let ownership {
            guard let owner = ownership.owner, let group = ownership.group, let mode = ownership.permissions else {
                throw MutyError("The server did not provide ownership information. The original file was not replaced.")
            }
            // Chown first: it can clear setuid/setgid bits. Refuse replacement if
            // the server cannot preserve the original Unix owner and group.
            try status(10) { $0.string(handle); $0.u32(2); $0.u32(owner); $0.u32(group) }
            try status(10) { $0.string(handle); $0.u32(4); $0.u32(mode & 0o7777) }
        } else {
            try status(10) { $0.string(handle); $0.u32(4); $0.u32((permissions ?? UInt32(info.st_mode)) & 0o777) }
        }
        try close(handle); handleClosed = true
    }
    // Return false only when the server did not advertise copy-data.
    // The caller retains its download/upload fallback for those servers.
    func copyRemote(_ source: String, to destination: String,
                    progress: (String, UInt64, UInt64?) -> Void) throws -> Bool {
        guard copyData else { return false }
        try validateDirectoryAncestors(source)
        try validateDirectoryAncestors(destination)
        guard try attributes(destination) == nil else { throw MutyError("Destination already exists.") }
        let parent = (destination as NSString).deletingLastPathComponent
        let temporary = try BrowserFile.join(parent, ".muty-copy-" + UUID().uuidString)
        do {
            try copyRemoteItem(source, to: temporary, depth: 0, progress: progress)
            try checkCancellation()
            try validateDirectoryAncestors(destination)
            try rename(temporary, destination)
            forgetTemporary(temporary)
            return true
        } catch let error as SFTPStatus where error.code == 8 {
            try? cleanup()
            copyData = false
            return false
        } catch {
            try? cleanup()
            throw error
        }
    }
    private func copyRemoteItem(_ source: String, to destination: String, depth: Int,
                                progress: (String, UInt64, UInt64?) -> Void) throws {
        try checkCancellation()
        guard depth < 64 else { throw MutyError("Folder nesting exceeds 64 levels.") }
        try validateDirectoryAncestors(source)
        try validateDirectoryAncestors(destination)
        guard let attrs = try attributes(source), !attrs.isSymlink else {
            throw MutyError("File is missing or is a symbolic link: " + source)
        }
        if attrs.isDirectory {
            guard try canonical(source) == source else { throw MutyError("Remote directory changed.") }
            let entries = try list(source)
            try mkdir(destination); pendingCleanup.append((destination, true))
            for entry in entries {
                try copyRemoteItem(entry.path, to: BrowserFile.join(destination, entry.name),
                                   depth: depth + 1, progress: progress)
            }
        } else {
            let (readHandle, opened) = try openReadFile(source)
            defer { if initiated { try? close(readHandle) } }
            guard let size = opened.size else {
                throw SFTPStatus(code: 8, message: "Server-side copying requires a file size.")
            }
            let writeHandle = try openNewFile(destination)
            pendingCleanup.append((destination, false))
            var writeClosed = false
            defer { if !writeClosed && initiated { try? close(writeHandle) } }
            var offset: UInt64 = 0
            let name = (source as NSString).lastPathComponent
            progress(name, 0, opened.size)
            repeat {
                try checkCancellation()
                let length = min(UInt64(8 * 1024 * 1024), size - offset)
                // A zero-length request copies through EOF, including empty files.
                try status(200) {
                    $0.string("copy-data"); $0.string(readHandle); $0.u64(offset); $0.u64(length)
                    $0.string(writeHandle); $0.u64(offset)
                }
                offset += length
                progress(name, offset, opened.size)
            } while offset < size
            let copied = try handleAttributes(writeHandle)
            guard opened.size == nil || copied.size == opened.size else { throw MutyError("Remote file changed while copying.") }
            let finalSource = try handleAttributes(readHandle)
            guard finalSource.isRegular, finalSource.size == opened.size, finalSource.modified == opened.modified else {
                throw MutyError("Remote file changed while copying.")
            }
            try status(10) {
                $0.string(writeHandle); $0.u32(4); $0.u32((opened.permissions ?? 0o600) & 0o777)
            }
            try close(writeHandle)
            writeClosed = true
        }
    }
    func download(_ remote: String, to local: URL, replace: Bool, progress: (String, UInt64, UInt64?) -> Void) throws {
        guard let attrs = try attributes(remote), !attrs.isSymlink else { throw MutyError("File is missing or is a symbolic link: " + remote) }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory)
        guard !exists || (replace && !isDirectory.boolValue && !attrs.isDirectory) else { throw MutyError("Destination exists. Folder merging is not supported.") }
        let temporary = local.deletingLastPathComponent().appendingPathComponent(".muty-download-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let canonicalSource = try canonical(remote)
        if attrs.isDirectory {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try downloadDirectory(canonicalSource, to: temporary, root: canonicalSource, depth: 0, progress: progress)
        } else {
            guard attrs.isRegular else { throw MutyError("Only regular files and folders can be downloaded.") }
            try downloadFile(canonicalSource, to: temporary, size: attrs.size, progress: progress)
        }
        try checkCancellation()
        // renamex_np with RENAME_EXCL prevents a race from overwriting a new file.
        let result = replace && exists ? Darwin.rename(temporary.path, local.path) : renamex_np(temporary.path, local.path, UInt32(RENAME_EXCL))
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private func downloadDirectory(_ remote: String, to local: URL, root: String, depth: Int, progress: (String, UInt64, UInt64?) -> Void) throws {
        guard depth < 64 else { throw MutyError("Folder nesting exceeds 64 levels.") }
        let canonicalPath = try canonical(remote)
        guard canonicalPath == root || canonicalPath.hasPrefix(root == "/" ? "/" : root + "/"),
              let directoryAttrs = try attributes(remote), directoryAttrs.isDirectory, !directoryAttrs.isSymlink else {
            throw MutyError("Remote directory changed or escaped the selected folder. Try again.")
        }
        let entries = try list(canonicalPath)
        guard try canonical(remote) == canonicalPath else { throw MutyError("Remote directory changed while reading. Try again.") }
        for entry in entries {
            try checkCancellation()
            guard !entry.isSymlink else { throw MutyError("Symbolic links are not transferred: " + entry.name) }
            let destination = local.appendingPathComponent(entry.name)
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try downloadDirectory(entry.path, to: destination, root: root, depth: depth + 1, progress: progress)
            } else {
                guard let attrs = try attributes(entry.path), attrs.isRegular, !attrs.isSymlink else { throw MutyError("Unsupported remote file: " + entry.name) }
                let resolved = try canonical(entry.path)
                guard resolved.hasPrefix(root == "/" ? "/" : root + "/") else { throw MutyError("Remote file escaped the selected folder.") }
                try downloadFile(resolved, to: destination, size: attrs.size, progress: progress)
            }
        }
    }
    func validateDirectoryAncestors(_ path: String) throws {
        var parent = (path as NSString).deletingLastPathComponent
        var ancestors: [String] = []
        while !parent.isEmpty {
            ancestors.append(parent)
            if parent == "/" { break }
            parent = (parent as NSString).deletingLastPathComponent
        }
        for start in stride(from: 0, to: ancestors.count, by: 16) {
            let batch = Array(ancestors[start..<min(start + 16, ancestors.count)])
            let requests: [(UInt8, SFTPPacket)] = batch.flatMap { path -> [(UInt8, SFTPPacket)] in
                var packet = SFTPPacket(); packet.string(path)
                return [(7, packet), (16, packet)]
            }
            try pipeline(requests) { index, kind, reply in
                let path = batch[index / 2]
                let valid: Bool
                if index.isMultiple(of: 2) {
                    guard kind == 105 else { throw MutyError("Invalid SFTP attributes response.") }
                    let attrs = try reply.attributes()
                    valid = attrs.isDirectory && !attrs.isSymlink
                } else {
                    guard kind == 104, try reply.u32() == 1 else { throw MutyError("Invalid SFTP path response.") }
                    valid = try reply.text() == path
                }
                guard valid else { throw MutyError("A directory changed or became a symbolic link: " + path) }
            }
        }
    }
    func setPermissions(_ path: String, _ mode: UInt32) throws {
        try validateDirectoryAncestors(path)
        guard let a = try attributes(path), !a.isSymlink else { throw MutyError("File is missing or is a symbolic link.") }
        try status(9) { $0.string(path); $0.u32(4); $0.u32(mode) }
    }
    func readDocument(_ path: String) throws -> RemoteTextSnapshot {
        guard let before = try attributes(path), before.isRegular, !before.isSymlink else {
            throw MutyError("Only regular files can be opened in the editor.")
        }
        guard let size = before.size, size <= RemoteTextSnapshot.maximumBytes else {
            throw MutyError("The editor supports files up to 1 MiB.")
        }
        let directory = try Self.documentTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("contents")
        try downloadFile(path, to: file, size: size, maximumBytes: RemoteTextSnapshot.maximumBytes, progress: { _, _, _ in })
        guard let after = try attributes(path), before == after else {
            throw MutyError("The file changed while reading. Open it again.")
        }
        let bytes = try Data(contentsOf: file)
        return try RemoteTextSnapshot(bytes: bytes, attributes: after)
    }
    func saveDocument(_ path: String, bytes: Data, expected: RemoteTextSnapshot) throws -> RemoteTextSnapshot {
        _ = try RemoteTextSnapshot(bytes: bytes, attributes: expected.attributes)
        let directory = try Self.documentTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("contents")
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try upload(file, to: path, replace: true, preserveOwnership: true, beforeCommit: {
            guard try self.readDocument(path) == expected else {
                throw MutyError("The file changed on the server. Your changes were not saved. Open the file again to compare; your draft is still available.")
            }
        }, progress: { _, _, _ in })
        let result = try readDocument(path)
        guard result.bytes == bytes else {
            throw MutyError("The server file changed immediately after saving. Your draft remains open; reopen the server file to compare.")
        }
        return result
    }
    private static func documentTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("muty-editor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
    private func openReadFile(_ remote: String) throws -> (Data, SFTPAttributes) {
        guard let before = try attributes(remote), before.isRegular, !before.isSymlink else {
            throw MutyError("Remote file changed or is not regular.")
        }
        let remoteHandle = try handle(3) { $0.string(remote); $0.u32(1); $0.u32(0) }
        do {
            let opened = try handleAttributes(remoteHandle)
            guard opened.isRegular, before.size == opened.size, before.modified == opened.modified,
                  let after = try attributes(remote), after.isRegular, !after.isSymlink,
                  after.size == opened.size, after.modified == opened.modified else {
                throw MutyError("Remote file changed while opening. Try again.")
            }
            return (remoteHandle, opened)
        } catch {
            try? close(remoteHandle)
            throw error
        }
    }
    private func downloadBlocks(_ handle: Data, to file: FileHandle, size: UInt64,
                                progress: (UInt64) -> Void) throws {
        var nextOffset: UInt64 = 0
        var received: UInt64 = 0
        var shortReads: [(UInt64, UInt32)] = []
        while nextOffset < size || !shortReads.isEmpty {
            var ranges = Array(shortReads.prefix(32))
            shortReads.removeFirst(ranges.count)
            while ranges.count < 32 && nextOffset < size {
                let length = UInt32(min(32768, size - nextOffset))
                ranges.append((nextOffset, length))
                nextOffset += UInt64(length)
            }
            let requests: [(UInt8, SFTPPacket)] = ranges.map { offset, length in
                var packet = SFTPPacket()
                packet.string(handle); packet.u64(offset); packet.u32(length)
                return (5, packet)
            }
            try pipeline(requests) { index, kind, reply in
                guard kind == 103 else { throw MutyError("Invalid SFTP data response.") }
                let (offset, length) = ranges[index]
                let data = try reply.string()
                guard !data.isEmpty, data.count <= Int(length) else { throw MutyError("Invalid SFTP file data.") }
                try file.seek(toOffset: offset)
                try file.write(contentsOf: data)
                received += UInt64(data.count)
                if data.count < Int(length) {
                    shortReads.append((offset + UInt64(data.count), length - UInt32(data.count)))
                }
                progress(received)
            }
        }
        guard received == size else { throw MutyError("Remote file changed while downloading. Try again.") }
    }
    private func downloadFile(_ remote: String, to local: URL, size: UInt64?, maximumBytes: UInt64? = nil, progress: (String, UInt64, UInt64?) -> Void) throws {
        let fd = open(local.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        let (remoteHandle, opened) = try openReadFile(remote)
        defer { if initiated { try? close(remoteHandle) } }
        let expectedSize = opened.size ?? size
        if let maximumBytes, let expectedSize, expectedSize > maximumBytes {
            throw MutyError("The editor supports files up to 1 MiB.")
        }
        var offset: UInt64 = 0
        progress((remote as NSString).lastPathComponent, 0, size)
        if let expectedSize {
            try downloadBlocks(remoteHandle, to: file, size: expectedSize) { bytes in
                offset = bytes
                progress((remote as NSString).lastPathComponent, bytes, expectedSize)
            }
        } else {
            while true {
                try checkCancellation()
                do {
                    var (kind, response) = try request(5) { $0.string(remoteHandle); $0.u64(offset); $0.u32(32768) }
                    guard kind == 103 else { throw MutyError("Invalid SFTP data response.") }
                    let data = try response.string()
                    guard !data.isEmpty, data.count <= 32768, offset <= UInt64.max - UInt64(data.count) else { throw MutyError("Invalid SFTP file data.") }
                    if let maximumBytes, offset + UInt64(data.count) > maximumBytes { throw MutyError("The editor supports files up to 1 MiB.") }
                    try file.write(contentsOf: data); offset += UInt64(data.count)
                    progress((remote as NSString).lastPathComponent, offset, size)
                } catch let error as SFTPStatus where error.code == 1 { break }
            }
        }
        guard size == nil || offset == size else { throw MutyError("Remote file changed while downloading. Try again.") }
        let final = try handleAttributes(remoteHandle)
        guard final.isRegular, final.size == opened.size, final.modified == opened.modified else {
            throw MutyError("Remote file changed while downloading. Try again.")
        }
        try file.synchronize(); try file.close()
    }
}
private extension String { var withLeadingSlash: String { "/" + self } }
