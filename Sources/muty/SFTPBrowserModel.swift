import Foundation
import AppKit
import Darwin

struct SFTPBookmark: Codable, Identifiable {
    var id = UUID()
    let name: String
    let localPath: String
    let remotePath: String
}

@MainActor final class SFTPBookmarks: ObservableObject {
    static let shared = SFTPBookmarks()
    @Published private(set) var byDestination: [String: [SFTPBookmark]]
    private let key = "sftp-bookmarks"

    private init() {
        byDestination = UserDefaults.standard.data(forKey: "sftp-bookmarks")
            .flatMap { try? JSONDecoder().decode([String: [SFTPBookmark]].self, from: $0) } ?? [:]
    }

    func save(_ bookmarks: [SFTPBookmark], for destination: String) throws {
        var updated = byDestination
        updated[destination] = bookmarks.isEmpty ? nil : bookmarks
        UserDefaults.standard.set(try JSONEncoder().encode(updated), forKey: key)
        byDestination = updated
    }
}

@MainActor final class SFTPBrowserModel: ObservableObject {
    let id = UUID()
    let transferQueue: SFTPTransferQueue
    private let endpoint: String?
    private let sessionID: UUID
    let bookmarkDestination: String?
    @Published private(set) var localPath = FileManager.default.homeDirectoryForCurrentUser.path
    @Published private(set) var remotePath = ""
    @Published private(set) var localFiles: [BrowserFile] = []
    @Published private(set) var remoteFiles: [BrowserFile] = []
    @Published var localSelection = Set<String>()
    @Published var remoteSelection = Set<String>()
    @Published var showHidden = true { didSet { localSelection = []; remoteSelection = [] } }
    @Published private(set) var busy = false
    @Published private(set) var disconnected = false
    @Published private(set) var progress: SFTPProgress?
    @Published private(set) var status = ""
    @Published var error: String?
    private let client: SFTPClient
    private var job: Task<Void, Never>?
    private var removalJob: Task<Void, Never>?
    private var removalClient: SFTPClient?
    private var removalNeedsRefresh = false
    private var removalError: String?
    @Published private(set) var removing = false
    @Published private(set) var removalPath = ""
    private struct EditorKey: Hashable {
        let path: String
        let readOnly: Bool
    }
    private var editors: [EditorKey: RemoteTextEditor] = [:]
    private weak var app: AppModel?
    var visibleLocal: [BrowserFile] { localFiles.filter { showHidden || !$0.name.hasPrefix(".") } }
    var visibleRemote: [BrowserFile] { remoteFiles.filter { showHidden || !$0.name.hasPrefix(".") } }
    init(client: SFTPClient, app: AppModel, sessionID: UUID, transferQueue: SFTPTransferQueue, endpoint: String? = nil, jumpEndpoint: String? = nil, temporary: Bool = false) {
        self.endpoint = endpoint
        let bookmarkScope = temporary ? "quick-connect" : sessionID.uuidString
        bookmarkDestination = endpoint.map { bookmarkScope + "|" + String($0.count) + ":" + $0 + (jumpEndpoint ?? "") }
        self.client = client; self.app = app; self.sessionID = sessionID
        self.transferQueue = transferQueue
        transferQueue.attach(owner: id, executor: SFTPTransferAdapter(client: client))
        let saved = UserDefaults.standard.string(forKey: "sftp-local-" + sessionID.uuidString)
        navigateLocal(transferQueue.localPath ?? saved ?? localPath)
    }
    func promptForBookmark() {
        let alert = NSAlert()
        alert.messageText = "Add SFTP Bookmark"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name"
        field.setAccessibilityLabel("Bookmark name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { saveBookmark(named: field.stringValue) }
    }

    private func saveBookmark(named input: String) {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !disconnected, !name.isEmpty, let bookmarkDestination, !remotePath.isEmpty else { return }
        let store = SFTPBookmarks.shared
        let bookmarks = store.byDestination[bookmarkDestination] ?? []
        guard !bookmarks.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            error = "A bookmark with that name already exists."
            return
        }
        do {
            try store.save(bookmarks + [SFTPBookmark(name: name, localPath: localPath, remotePath: remotePath)],
                           for: bookmarkDestination)
        } catch { self.error = error.localizedDescription }
    }

