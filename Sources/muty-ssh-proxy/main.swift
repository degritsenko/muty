import Darwin

// The bastion transport must not share the shell client's controlling terminal
// or process group: that client can close while sibling SFTP channels stay open.
guard CommandLine.arguments.count > 1, setsid() >= 0 else { exit(1) }
let arguments = ["/usr/bin/ssh"] + Array(CommandLine.arguments.dropFirst())
var argv = arguments.map { strdup($0) }
argv.append(nil)
argv.withUnsafeMutableBufferPointer { buffer in
    _ = execv("/usr/bin/ssh", buffer.baseAddress!)
}
for pointer in argv { free(pointer) }
exit(127)
