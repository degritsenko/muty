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
    @Published private(set) var entries: [KnownHostEntry] = []
    @Published private(set) var error: String?
    private(set) var file: URL
    private var snapshot: Data?
    private var lines: [String] = []
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
    @ViewState private var query = ""
    @ViewState private var selection = Set<Int>()
    @ViewState private var source = 0
    private let files: [URL]
    init(model: AppModel) {
        self.model = model
        let home = FileManager.default.homeDirectoryForCurrentUser
        files = [home.appendingPathComponent(".ssh/known_hosts"), home.appendingPathComponent(".ssh/known_hosts2"),
                 URL(fileURLWithPath: "/etc/ssh/ssh_known_hosts"), URL(fileURLWithPath: "/etc/ssh/ssh_known_hosts2")]
        let initial = home.appendingPathComponent(".ssh/known_hosts")
        _store = StateObject(wrappedValue: KnownHostsStore(file: initial))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Host Keys").font(.title2.bold())
                Spacer()
                Button("Refresh") { selection = []; store.reload() }
            }
            Picker("File", selection: $source) {
                Text("User — known_hosts").tag(0)
                Text("User — known_hosts2").tag(1)
                Text("System — ssh_known_hosts (read-only)").tag(2)
                Text("System — ssh_known_hosts2 (read-only)").tag(3)
            }
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
                Button("Show File") { NSWorkspace.shared.activateFileViewerSelecting([files[source]]) }
                Button("Remove Selected…", role: .destructive, action: remove)
                    .disabled(selection.isEmpty || source >= 2 || store.error != nil)
            }
            Text("Shared with OpenSSH. Hashed hosts can be found by their exact name. Removed entries are commented out and backed up; SSH may ask to verify the server again.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding()
        .onChange(of: source) { _, value in selection = []; store.reload(file: files[value]) }
        .onChange(of: query) { _, _ in selection = [] }
    }
    private func remove() {
        guard source < 2, model.confirm("Remove Stored Host Keys?", text: "Remove \(selection.count) entries? Verify the server fingerprint before trusting a replacement key. A backup of the current file will be saved.", action: "Remove") else { return }
        do {
            let backup = try store.remove(selection)
            selection = []
            model.operationStatus = "Host keys removed. Backup: " + backup.path
        } catch { model.errorMessage = error.localizedDescription }
    }
}
