import Combine
import CryptoKit
import Foundation
import SQLite3

@MainActor
final class SFTPTransferQueueStore: ObservableObject {
    private var database: OpaquePointer?
    @Published private(set) var recovered: [SFTPTransfer] = []
    private var loadError: Error?
    private let encoder = JSONEncoder()

    init(directory: URL, scope: String) {
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = directory.appendingPathComponent("sftp-queues", isDirectory: true)
        let file = folder.appendingPathComponent(name + ".sqlite")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try check(sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil))
            try execute("PRAGMA journal_mode = WAL")
            try execute("CREATE TABLE IF NOT EXISTS transfers (id TEXT UNIQUE NOT NULL, payload BLOB NOT NULL)")
            try statement("SELECT payload FROM transfers ORDER BY rowid") { query in
                let decoder = JSONDecoder()
                while true {
                    let result = sqlite3_step(query)
                    if result == SQLITE_DONE { break }
                    try check(result, expected: SQLITE_ROW)
                    guard let bytes = sqlite3_column_blob(query, 0) else { throw MutyError("Missing transfer record.") }
                    let payload = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
                    recovered.append(try decoder.decode(SFTPTransfer.self, from: payload))
                }
            }
        } catch {
            recovered.removeAll()
            loadError = error
        }
    }

    deinit { sqlite3_close(database) }

    func makeQueue() -> SFTPTransferQueue {
        SFTPTransferQueue(recoveryStore: self, loadError: loadError) { [self] updated, removed in
            try save(updated: updated, removed: removed)
        }
    }

    func takeRecovered() -> [SFTPTransfer] {
        let items = recovered
        recovered.removeAll()
        return items
    }

    func returnForRecovery(_ items: [SFTPTransfer]) {
        recovered.append(contentsOf: items)
    }

    private func save(updated: [SFTPTransfer], removed: [UUID]) throws {
        if let loadError { throw loadError }
        try execute("BEGIN IMMEDIATE")
        do {
            if !updated.isEmpty {
                try statement("""
                    INSERT INTO transfers (id, payload) VALUES (?1, ?2)
                    ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                    """) { query in
                    for item in updated {
                        try bind(item.id, to: query)
                        let payload = try encoder.encode(item)
                        try payload.withUnsafeBytes { bytes in
                            try check(sqlite3_bind_blob(query, 2, bytes.baseAddress, Int32(bytes.count), Self.transient))
                        }
                        try stepAndReset(query)
                    }
                }
            }
            if !removed.isEmpty {
                try statement("DELETE FROM transfers WHERE id = ?1") { query in
                    for id in removed {
                        try bind(id, to: query)
                        try stepAndReset(query)
                    }
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ id: UUID, to query: OpaquePointer) throws {
        try check(sqlite3_bind_text(query, 1, id.uuidString, -1, Self.transient))
    }

    private func stepAndReset(_ query: OpaquePointer) throws {
        try check(sqlite3_step(query), expected: SQLITE_DONE)
        try check(sqlite3_reset(query))
    }

    private func statement(_ sql: String, body: (OpaquePointer) throws -> Void) throws {
        var query: OpaquePointer?
        try check(sqlite3_prepare_v2(database, sql, -1, &query, nil))
        guard let query else { throw MutyError("Could not prepare transfer queue statement.") }
        defer { sqlite3_finalize(query) }
        try body(query)
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(database, sql, nil, nil, nil))
    }

    private func check(_ result: Int32, expected: Int32 = SQLITE_OK) throws {
        guard result == expected else {
            let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "SQLite error \(result)."
            throw MutyError(message)
        }
    }
}
