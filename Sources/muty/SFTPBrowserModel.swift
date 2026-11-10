import Foundation
import AppKit
import Darwin

@MainActor final class SFTPBrowserModel: ObservableObject {
    let id = UUID()
    let transferQueue: SFTPTransferQueue
    private let endpoint: String?
    private let sessionID: UUID
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
    private struct EditorKey: Hashable {
        let path: String
        let readOnly: Bool
    }
    private var editors: [EditorKey: RemoteTextEditor] = [:]
    private weak var app: AppModel?
    var visibleLocal: [BrowserFile] { localFiles.filter { showHidden || !$0.name.hasPrefix(".") } }
    var visibleRemote: [BrowserFile] { remoteFiles.filter { showHidden || !$0.name.hasPrefix(".") } }
    init(client: SFTPClient, app: AppModel, sessionID: UUID, transferQueue: SFTPTransferQueue, endpoint: String? = nil) {
        self.endpoint = endpoint
        self.client = client; self.app = app; self.sessionID = sessionID
        self.transferQueue = transferQueue
        transferQueue.attach(owner: id, executor: SFTPTransferAdapter(client: client))
        let saved = UserDefaults.standard.string(forKey: "sftp-local-" + sessionID.uuidString)
        navigateLocal(transferQueue.localPath ?? saved ?? localPath)
    }
    func start() {
        if remotePath.isEmpty && !busy && !disconnected {
            let saved = UserDefaults.standard.string(forKey: "sftp-remote-" + sessionID.uuidString)
            navigateRemote(transferQueue.remotePath ?? saved ?? ".", restoring: true)
        }
    }
    func disconnect() { disconnected = true; transferQueue.detach(owner: id); job?.cancel(); client.shutdown(); editors.values.forEach { $0.connectionEnded() } }
    func cancel() {
        transferQueue.cancel(owner: id)
        job?.cancel(); client.cancel()
    }
    func navigateLocal(_ path: String) {
        guard !busy else { return }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true).resolvingSymlinksInPath()
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            var entries: [BrowserFile] = []
            for item in urls {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                entries.append(BrowserFile(name: item.lastPathComponent, path: item.path,
                                           isDirectory: values.isDirectory == true && values.isSymbolicLink != true,
                                           isSymlink: values.isSymbolicLink == true,
                                           size: values.fileSize.map { UInt64(max(0, $0)) }, modified: values.contentModificationDate))
            }
            localPath = url.path; transferQueue.localPath = url.path
            UserDefaults.standard.set(url.path, forKey: "sftp-local-" + sessionID.uuidString)
            localFiles = BrowserFile.sorted(entries); localSelection = []; error = nil
        } catch { self.error = error.localizedDescription }
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
        }) { [weak self] value in
            guard let self else { return }
            remotePath = value.0; transferQueue.remotePath = value.0
            UserDefaults.standard.set(value.0, forKey: "sftp-remote-" + sessionID.uuidString)
            remoteFiles = value.1; remoteSelection = []
            status = ""
        }
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
            if !refreshAfter { processTransfers() }
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
    func uploadSelection() { upload(localFiles.filter { localSelection.contains($0.id) }.map { URL(fileURLWithPath: $0.path) }) }
    func upload(_ files: [URL]) {
        guard !files.isEmpty else { return }
        processTransfers(request: .upload(files, to: remotePath))
    }
    func downloadSelection() { download(remoteFiles.filter { remoteSelection.contains($0.id) }) }
    func download(_ files: [BrowserFile]) {
        guard !files.isEmpty else { return }
        processTransfers(request: .download(files, to: localPath))
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
            if !disconnected { refresh() }
        }
    }
    func currentPermissions(_ file: BrowserFile) async throws -> String {
        guard !busy, !disconnected else { throw MutyError("Wait for the current SFTP operation to finish.") }
        busy = true; defer { busy = false }
        let mode = try await client.perform { client -> UInt32 in
            try client.validateDirectoryAncestors(file.path)
            guard let attributes = try client.attributes(file.path), !attributes.isSymlink, let mode = attributes.permissions else { throw MutyError("Permissions are unavailable.") }
            return mode & 0o7777
        }
        return String(format: "%04o", mode)
    }
    func properties(_ file: BrowserFile) async throws -> SFTPAttributes {
        guard !busy, !disconnected else { throw MutyError("Wait for the current SFTP operation to finish.") }
        busy = true; defer { busy = false }
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
                defer { self.busy = false }
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
        guard !busy else { return }
        let files = remote ? remoteFiles.filter { remoteSelection.contains($0.id) } : localFiles.filter { localSelection.contains($0.id) }
        guard !files.isEmpty else { return }
        let detail = files.map(\.name).joined(separator: "\n") + (remote ? "\n\nOnly files and empty folders are removed." : "\n\nItems will be moved to Trash.")
        guard confirm(remote ? "Remove Remote Items?" : "Move to Trash?", detail, action: remote ? "Remove" : "Move to Trash") else { return }
        if remote {
            run("Removing…", refreshAfter: true, work: { client in
                for file in files { try client.checkCancellation(); try client.remove(file.path, directory: file.isDirectory && !file.isSymlink) }
            })
        } else {
            do {
                for file in files { try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil) }
                navigateLocal(localPath)
            } catch { self.error = error.localizedDescription }
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