    func removeBookmark(_ bookmark: SFTPBookmark) {
        guard let bookmarkDestination else { return }
        let store = SFTPBookmarks.shared
        do {
            try store.save((store.byDestination[bookmarkDestination] ?? []).filter { $0.id != bookmark.id },
                           for: bookmarkDestination)
        } catch { self.error = error.localizedDescription }
    }

    func openBookmark(_ bookmark: SFTPBookmark) {
        guard !busy, !disconnected else { return }
        do {
            let local = try readLocalDirectory(bookmark.localPath)
            run("Opening bookmark…", work: { client in
                let path = try client.canonical(bookmark.remotePath)
                return (path, try client.list(path))
            }) { [weak self] remote in
                self?.applyLocalDirectory(local)
                self?.applyRemoteDirectory(remote)
            }
        } catch { self.error = error.localizedDescription }
    }

    func start() {
        if remotePath.isEmpty && !busy && !disconnected {
            let saved = UserDefaults.standard.string(forKey: "sftp-remote-" + sessionID.uuidString)
            navigateRemote(transferQueue.remotePath ?? saved ?? ".", restoring: true)
        }
    }
    func disconnect() {
        disconnected = true
        transferQueue.detach(owner: id)
        job?.cancel()
        removalJob?.cancel()
        removalClient?.shutdown()
        client.shutdown()
        editors.values.forEach { $0.connectionEnded() }
    }
    func cancel() {
        transferQueue.cancel(owner: id)
        job?.cancel(); client.cancel()
        removalJob?.cancel(); removalClient?.cancel()
    }
    func navigateLocal(_ path: String) {
        guard !busy else { return }
        do { applyLocalDirectory(try readLocalDirectory(path)) }
        catch { self.error = error.localizedDescription }
    }

