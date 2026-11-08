import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MobaXtermImport: Identifiable, Sendable {
    let id = UUID()
    private(set) var sessions: [SessionProfile] = []
    private(set) var folders: [String] = []
    private(set) var skipped = 0

    static func read(_ file: URL) throws -> Self {
        let data = try BackupArchive.load(file)
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252) else {
            throw MutyError("Unsupported MobaXterm file encoding.")
        }
        return try parse(text)
    }

    static func parse(_ text: String) throws -> Self {
        var result = Self()
        var inBookmarks = false
        var foundBookmarks = false
        var folder: String?
        for raw in text.drop(while: { $0 == "\u{FEFF}" }).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let section = line.dropFirst().dropLast()
                inBookmarks = section == "Bookmarks"
                    || (section.hasPrefix("Bookmarks_") && Int(section.dropFirst("Bookmarks_".count)) != nil)
                foundBookmarks = foundBookmarks || inBookmarks
                folder = nil
                continue
            }
            guard inBookmarks, !line.hasPrefix(";"), !line.hasPrefix("#"),
                  let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...]
            if name == "SubRep" {
                folder = SessionProfile.canonicalFolder(value.replacingOccurrences(of: "\\", with: "/"))
                if let folder, folder != "__favorites" { result.folders.append(folder) }
                continue
            }
            if name == "ImgNum" { continue }
            guard result.sessions.count + result.skipped < 10_000 else {
                throw MutyError("MobaXterm export exceeds 10,000 sessions.")
            }
            let groups = value.split(separator: "#", maxSplits: 3, omittingEmptySubsequences: false)
            guard groups.count >= 3, !name.isEmpty, folder != "__favorites" else {
                result.skipped += 1
                continue
            }
            let fields = groups[2].split(separator: "%", omittingEmptySubsequences: false)
            guard fields.count >= 4, fields[0] == "0", let port = Int(fields[2]) else {
                result.skipped += 1
                continue
            }
            let hasGateway = fields.count > 8 && !fields[8].trimmingCharacters(in: .whitespaces).isEmpty
            let hasProxy = fields.count > 19 && !["", "0"].contains(fields[19].trimmingCharacters(in: .whitespaces))
            guard !hasGateway, !hasProxy else {
                result.skipped += 1
                continue
            }
            var profile = SessionProfile()
            profile.name = name
            profile.folder = folder
            profile.host = String(fields[1])
            profile.port = port
            profile.user = fields[3].trimmingCharacters(in: .whitespaces)
            let needsUsername = profile.user.isEmpty || profile.user.caseInsensitiveCompare("<default>") == .orderedSame
            if needsUsername { profile.user = "placeholder" }
            guard var validated = try? profile.validated() else {
                result.skipped += 1
                continue
            }
            if needsUsername { validated.user = "" }
            result.sessions.append(validated)
        }
        guard foundBookmarks else { throw MutyError("No bookmark sections found in the MobaXterm export.") }
        result.folders = Set(result.folders).sorted()
        return result
    }
}

extension AppModel {
    func chooseMobaXtermImport() {
        let panel = NSOpenPanel()
        panel.title = L("Import MobaXterm Sessions")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: "mxtsessions") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let file = panel.url else { return }
        operationStatus = "Reading MobaXterm sessions…"
        Task {
            defer { operationStatus = nil }
            do {
                mobaXtermImport = try await Task.detached(priority: .userInitiated) { try MobaXtermImport.read(file) }.value
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

struct MobaXtermImportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let preview: MobaXtermImport
    @ViewState private var username = ""
    @ViewState private var error: String?

    private struct SessionName: Hashable {
        let folder: String?
        let name: String
        init(_ profile: SessionProfile) {
            folder = profile.folder
            name = profile.name
        }
    }

    private var fallbackUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var missingUsernames: Int { preview.sessions.filter { $0.user.isEmpty }.count }
    private var validFallback: Bool {
        guard !fallbackUsername.isEmpty else { return true }
        var profile = SessionProfile()
        profile.host = "example.invalid"
        profile.user = fallbackUsername
        return (try? profile.validated()) != nil
    }

    var body: some View {
        let canUseFallback = validFallback && !fallbackUsername.isEmpty
        let candidates = preview.sessions.compactMap { source -> SessionProfile? in
            guard source.user.isEmpty else { return source }
            guard canUseFallback else { return nil }
            var profile = source
            profile.user = fallbackUsername
            return profile
        }
        var occupied = Set(model.profiles.map(SessionName.init))
        let ready = candidates.filter { occupied.insert(SessionName($0)).inserted }
        let readyIDs = Set(ready.map(\.id))

        return VStack(alignment: .leading, spacing: 12) {
            Text("Import MobaXterm Sessions").font(.title2.bold())
            Text(LF("%ld ready · %ld duplicate names in the same folder · %ld invalid or unsupported", ready.count, candidates.count - ready.count, preview.skipped))
            if missingUsernames > 0 {
                TextField(LF("Username for %ld sessions", missingUsernames), text: $username)
                Text(validFallback ? L("Leave blank to skip sessions without a username.") : L("Enter a valid SSH username."))
                    .font(.caption).foregroundStyle(validFallback ? Color.secondary : .red)
            }
            List(preview.sessions) { profile in
                VStack(alignment: .leading) {
                    Text([profile.folder, profile.name].compactMap { $0 }.joined(separator: "/"))
                    Text(profile.host + ":" + String(profile.port) + " · " + (profile.user.isEmpty ? (fallbackUsername.isEmpty ? L("Username missing") : fallbackUsername) : profile.user))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .foregroundStyle(readyIDs.contains(profile.id) ? Color.primary : .secondary)
            }.frame(height: 300)
            if let error { Text(L(error)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Import") {
                    let backup = ConfigurationBackup(
                        sessions: ready.map { PortableSession($0, keyName: nil, keyFingerprint: nil) },
                        folders: preview.folders
                    )
                    do {
                        try model.importConfiguration(backup, selected: readyIDs, keyBindings: [:])
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.disabled(model.readOnly || !validFallback || (ready.isEmpty && preview.folders.isEmpty))
            }
        }.padding(24).frame(width: 640)
    }
}
