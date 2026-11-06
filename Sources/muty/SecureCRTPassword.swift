import Foundation
import CryptoKit
import CommonCrypto
import SecureCRTSupport

// Import-only decoder. Never logs, persists or includes secret input in errors.
enum SecureCRTPassword {
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Result<String, Error>] = [:]
        func store(_ value: String, result: Result<String, Error>) {
            lock.lock(); defer { lock.unlock() }; values[value] = result
        }
        func snapshot() -> [String: Result<String, Error>] {
            lock.lock(); defer { lock.unlock() }; return values
        }
    }
    static func decryptAll(_ values: Set<String>, configurationPassphrase: String = "") -> [String: Result<String, Error>] {
        let results = Results()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = min(4, ProcessInfo.processInfo.activeProcessorCount)
        for value in values {
            queue.addOperation { results.store(value, result: Result { try decrypt(value, configurationPassphrase: configurationPassphrase) }) }
        }
        queue.waitUntilAllOperationsAreFinished()
        return results.snapshot()
    }

    static func decrypt(_ value: String, configurationPassphrase: String = "") throws -> String {
        guard configurationPassphrase.utf8.count <= 4096 else {
            throw MutyError("Configuration Passphrase must be at most 4096 UTF-8 bytes.")
        }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, ["02", "03"].contains(parts[0]),
              parts[1].count <= 8192, parts[1].count.isMultiple(of: 2) else {
            throw MutyError("Unsupported SecureCRT password format.")
        }
        var bytes = [UInt8]()
        var index = parts[1].startIndex
        while index < parts[1].endIndex {
            let next = parts[1].index(index, offsetBy: 2)
            guard let byte = UInt8(parts[1][index..<next], radix: 16) else {
                throw MutyError("Invalid SecureCRT password encoding.")
            }
            bytes.append(byte); index = next
        }
        var key: [UInt8]
        var iv: [UInt8]
        if parts[0] == "03" {
            guard bytes.count >= 32 else { throw MutyError("Invalid SecureCRT password length.") }
            let salt = Array(bytes.prefix(16))
            var derived = [UInt8](repeating: 0, count: 48)
            let status = configurationPassphrase.withCString { pass in
                salt.withUnsafeBufferPointer { salt in
                    derived.withUnsafeMutableBufferPointer { output in
                        muty_securecrt_bcrypt_pbkdf(pass, configurationPassphrase.utf8.count, salt.baseAddress!, salt.count,
                                                   output.baseAddress!, output.count, 16)
                    }
                }
            }
            guard status == 0 else { throw MutyError("SecureCRT key derivation failed.") }
            key = Array(derived.prefix(32)); iv = Array(derived.suffix(16))
            _ = derived.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            bytes.removeFirst(16)
        } else {
            key = Array(SHA256.hash(data: Data(configurationPassphrase.utf8))); iv = .init(repeating: 0, count: 16)
        }
        defer {
            _ = key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            _ = iv.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        }
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 16) else {
            throw MutyError("Invalid SecureCRT password length.")
        }
        var plain = [UInt8](repeating: 0, count: bytes.count)
        defer { _ = plain.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var written = 0
        let status = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { iv in
                bytes.withUnsafeBytes { input in
                    plain.withUnsafeMutableBytes { output in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                k.baseAddress, k.count, iv.baseAddress, input.baseAddress,
                                input.count, output.baseAddress, output.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess, written >= 36 else { throw MutyError("SecureCRT password decryption failed.") }
        let length = Int(plain[0]) | Int(plain[1]) << 8 | Int(plain[2]) << 16 | Int(plain[3]) << 24
        guard length <= 1023, 4 + length + 32 <= written else {
            throw MutyError("Cannot decrypt SecureCRT password. Check the Configuration Passphrase.")
        }
        let end = 4 + length
        var padding = 16 - (end + 32) % 16
        if padding < 8 { padding += 16 }
        let payload = Data(plain[4..<end])
        guard written == end + 32 + padding,
              Array(SHA256.hash(data: payload)) == Array(plain[end..<(end + 32)]),
              let password = String(data: payload, encoding: .utf8) else {
            throw MutyError("SecureCRT password integrity check failed. Check the Configuration Passphrase.")
        }
        // Empty stored values are ignored by the importer.
        if !password.isEmpty { try VaultStore.validatePassword(password) }
        return password
    }
}