    private func readLocalDirectory(_ path: String) throws -> (path: String, files: [BrowserFile]) {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true).resolvingSymlinksInPath()
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        let entries = try urls.map { item in
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            return BrowserFile(name: item.lastPathComponent, path: item.path,
                               isDirectory: values.isDirectory == true && values.isSymbolicLink != true,
                               isSymlink: values.isSymbolicLink == true,
                               size: values.fileSize.map { UInt64(max(0, $0)) }, modified: values.contentModificationDate)
        }
        return (url.path, BrowserFile.sorted(entries))
    }

    private func applyLocalDirectory(_ directory: (path: String, files: [BrowserFile])) {
        localPath = directory.path; transferQueue.localPath = directory.path
        UserDefaults.standard.set(directory.path, forKey: "sftp-local-" + sessionID.uuidString)
        localFiles = directory.files; localSelection = []; error = nil
    }
    func localUp() { navigateLocal((localPath as NSString).deletingLastPathComponent) }
    func localHome() { navigateLocal(FileManager.default.homeDirectoryForCurrentUser.path) }
    func remoteUp() { navigateRemote((remotePath as NSString).deletingLastPathComponent) }
    func goRemoteHome() { navigateRemote(".") }
    func navigateRemote(_ path: String, restoring: Bool = false) {
        run("Loading directory…", work: { client in
            do {
                let canonical = try client.canonical(path.isEmpty ? "." : path)
                return (canonical, try client.list(canonical))
            } catch is SFTPStatus where restoring && path != "." {
                let home = try client.canonical(".")
                return (home, try client.list(home))
            }
        }) { [weak self] value in self?.applyRemoteDirectory(value) }
    }

    private func applyRemoteDirectory(_ directory: (path: String, files: [BrowserFile])) {
        remotePath = directory.path; transferQueue.remotePath = directory.path
        UserDefaults.standard.set(directory.path, forKey: "sftp-remote-" + sessionID.uuidString)
        remoteFiles = directory.files; remoteSelection = []
        status = ""
    }

    func refresh() {
        guard !busy else { return }
        navigateLocal(localPath)
        if !disconnected { navigateRemote(remotePath.isEmpty ? "." : remotePath) }
    }
    private func run<T>(_ title: String, refreshAfter: Bool = false,
                        work: @escaping (SFTPClient) throws -> T, success: @escaping (T) -> Void = { _ in }) {
        guard !busy, !disconnected else { return }
        busy = true; progress = nil; error = nil; status = title
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await client.perform(work)
                try Task.checkCancellation()
                status = "Completed"; success(value)
            } catch is CancellationError { status = "Cancelled" }
            catch { self.error = error.localizedDescription; status = "Failed" }
            busy = false; progress = nil; job = nil
            if !refreshAfter {
                refreshAfterRemovalIfNeeded()
                processTransfers()
            }
            if refreshAfter && !disconnected {
                let message = error
                navigateLocal(localPath)
                error = message
                // Refresh after cancelled/failed transfers too; staged files are
                // cleaned through the next SFTP channel before listing.
                let lastStatus = status
                let directory = remotePath
                run("Refreshing…", work: { client in try client.list(directory) }) { entries in
                    self.remoteFiles = entries; self.remoteSelection = []; self.status = lastStatus
                    self.error = message
                }
            }
        }
    }
    private struct FileClipboard {
        let id = UUID()
        var files: [BrowserFile]
        let remote: Bool
        let cut: Bool
    }
    @Published private var fileClipboard: FileClipboard?
    var canPasteFiles: Bool { fileClipboard != nil && !busy && !disconnected && !removing }

    func copyFiles(_ ids: Set<String>, remote: Bool, cut: Bool) {
        let files = (remote ? remoteFiles : localFiles).filter { ids.contains($0.id) }
        guard !files.isEmpty else { return }
        fileClipboard = FileClipboard(files: files, remote: remote, cut: cut)
    }

    func pasteFiles(remote: Bool) {
        guard canPasteFiles, let clipboard = fileClipboard else { return }
        let destination = remote ? remotePath : localPath
        guard !destination.isEmpty else { return }
        let action = clipboard.cut ? "Moving" : "Copying"
        let sink = SFTPProgressSink { [weak self] in self?.progress = $0 }
        let report: (String, UInt64, UInt64?) -> Void = { name, bytes, total in
            sink.update(name: action + "… " + name, bytes: bytes, total: total)
        }
        let removalProgress: (String) -> Void = { path in
            sink.update(name: "Removing… " + path, bytes: 1, total: nil)
        }
        let completeMove: (BrowserFile) -> Void = { [weak self] file in
            DispatchQueue.main.async { [weak self = self] in
                guard let self, self.fileClipboard?.id == clipboard.id else { return }
                self.fileClipboard?.files.removeAll { $0.id == file.id }
                if self.fileClipboard?.files.isEmpty == true { self.fileClipboard = nil }
            }
        }
        run(action + "…", refreshAfter: true, work: { client in
            for file in clipboard.files {
                try client.checkCancellation()
                report(file.path, 0, nil)
                var target = try BrowserFile.join(destination, file.name)
                if clipboard.remote == remote, file.isDirectory,
                   target.hasPrefix(file.path + "/") {
                    throw MutyError("A folder cannot be pasted into itself or its subfolders.")
                }
                let exists: (String) throws -> Bool = { path in
                    if remote { return try client.attributes(path) != nil }
                    return FileManager.default.fileExists(atPath: path)
                }
                if clipboard.cut && clipboard.remote == remote && target == file.path { continue }
                if try exists(target) {
                    target = try self.availableCopyDestination(target, exists: exists)
                }
                var moveSnapshot: [String: BrowserFile] = [:]
                if clipboard.cut && clipboard.remote != remote {
                    if clipboard.remote { moveSnapshot = try client.moveSourceSnapshot(file.path) }
                    else {
                        let entries = try SFTPMoveVerification.snapshot(URL(fileURLWithPath: file.path), checkCancellation: client.checkCancellation)
                        moveSnapshot = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
                    }
                }
                if clipboard.remote && remote && clipboard.cut {
                    try client.rename(file.path, target)
                } else if !clipboard.remote && !remote {
                    if clipboard.cut { try FileManager.default.moveItem(atPath: file.path, toPath: target) }
                    else { try FileManager.default.copyItem(atPath: file.path, toPath: target) }
                } else {
                    let staging = FileManager.default.temporaryDirectory.appendingPathComponent("muty-paste-" + UUID().uuidString, isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    if clipboard.remote {
                        if remote, try client.copyRemote(file.path, to: target, progress: report) {
                            // Server-side copy completed without local staging.
                        } else if remote {
                            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                            let temporary = staging.appendingPathComponent("item", isDirectory: file.isDirectory)
                            try client.download(file.path, to: temporary, replace: false, progress: report)
                            try client.upload(temporary, to: target, replace: false, progress: report)
                        } else {
                            try client.download(file.path, to: URL(fileURLWithPath: target), replace: false, progress: report)
                        }
                    } else {
                        try client.upload(URL(fileURLWithPath: file.path), to: target, replace: false, progress: report)
                    }
                    if clipboard.cut {
                        completeMove(file)
                        do {
                            if clipboard.remote {
                                if try client.attributes(file.path) != nil {
                                    try client.removeTree(file.path, expected: moveSnapshot, progress: removalProgress)
                                }
                            } else {
                                try SFTPMoveVerification.remove(Array(moveSnapshot.values), checkCancellation: client.checkCancellation,
                                                                progress: removalProgress)
                            }
                        } catch {
                            let message = "Copy saved at " + target + ". Source cleanup incomplete at " +
                                          file.path + ". " + error.localizedDescription
                            DispatchQueue.main.sync { [weak self = self] in self?.error = message }
                            throw MutyError(message)
                        }
                        continue
                    }
                }
                if clipboard.cut { completeMove(file) }
            }
        })
    }

    private func availableCopyDestination(_ path: String, exists: (String) throws -> Bool) throws -> String {
        let source = URL(fileURLWithPath: path)
        let parent = source.deletingLastPathComponent().path
        let name = source.lastPathComponent
        let ext = source.pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        for index in 1...10_000 {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            let candidateName = ext.isEmpty ? stem + suffix : stem + suffix + "." + ext
            let candidate = try BrowserFile.join(parent, candidateName)
            if try !exists(candidate) { return candidate }
        }
        throw MutyError("Could not choose a free copy name for " + name)
    }

    func uploadSelection() { upload(localFiles.filter { localSelection.contains($0.id) }.map { URL(fileURLWithPath: $0.path) }) }
    func upload(_ files: [URL]) {
        guard !files.isEmpty, !busy, !disconnected, !remotePath.isEmpty else { return }
        let destination = remotePath
        guard confirm("Copy to Remote?", files.map(\.lastPathComponent).joined(separator: "\n") + "\n\nDestination: " + destination, action: "Copy") else { return }
        processTransfers(request: .upload(files, to: destination))
    }
    func downloadSelection() { download(remoteFiles.filter { remoteSelection.contains($0.id) }) }
    func download(_ files: [BrowserFile]) {
        guard !files.isEmpty, !busy, !disconnected else { return }
        let destination = localPath
        guard confirm("Copy to Local?", files.map(\.name).joined(separator: "\n") + "\n\nDestination: " + destination, action: "Copy") else { return }
        processTransfers(request: .download(files, to: destination))
    }
    func pauseTransfers() { transferQueue.pause(owner: id) }
    func resumeTransfers() {
        transferQueue.resume(owner: id)
        processTransfers()
    }
    func retryTransfers(id: UUID? = nil) {
        guard !busy, !disconnected else { return }
        transferQueue.retry(owner: self.id, id: id)
        processTransfers()
    }
    private func resolveConflict(_ transfer: SFTPTransfer) -> SFTPConflictResolution {
        let alert = NSAlert(); alert.messageText = "File already exists"
        alert.informativeText = transfer.destination
        alert.addButton(withTitle: "Replace"); alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Keep Both"); alert.addButton(withTitle: "Cancel Queue")
        alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Apply to all conflicts in this batch"
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let choices: [SFTPConflictResolution.Choice] = [.replace, .skip, .keepBoth, .cancel]
        return SFTPConflictResolution(choice: choices.indices.contains(index) ? choices[index] : .cancel,
                                      applyToAll: alert.suppressionButton?.state == .on)
    }
    private func processTransfers(request: SFTPTransferRequest? = nil) {
        guard !busy, !disconnected, !remotePath.isEmpty,
              request != nil || (transferQueue.hasPending && !transferQueue.paused) else { return }
        busy = true; progress = nil
        if let request {
            error = nil
            switch request {
            case .upload: status = "Preparing uploads…"
            case .download: status = "Preparing downloads…"
            }
        }
        job = Task { [self] in
            do {
                try await transferQueue.run(owner: id, request: request, resolveConflict: resolveConflict,
                    progress: { [weak self] in self?.progress = $0 }, status: { self.status = $0 })
            } catch is CancellationError { status = "Cancelled" }
            catch { self.error = error.localizedDescription; status = "Failed" }
            busy = false; progress = nil; job = nil
            if removalNeedsRefresh { refreshAfterRemovalIfNeeded() }
            else if !disconnected { refresh() }
        }
    }
    func currentPermissions(_ file: BrowserFile) async throws -> String {
        guard !busy, !disconnected else { throw MutyError("Wait for the current SFTP operation to finish.") }
        busy = true; defer { busy = false; refreshAfterRemovalIfNeeded() }
        let mode = try await client.perform { client -> UInt32 in
            try client.validateDirectoryAncestors(file.path)
            guard let attributes = try client.attributes(file.path), !attributes.isSymlink, let mode = attributes.permissions else { throw MutyError("Permissions are unavailable.") }
            return mode & 0o7777
        }
        return String(format: "%04o", mode)
    }
    func properties(_ file: BrowserFile) async throws -> SFTPAttributes {
        guard !busy, !disconnected else { throw MutyError("Wait for the current SFTP operation to finish.") }
        busy = true; defer { busy = false; refreshAfterRemovalIfNeeded() }
        return try await client.perform { client in
            try client.validateDirectoryAncestors(file.path)
            guard let attributes = try client.attributes(file.path), !attributes.isSymlink else {
                throw MutyError("Properties are unavailable for this file.")
            }
            return attributes
        }
    }
    func changePermissions(_ file: BrowserFile, mode: String) {
        guard let permissions = UInt32(mode, radix: 8), permissions <= 0o7777 else { error = "Enter Unix permissions in octal, for example 0644."; return }
        run("Changing permissions…", refreshAfter: true, work: { try $0.setPermissions(file.path, permissions) })
    }
    func openEditor(_ file: BrowserFile, readOnly: Bool) {
        guard !file.isDirectory, !file.isSymlink else { return }
        let key = EditorKey(path: file.path, readOnly: readOnly)
        if let existing = editors[key] { existing.activate(); return }
        run("Opening file…", work: { try $0.readDocument(file.path) }) { [weak self] snapshot in
            guard let self else { return }
            let controller = RemoteTextEditor(path: file.path, endpoint: self.endpoint, snapshot: snapshot, readOnly: readOnly, tabGroupID: self.id) { [weak self] bytes, expected in
                guard let self, !self.disconnected else { throw MutyError("SSH connection ended.") }
                guard !self.busy else { throw MutyError("Another SFTP operation is running. Try saving again when it finishes.") }
                self.busy = true; self.status = "Saving file…"
                defer { self.busy = false; self.refreshAfterRemovalIfNeeded() }
                let directory = self.remotePath
                let result = try await self.client.perform { client in
                    let snapshot = try client.saveDocument(file.path, bytes: bytes, expected: expected)
                    return (snapshot, try? client.list(directory))
                }
                if let entries = result.1 { self.remoteFiles = entries }
                self.status = "Saved"
                return result.0
            }
            if let existingWindow = self.editors.values.compactMap(\.window).first, let newWindow = controller.window {
                let anchor = existingWindow.tabGroup?.selectedWindow ?? existingWindow
                anchor.addTabbedWindow(newWindow, ordered: .above)
            }
            controller.onClose = { [weak self] in self?.editors[key] = nil }
            self.editors[key] = controller
            controller.showWindow(nil)
            controller.activate()
        }
    }
    func makeFile(_ name: String, remote: Bool) {
        guard !busy else { return }
        do {
            let path = try BrowserFile.join(remote ? remotePath : localPath, name)
            if remote {
                run("Creating file…", refreshAfter: true, work: { try $0.createFile(path) })
            } else {
                let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard fd >= 0, close(fd) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                navigateLocal(localPath)
            }
        } catch { self.error = error.localizedDescription }
    }
    func makeFolder(_ name: String, remote: Bool) {
        do {
            let path = try BrowserFile.join(remote ? remotePath : localPath, name)
            if remote { run("Creating folder…", refreshAfter: true, work: { try $0.mkdir(path) }) }
            else {
                guard !busy else { return }
                guard !FileManager.default.fileExists(atPath: path) else { throw MutyError("An item with this name already exists.") }
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: false)
                navigateLocal(localPath)
            }
        } catch { self.error = error.localizedDescription }
    }
    func rename(_ file: BrowserFile, to name: String, remote: Bool) {
        do {
            let path = try BrowserFile.join(remote ? remotePath : localPath, name)
            guard path != file.path else { return }
            if remote { run("Renaming…", refreshAfter: true, work: { try $0.rename(file.path, path) }) }
            else {
                guard !busy else { return }
                guard !FileManager.default.fileExists(atPath: path) else { throw MutyError("An item with this name already exists.") }
                try FileManager.default.moveItem(atPath: file.path, toPath: path); navigateLocal(localPath)
            }
        } catch { self.error = error.localizedDescription }
    }
    func removeSelection(remote: Bool) {
        guard !busy, !remote || (!removing && !disconnected) else { return }
        let files = remote ? remoteFiles.filter { remoteSelection.contains($0.id) } : localFiles.filter { localSelection.contains($0.id) }
        guard !files.isEmpty else { return }
        let detail = files.map(\.name).joined(separator: "\n") + (remote ? "\n\nSelected folders and all their contents will be permanently removed. Symbolic links are removed without following them." : "\n\nItems will be moved to Trash.")
        guard confirm(remote ? "Remove Remote Items?" : "Move to Trash?", detail, action: remote ? "Remove" : "Move to Trash") else { return }
        if remote {
            guard !removing, !disconnected else { return }
            let channel = client.independentChannel()
            removalClient = channel
            removing = true
            error = nil
            removalError = nil
            removalJob = Task { [weak self] in
                guard let self else { return }
                let progress = SFTPProgressSink { [weak self, weak channel] value in
                    guard let self, let channel, self.removalClient === channel else { return }
                    self.removalPath = value.name
                }
                defer {
                    channel.shutdown()
                    removalClient = nil
                    removalJob = nil
                    removing = false
                    removalPath = ""
                }
                do {
                    try await channel.perform { client in
                        for file in files {
                            try client.removeTree(file.path) { progress.update(name: $0, bytes: 1, total: nil) }
                        }
                    }
                } catch is CancellationError { }
                catch {
                    removalError = error.localizedDescription
                    self.error = removalError
                }
                removalNeedsRefresh = true
                refreshAfterRemovalIfNeeded()
            }
        } else {
            do {
                for file in files { try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil) }
                navigateLocal(localPath)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func refreshAfterRemovalIfNeeded() {
        guard removalNeedsRefresh, !busy, !disconnected else { return }
        removalNeedsRefresh = false
        let message = removalError
        removalError = nil
        let directory = remotePath
        run("Refreshing…", work: { try $0.list(directory) }) { entries in
            self.remoteFiles = entries
            self.remoteSelection = []
            self.error = message
        }
    }

    private func confirm(_ title: String, _ text: String, action: String) -> Bool {
        app?.confirm(title, text: text, action: action) ?? false
    }
    func remoteDrag(_ file: BrowserFile) -> Data {
        let selected = remoteSelection.contains(file.id) ? remoteFiles.filter { remoteSelection.contains($0.id) } : [file]
        return (try? JSONEncoder().encode(RemoteFileDrag(browser: id, paths: selected.map(\.path)))) ?? Data()
    }
    func acceptRemoteDrag(_ data: Data) {
        guard let value = try? JSONDecoder().decode(RemoteFileDrag.self, from: data), value.browser == id else { return }
        let paths = Set(value.paths)
        download(remoteFiles.filter { paths.contains($0.path) })
    }
}
struct RemoteFileDrag: Codable { let browser: UUID; let paths: [String] }


private enum SFTPMoveVerification {
    static func snapshot(_ source: URL, depth: Int = 0,
                         checkCancellation: () throws -> Void) throws -> [BrowserFile] {
        try checkCancellation()
        guard depth < 128 else { throw MutyError("Folder nesting exceeds 128 levels.") }
        guard FileManager.default.fileExists(atPath: source.path) else { return [] }
        guard source.resolvingSymlinksInPath().path == source.standardizedFileURL.path else { throw MutyError("The move source became a symbolic link.") }
        let attrs = try source.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
        ])
        guard attrs.isSymbolicLink == false, attrs.isDirectory == true || attrs.isRegularFile == true else {
            throw MutyError("The move source changed: " + source.path)
        }
        let entry = BrowserFile(name: source.lastPathComponent, path: source.path,
                                isDirectory: attrs.isDirectory == true, isSymlink: false,
                                size: attrs.fileSize.map { UInt64($0) }, modified: attrs.contentModificationDate)
        var entries = [entry]
        if entry.isDirectory {
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                entries += try snapshot(child, depth: depth + 1, checkCancellation: checkCancellation)
            }
        }
        return entries
    }
    static func remove(_ expected: [BrowserFile], checkCancellation: () throws -> Void,
                       progress: (String) -> Void) throws {
        for entry in expected.sorted(by: { $0.path.count > $1.path.count }) {
            try checkCancellation()
            let source = URL(fileURLWithPath: entry.path)
            guard source.resolvingSymlinksInPath().path == source.standardizedFileURL.path else { throw MutyError("The move source became a symbolic link.") }
            let attrs = try source.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
            ])
            guard attrs.isSymbolicLink == false, (attrs.isDirectory == true) == entry.isDirectory,
                  entry.isDirectory || (attrs.isRegularFile == true && attrs.fileSize.map { UInt64($0) } == entry.size &&
                                        attrs.contentModificationDate == entry.modified) else {
                throw MutyError("The move source changed: " + entry.path)
            }
            try checkCancellation()
            // rmdir refuses newly added files instead of recursively deleting them.
            let result = entry.isDirectory ? Darwin.rmdir(entry.path) : Darwin.unlink(entry.path)
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            progress(entry.path)
        }
    }
}
