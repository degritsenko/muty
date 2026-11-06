import Foundation
import Darwin
import MutyIPC

// stdout is exclusively the ASKPASS protocol, never diagnostic output.
let env = ProcessInfo.processInfo.environment
guard let path = env["MUTY_ASKPASS_SOCKET"], let token = env["MUTY_ASKPASS_TOKEN"],
      let connection = env["MUTY_ASKPASS_CONNECTION"], CommandLine.arguments.count == 2 else { exit(1) }
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(1) }
Wire.configure(fd)
do {
    var addr = try Wire.address(path)
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { throw Wire.Failure.io }
    var uid: uid_t = 0; var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw Wire.Failure.io }
    let request = AskpassRequest(token: token, connection: connection,
                                 prompt: CommandLine.arguments[1], kind: env["SSH_ASKPASS_PROMPT"] ?? "")
    try Wire.send(request, fd: fd)
    let response = try Wire.receive(AskpassResponse.self, fd: fd)
    close(fd)
    guard response.accepted else { exit(1) }
    FileHandle.standardOutput.write(Data((response.value + "\n").utf8))
    exit(0)
} catch {
    close(fd)
    exit(1)
}
