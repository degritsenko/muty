import Foundation

struct WorkspaceDocument: Codable {
    struct Tab: Codable {
        var profileID: UUID
        var name: String?
    }
    var version = 1
    var tabs: [Tab]
    var selectedIndex: Int?
}
struct WorkspaceStore {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("workspace.json") }
    func load() throws -> WorkspaceDocument? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        guard data.count <= 1_000_000 else { throw MutyError("Workspace file is too large.") }
        let document = try JSONDecoder().decode(WorkspaceDocument.self, from: data)
        guard document.version == 1, document.tabs.count <= 500 else { throw MutyError("Unsupported workspace file.") }
        return document
    }
    func save(_ document: WorkspaceDocument) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(document).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
