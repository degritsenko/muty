import Foundation

protocol CredentialStore {
    func read(id: UUID) throws -> String?
    func write(id: UUID, password: String) throws
    func delete(id: UUID) throws
    func write(id: UUID, password: String, name: String, endpoint: String) throws
}
extension CredentialStore {
    func write(id: UUID, password: String, name: String, endpoint: String) throws { try write(id: id, password: password) }
}
