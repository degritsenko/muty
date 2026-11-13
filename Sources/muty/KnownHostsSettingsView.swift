import SwiftUI
import CryptoKit
import Darwin

struct KnownHostEntry: Identifiable {
    let id: Int
    let hosts: String
    let keyType: String
    let fingerprint: String
    let marker: String?
    var displayHost: String { hosts.hasPrefix("|1|") ? "Hashed host" : hosts }
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty || (hosts + " " + keyType + " " + fingerprint).localizedCaseInsensitiveContains(query) { return true }
        let parts = hosts.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[1] == "1", let salt = Data(base64Encoded: String(parts[2])),
              let expected = Data(base64Encoded: String(parts[3])) else { return false }
        return [query, query.lowercased()].contains { value in
            Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: salt))) == expected
        }
    }
}

@MainActor final class KnownHostsStore: ObservableObject {
    static func prepare(file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(file.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), fchmod(fd, 0o600) == 0 else {
            throw MutyError("Host-key file must be a regular file owned by the current user.")
        }
    }
    @Published private(set) var entries: [KnownHostEntry] = []
    @Published private(set) var error: String?
    private(set) var file: URL
    private var snapshot: Data?
    private var lines: [String] = []
    @discardableResult func importFrom(_ source: URL) throws -> Int {
        guard source.resolvingSymlinksInPath() != file else { throw MutyError("Choose a different source host-key file.") }
        guard FileManager.default.fileExists(atPath: source.path) else { throw MutyError("OpenSSH known_hosts was not found.") }
        let imported = KnownHostsStore(file: source)
        if let error = imported.error { throw MutyError(error) }
        guard !imported.entries.isEmpty else { throw MutyError("No host keys were found in the source file.") }
        try Self.prepare(file: file)
        let fd = open(file.path, O_RDWR | O_APPEND | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw MutyError("Host-key file is busy. Try again.") }
        defer { _ = flock(fd, LOCK_UN) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let current = try handle.readToEnd() ?? Data()
        guard current.count <= 16_000_000,
              let text = String(data: current, encoding: .utf8) else { throw MutyError("Invalid host-key file.") }
        var existing = Set(text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        var additions: [String] = []
        for entry in imported.entries {
            let line = imported.lines[entry.id].trimmingCharacters(in: .whitespacesAndNewlines)
            if existing.insert(line).inserted { additions.append(line) }
        }
        guard !additions.isEmpty else { reload(); return 0 }
        let data = Data(((text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + additions.joined(separator: "\n") + "\n").utf8)
        guard current.count + data.count <= 16_000_000 else { throw MutyError("Host-key file exceeds 16 MB.") }
        if !current.isEmpty {
            try BackupArchive.write(current, to: file.appendingPathExtension("muty-backup-" + UUID().uuidString))
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        reload()
        return additions.count
    }
    init(file: URL) { self.file = file.resolvingSymlinksInPath(); reload() }
    func reload(file: URL? = nil) {
        if let file { self.file = file.resolvingSymlinksInPath() }
        entries = []; snapshot = nil; lines = []; error = nil
        do {
            guard FileManager.default.fileExists(atPath: self.file.path) else { return }
            let size = try self.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 16_000_000 else { throw MutyError("Host-key file exceeds 16 MB.") }
            let data = try Data(contentsOf: self.file)
            guard data.count <= 16_000_000, let text = String(data: data, encoding: .utf8) else { throw MutyError("Invalid host-key file.") }
            snapshot = data; lines = text.components(separatedBy: "\n")
            entries = lines.enumerated().compactMap { index, line in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard let first = fields.first, !first.hasPrefix("#") else { return nil }
                let offset = first.hasPrefix("@") ? 1 : 0
                guard fields.count >= offset + 3, let key = Data(base64Encoded: String(fields[offset + 2])), !key.isEmpty else { return nil }
                let fingerprint = "SHA256:" + Data(SHA256.hash(data: key)).base64EncodedString().replacingOccurrences(of: "=", with: "")
                return KnownHostEntry(id: index, hosts: String(fields[offset]), keyType: String(fields[offset + 1]),
                                      fingerprint: fingerprint, marker: offset == 1 ? String(first) : nil)
            }
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func remove(_ ids: Set<Int>) throws -> URL {
        guard let snapshot, error == nil, !ids.isEmpty, ids.isSubset(of: Set(entries.map(\.id))) else { throw MutyError("Reload the host-key file before removing entries.") }
        let fd = open(file.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw MutyError("Host-key file is busy. Try again.") }
        defer { _ = flock(fd, LOCK_UN) }
        var originalInfo = stat()
        guard fstat(fd, &originalInfo) == 0, (originalInfo.st_mode & S_IFMT) == S_IFREG else { throw MutyError("Invalid host-key file.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let current = try handle.readToEnd(), current.count <= 16_000_000,
              current.starts(with: snapshot) else { throw MutyError("Host-key file changed. Refresh before deleting.") }
        let backup = file.appendingPathExtension("muty-backup-" + UUID().uuidString)
        try BackupArchive.write(current, to: backup)
        var expected = snapshot
        var offset = 0
        for (index, line) in lines.enumerated() {
            if ids.contains(index) {
                var currentInfo = stat()
                guard stat(file.path, &currentInfo) == 0, currentInfo.st_ino == originalInfo.st_ino,
                      currentInfo.st_dev == originalInfo.st_dev, currentInfo.st_size >= snapshot.count else {
                    throw MutyError("Host-key file changed. Refresh before deleting.")
                }
                // Disabling a line in place preserves concurrent OpenSSH O_APPEND
                // writes. Replacing the whole file would discard those additions.
                var comment: UInt8 = 35
                guard pwrite(fd, &comment, 1, off_t(offset)) == 1 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                expected[offset] = comment
            }
            offset += line.utf8.count + 1
        }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var finalInfo = stat()
        guard stat(file.path, &finalInfo) == 0, finalInfo.st_ino == originalInfo.st_ino,
              finalInfo.st_dev == originalInfo.st_dev, try Data(contentsOf: file).starts(with: expected) else {
            throw MutyError("Host-key file changed during removal. Refresh the list; a backup was saved.")
        }
        reload()
        return backup
    }
}

struct KnownHostsSettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var store: KnownHostsStore
    @ViewState private var operationError: String?
    @ViewState private var query = ""
    @ViewState private var selection = Set<Int>()
    init(model: AppModel) {
        self.model = model
        _store = StateObject(wrappedValue: KnownHostsStore(file: SSHNetworking.knownHostsFile))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Host Keys").font(.title2.bold())
                Spacer()
                Button("Import from OpenSSH…", action: importOpenSSH).disabled(model.readOnly)
                Button("Refresh") {
                    selection = []
                    operationError = nil
                    store.reload()
                }
            }
            Text("muty uses its own known_hosts file. OpenSSH files are unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search host, [host]:port or fingerprint", text: $query)
                .textFieldStyle(.roundedBorder)
            List(selection: $selection) {
                ForEach(store.entries.filter { $0.matches(query) }) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.displayHost).lineLimit(1).help(entry.hosts)
                            Spacer()
                            Text(entry.keyType).font(.caption).foregroundStyle(.secondary)
                            if let marker = entry.marker { Text(marker).font(.caption).foregroundStyle(.orange) }
                        }
                        Text(entry.fingerprint).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }.tag(entry.id)
                }
            }
            HStack {
                Text("\(store.entries.count) stored keys").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show File") { NSWorkspace.shared.activateFileViewerSelecting([store.file]) }
                Button("Remove Selected…", role: .destructive, action: remove)
                    .disabled(selection.isEmpty || model.readOnly || store.error != nil)
            }
            Text("Hashed hosts can be found by their exact name. Removed entries are commented out and backed up; muty may ask to verify the server again.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = operationError ?? store.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding()
        .onChange(of: query) { _, _ in selection = [] }
    }
    private func importOpenSSH() {
        guard !model.readOnly, model.confirm("Import OpenSSH Host Keys?",
            text: "Trust the active entries from ~/.ssh/known_hosts in muty? Hashed names, certificate authorities and revoked-key markers are preserved. Existing muty entries are kept; the source file is unchanged.",
            action: "Import") else { return }
        do {
            let source = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")
            let count = try store.importFrom(source)
            selection = []
            operationError = nil
            model.operationStatus = "\(count) host keys imported into muty."
        } catch { operationError = error.localizedDescription }
    }
    private func remove() {
        guard !model.readOnly, model.confirm("Remove Stored Host Keys?", text: "Remove \(selection.count) entries from muty? Verify the server fingerprint before trusting a replacement key. A backup of the current file will be saved. OpenSSH files are unchanged.", action: "Remove") else { return }
        do {
            let backup = try store.remove(selection)
            selection = []
            operationError = nil
            model.operationStatus = "Host keys removed. Backup: " + backup.path
        } catch { operationError = error.localizedDescription }
    }
}
