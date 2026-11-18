import Foundation
import Darwin
import SwiftUI

// Output-only streaming transcript. Input and askpass responses never reach this writer.
final class SessionOutputLog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "muty.session-log", qos: .utility)
    private let lock = NSLock()
    private var pendingBytes = 0
    private var accepting = true
    private var failure: Error?
    private let onError: @Sendable (Error) -> Void
    private static let maxPendingBytes = 4 * 1024 * 1024
    let url: URL
    private var descriptor: Int32 = -1
    init(url: URL, onError: @escaping @Sendable (Error) -> Void) throws {
        self.url = url
        self.onError = onError
        let fd = open(url.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            Darwin.close(fd); throw MutyError("Choose a regular file for the session log.")
        }
        guard fchmod(fd, 0o600) == 0, ftruncate(fd, 0) == 0 else {
            let code = errno; Darwin.close(fd); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
    }
    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return }
        guard data.count <= Self.maxPendingBytes - pendingBytes else {
            throw MutyError("Session log stopped because the disk cannot keep up with terminal output.")
        }
        pendingBytes += data.count
        queue.async { [self] in
            defer {
                lock.lock()
                pendingBytes -= data.count
                lock.unlock()
            }
            guard failure == nil else { return }
            do { try writeToFile(data) }
            catch {
                failure = error
                lock.lock()
                accepting = false
                lock.unlock()
                onError(error)
            }
        }
    }

    private func writeToFile(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
    }

    func finish(completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        accepting = false
        queue.async { [self] in
            guard descriptor >= 0 else { completion(failure); return }
            let fd = descriptor
            descriptor = -1
            let synced = fsync(fd)
            let syncError = errno
            let closed = Darwin.close(fd)
            if failure == nil {
                if synced != 0 { failure = POSIXError(POSIXErrorCode(rawValue: syncError) ?? .EIO) }
                else if closed != 0 { failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            completion(failure)
        }
        lock.unlock()
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}

struct SessionLoggingMenu: View {
    @ObservedObject var connection: SSHConnection
    var body: some View {
        Button(connection.isLogging ? "Stop Logging" : "Start Logging…") {
            if connection.isLogging { connection.stopLogging() } else { connection.startLogging() }
        }.disabled(!connection.running && !connection.isLogging)
        if connection.logURL != nil { Button("Show Log File") { connection.showLogFile() } }
    }
}
