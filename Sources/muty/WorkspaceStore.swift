import Foundation

struct WorkspaceDocument: Codable {
    struct Tab: Codable {
        var profileID: UUID
        var name: String?
        var buttonBarSelection: ButtonBarSelection? = nil
    }
    struct Split: Codable {
        var mode: String
        var slots: [Int?]
        var activeIndex: Int
        var columnFraction: CGFloat? = nil
        var rowFraction: CGFloat? = nil
        var groups: [[Int]]? = nil
    }
    var version = 1
    var tabs: [Tab]
    var selectedIndex: Int?
    var split: Split? = nil
}
struct WorkspaceStore {
    enum LimitError: LocalizedError {
        case fileSize
        case tabCount(maximum: Int)

        var errorDescription: String? {
            switch self {
            case .fileSize: return "Workspace file is too large."
            case .tabCount(let maximum): return "Workspace exceeds \(maximum) tabs."
            }
        }
    }

    private static let maxBytes = 1_000_000
    private static let maxTabs = 500
    let directory: URL
    private var file: URL { directory.appendingPathComponent("workspace.json") }
    func load() throws -> WorkspaceDocument? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        try validateSize(data)
        let document = try JSONDecoder().decode(WorkspaceDocument.self, from: data)
        try validate(document)
        return document
    }
    func save(_ document: WorkspaceDocument) throws {
        try validate(document)
        let data = try JSONEncoder().encode(document)
        try validateSize(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func validate(_ document: WorkspaceDocument) throws {
        guard document.version == 1 else { throw MutyError("Unsupported workspace file.") }
        guard document.tabs.count <= Self.maxTabs else { throw LimitError.tabCount(maximum: Self.maxTabs) }
    }
    private func validateSize(_ data: Data) throws {
        guard data.count <= Self.maxBytes else { throw LimitError.fileSize }
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
