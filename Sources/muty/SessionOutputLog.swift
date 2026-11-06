import Foundation
import Darwin
import SwiftUI

// Output-only streaming transcript. Input and askpass responses never reach this writer.
final class SessionOutputLog {
    let url: URL
    private var descriptor: Int32 = -1
    init(url: URL) throws {
        self.url = url
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
        guard descriptor >= 0 else { return }
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
    func finish() throws {
        guard descriptor >= 0 else { return }
        let fd = descriptor; descriptor = -1
        let synced = fsync(fd)
        let syncError = errno
        let closed = Darwin.close(fd)
        if synced != 0 { throw POSIXError(POSIXErrorCode(rawValue: syncError) ?? .EIO) }
        if closed != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
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
