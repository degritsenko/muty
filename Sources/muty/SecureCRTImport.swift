import Foundation
import SwiftUI
import AppKit

struct SessionImportPreview: Identifiable, Sendable {
    let id = UUID()
    var profiles: [SessionProfile] = []
    var folders: [String] = []
    var skipped: [String] = []
    var passwords: [UUID: String] = [:]
    var credentials: [SavedCredential] = []
    var passwordWarnings: [String] = []
}

final class SecureCRTParser: NSObject, XMLParserDelegate {
    struct Frame { var name: String; var fields: [String: String] = [:] }
    private var configurationPassphrase = ""
    var stack: [Frame] = []
    var rawSessions: [(Frame, String?)] = []
    var rawCredentials: [Frame] = []
    var credentialsDepth: Int?
    var sessionsDepth: Int?
    var field: String?
    var text = ""
    var result = SessionImportPreview()
    var validRoot = false
    let allowed: Set<String> = ["Protocol Name", "Hostname", "Username", "[SSH2] Port", "Password V2", "Session Password Saved", "Credential Title"]

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if element == "VanDyke" { validRoot = true }
        if element == "key" {
            stack.append(Frame(name: attributes["name"] ?? ""))
            if stack.count == 1 && attributes["name"] == "Sessions" { sessionsDepth = stack.count }
            if stack.count == 1 && attributes["name"] == "Credentials" { credentialsDepth = stack.count }
        }
        if sessionsDepth != nil || credentialsDepth != nil, element != "key", let name = attributes["name"], allowed.contains(name) {
            field = name; text = ""
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field != nil { text += string }
    }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element != "key", let field, !stack.isEmpty {
            stack[stack.count - 1].fields[field] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.field = nil; text = ""
        }
        guard element == "key", let frame = stack.last else { return }
        if let depth = sessionsDepth, stack.count > depth {
            let path = stack.dropFirst(depth).map(\.name).joined(separator: "/")
            if let proto = frame.fields["Protocol Name"] {
                if proto == "SSH2" || proto == "Local Shell" {
                    let folder = SessionProfile.canonicalFolder(stack.dropFirst(depth).dropLast().map(\.name).joined(separator: "/"))
                    rawSessions.append((frame, folder))
                } else { result.skipped.append("\(path): unsupported protocol \(proto)") }
            } else if let folder = SessionProfile.canonicalFolder(path) { result.folders.append(folder) }
        }
        if let depth = credentialsDepth, stack.count == depth + 1 { rawCredentials.append(frame) }
        if stack.count == credentialsDepth { credentialsDepth = nil }
        if stack.count == sessionsDepth { sessionsDepth = nil }
        stack.removeLast()
    }
    private func finish() throws -> SessionImportPreview {
        guard rawSessions.count <= 10000, rawCredentials.count <= 10000 else {
            throw MutyError("SecureCRT backup exceeds 10,000 sessions or credentials.")
        }
        let passwordFrames = rawCredentials + rawSessions.compactMap { frame, _ in
            frame.fields["Protocol Name"] == "SSH2" && (frame.fields["Credential Title"] ?? "").isEmpty ? frame : nil
        }
        let encrypted = Set(passwordFrames.compactMap { frame -> String? in
            guard frame.fields["Session Password Saved"] == "1",
                  let value = frame.fields["Password V2"], !value.isEmpty else { return nil }
            return value
        })
        // Reject a missing/wrong passphrase before showing a partial import preview.
        // Check one value first so a wrong passphrase does not decrypt the whole backup.
        func decodeFailure() -> MutyError {
            MutyError("Cannot decrypt passwords in this SecureCRT backup. Enter the correct Configuration Passphrase and select the file again.")
        }
        var decoded: [String: Result<String, Error>] = [:]
        if let first = encrypted.sorted().first {
            do { decoded[first] = .success(try SecureCRTPassword.decrypt(first, configurationPassphrase: configurationPassphrase)) }
            catch { throw decodeFailure() }
            decoded.merge(SecureCRTPassword.decryptAll(encrypted.subtracting([first]), configurationPassphrase: configurationPassphrase)) { first, _ in first }
        }
        guard decoded.values.allSatisfy({ if case .success = $0 { return true }; return false }) else {
            throw decodeFailure()
        }
        func password(_ frame: Frame, path: String) -> String? {
            guard frame.fields["Session Password Saved"] == "1",
                  let value = frame.fields["Password V2"], !value.isEmpty else { return nil }
            do { let secret = try decoded[value]!.get(); return secret.isEmpty ? nil : secret }
            catch { result.passwordWarnings.append(path + ": " + error.localizedDescription); return nil }
        }
        var shared: [String: SavedCredential] = [:]
        var sharedUsernames: [String: String] = [:]
        for frame in rawCredentials {
            let title = frame.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if sharedUsernames[title] == nil {
                sharedUsernames[title] = (frame.fields["Username"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let secret = password(frame, path: "Credentials/" + frame.name) else { continue }
            do {
                let credential = try SavedCredential(title: frame.name, username: frame.fields["Username"] ?? "", password: secret).validated()
                guard shared[credential.title.lowercased()] == nil else { throw MutyError("Duplicate credential name.") }
                shared[credential.title.lowercased()] = credential
                result.credentials.append(credential)
            } catch { result.passwordWarnings.append("Credentials/" + frame.name + ": " + error.localizedDescription) }
        }
        var seen = Set<String>()
        for (frame, folder) in rawSessions {
            let path = [folder, frame.name].compactMap { $0 }.joined(separator: "/")
            var profile = SessionProfile()
            profile.name = frame.name; profile.folder = folder
            profile.connectionType = frame.fields["Protocol Name"] == "Local Shell" ? .localShell : .ssh
            profile.host = frame.fields["Hostname"] ?? ""
            profile.user = frame.fields["Username"] ?? ""
            profile.port = Int(frame.fields["[SSH2] Port"] ?? "22") ?? 0
            let title = frame.fields["Credential Title"] ?? ""
            if profile.connectionType == .ssh, !title.isEmpty {
                if let username = sharedUsernames[title.lowercased()] { profile.user = username }
                if let credential = shared[title.lowercased()] {
                    profile.credentialID = credential.id
                } else { result.passwordWarnings.append(path + ": shared credential unavailable; password not imported.") }
            }
            do {
                profile = try profile.validated()
                let identity = [profile.folder ?? "", profile.name].joined(separator: "\0")
                guard seen.insert(identity).inserted else { throw MutyError("Duplicate session path.") }
                result.profiles.append(profile)
                if profile.connectionType == .ssh, title.isEmpty, let secret = password(frame, path: path) {
                    result.passwords[profile.id] = secret
                }
            } catch { result.skipped.append(path + ": " + error.localizedDescription) }
        }
        return result
    }
    static func read(_ file: URL, configurationPassphrase: String = "") throws -> SessionImportPreview {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 50_000_000 else { throw MutyError("XML backup exceeds 50 MB.") }
        let data = try Data(contentsOf: file)
        guard data.count <= 50_000_000, data.range(of: Data("<!DOCTYPE".utf8)) == nil else {
            throw MutyError("Unsupported XML backup.")
        }
        let delegate = SecureCRTParser()
        delegate.configurationPassphrase = configurationPassphrase
        defer { delegate.configurationPassphrase = "" }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.validRoot else { throw MutyError("Invalid SecureCRT XML backup.") }
        return try delegate.finish()
    }
}

extension AppModel {
    func importSecureCRT(_ preview: SessionImportPreview, importPasswords: Bool, replacePasswords: Bool) throws {
        var backup = ConfigurationBackup(sessions: [], folders: preview.folders)
        var skipped = preview.skipped.count
        var omittedPasswords = preview.passwordWarnings.count
        var referenced = Set<UUID>()
        for profile in preview.profiles {
            var incoming = profile
            let existing = profiles.first { $0.name == incoming.name && $0.folder == incoming.folder }
            if let existing {
                guard existing.host == incoming.host, existing.port == incoming.port,
                      existing.user == incoming.user, existing.connectionType == incoming.connectionType else {
                    skipped += 1; continue
                }
                if existing.authentication != .password {
                    if incoming.credentialID != nil || preview.passwords[incoming.id] != nil { omittedPasswords += 1 }
                    incoming.credentialID = nil
                }
            }
            if importPasswords, incoming.connectionType == .ssh, existing == nil || existing?.authentication == .password {
                if let id = incoming.credentialID { referenced.insert(id) }
                else if let secret = preview.passwords[incoming.id] {
                    if existing?.credentialID == nil || replacePasswords { backup.restoredPasswords[incoming.id] = secret }
                    else { omittedPasswords += 1 }
                }
            }
            backup.sessions.append(PortableSession(incoming, keyName: nil, keyFingerprint: nil, includeCredentialLink: importPasswords))
        }
        if importPasswords {
            backup.restoredCredentials = preview.credentials.filter { referenced.contains($0.id) }
            // Standalone named credentials can also be imported without sessions.
            if preview.profiles.isEmpty { backup.restoredCredentials = preview.credentials }
        }
        try importConfiguration(backup, selected: Set(backup.sessions.map(\.id)), keyBindings: [:],
                                restorePasswords: importPasswords, replacePasswords: importPasswords && replacePasswords,
                                linkExistingCredentials: true)
        if skipped > 0 || omittedPasswords > 0 {
            operationStatus = (operationStatus ?? "Import complete.") + " \(skipped) sessions and \(omittedPasswords) unavailable/incompatible password records skipped."
        }
    }

    func chooseSecureCRTImport() {
        let panel = NSOpenPanel()
        panel.title = "Import SecureCRT XML"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 76))
        let label = NSTextField(labelWithString: "Configuration Passphrase (optional)")
        label.frame = NSRect(x: 0, y: 54, width: 440, height: 18)
        let passphraseField = NSSecureTextField(frame: NSRect(x: 0, y: 25, width: 440, height: 24))
        passphraseField.placeholderString = "Leave blank if not set in SecureCRT"
        let hint = NSTextField(labelWithString: "Used only to decrypt this XML; never saved in muty.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 0, y: 3, width: 440, height: 18)
        accessory.addSubview(label); accessory.addSubview(passphraseField); accessory.addSubview(hint)
        panel.accessoryView = accessory; panel.isAccessoryViewDisclosed = true
        defer { passphraseField.stringValue = "" }
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let passphrase = passphraseField.stringValue
        operationStatus = "Reading SecureCRT backup…"
        Task {
            do {
                let preview = try await Task.detached(priority: .userInitiated) { try SecureCRTParser.read(file, configurationPassphrase: passphrase) }.value
                operationStatus = nil
                importPreview = preview
            } catch { operationStatus = nil; errorMessage = error.localizedDescription }
        }
    }
}

struct SessionImportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let preview: SessionImportPreview
    @ViewState private var error: String?
    @ViewState private var importPasswords = false
    @ViewState private var replacePasswords = false
    private var ready: [SessionProfile] {
        preview.profiles.filter { candidate in
            !model.profiles.contains { $0.name == candidate.name && $0.folder == candidate.folder }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import SecureCRT Sessions").font(.title2.bold())
            Text("\(ready.count) ready · \(preview.skipped.count) invalid or unsupported · \(preview.profiles.count - ready.count) already exist")
            Text("SSH keys, scripts and tunnels are excluded. Existing sessions are matched by folder, name, host, port and username. No sessions connect automatically.").font(.caption).foregroundStyle(.secondary)
            Toggle("Import passwords (\(preview.passwords.count) session passwords, \(preview.credentials.count) shared credentials)", isOn: $importPasswords)
                .disabled(preview.passwords.isEmpty && preview.credentials.isEmpty)
            if importPasswords {
                Toggle("Replace existing passwords and credential assignments", isOn: $replacePasswords)
                Text("Existing SSH Key sessions are kept unchanged. Replacing a shared password affects all sessions using that credential.").font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(preview.profiles) { profile in
                    VStack(alignment: .leading) {
                        Text([profile.folder, profile.name].compactMap { $0 }.joined(separator: "/"))
                        Text(profile.endpoint).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(preview.passwordWarnings.enumerated()), id: \.offset) { _, reason in
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
                ForEach(Array(preview.skipped.enumerated()), id: \.offset) { _, reason in
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
            }.frame(height: 300)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Import") {
                    do { try model.importSecureCRT(preview, importPasswords: importPasswords, replacePasswords: replacePasswords); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.disabled(model.readOnly || (preview.profiles.isEmpty && preview.folders.isEmpty && (!importPasswords || preview.credentials.isEmpty)))
            }
        }.padding(24).frame(width: 620)
    }
}
