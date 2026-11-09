import SwiftUI
import UniformTypeIdentifiers

struct SFTPBrowserView: View {
    @ObservedObject var browser: SFTPBrowserModel
    let endpoint: String
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                SFTPFilePane(browser: browser, remote: false, title: "Local")
                SFTPFilePane(browser: browser, remote: true, title: "Remote · " + endpoint)
            }
            SFTPTransfersView(queue: browser.transferQueue, browser: browser)
            if browser.busy || browser.disconnected {
            Divider()
            HStack(spacing: 10) {
                if browser.disconnected { Text("SSH connection ended").foregroundStyle(.secondary) }
                else if browser.busy {
                    if let progress = browser.progress {
                        Text(progress.name).lineLimit(1).truncationMode(.middle)
                        if let total = progress.total, total > 0 {
                            ProgressView(value: min(Double(progress.bytes) / Double(total), 1)).frame(width: 110)
                            Text(Self.bytes(progress.bytes) + " / " + Self.bytes(total)).monospacedDigit()
                        } else { ProgressView().controlSize(.small) }
                    } else { ProgressView().controlSize(.small); Text(browser.status) }
                    Spacer(minLength: 4)
                    Button("Cancel") { browser.cancel() }
                } else { Text(browser.status).foregroundStyle(.secondary); Spacer(minLength: 0) }
            }.font(.system(size: 11)).controlSize(.small).padding(.horizontal, 8).frame(height: 24)
            }
            if let error = browser.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button { browser.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(8).background(Color.orange.opacity(0.1))
            }
        }.onAppear { browser.start() }
    }
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .file)
    }
}

private struct SFTPFilePane: View {
    static let dragType = "local.muty.sftp-items"
    @ObservedObject var browser: SFTPBrowserModel
    let remote: Bool
    let title: String
    @ViewState private var path = ""
    @ViewState private var namePrompt = false
    @ViewState private var creatingFile = false
    @ViewState private var name = ""
    @ViewState private var permissionsFile: BrowserFile?
    @ViewState private var permissions = "0644"
    @ViewState private var permissionsPrompt = false
    @ViewState private var renaming: BrowserFile?
    @ViewState private var sortOrder = [KeyPathComparator(\BrowserFile.name)]
    private var files: [BrowserFile] {
        (remote ? browser.visibleRemote : browser.visibleLocal).sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            for comparator in sortOrder {
                let result = comparator.compare(lhs, rhs)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
    private var parentEntry: BrowserFile? {
        guard !directory.isEmpty, directory != "/" else { return nil }
        return BrowserFile(name: "..", path: (directory as NSString).deletingLastPathComponent,
                           isDirectory: true, isSymlink: false, size: nil, modified: nil)
    }
    private var rows: [BrowserFile] { parentEntry.map { [$0] + files } ?? files }
    private var selectedFiles: Set<String> { selection.wrappedValue.intersection(Set(files.map(\.id))) }
    private var selection: Binding<Set<String>> { remote ? $browser.remoteSelection : $browser.localSelection }
    private var directory: String { remote ? browser.remotePath : browser.localPath }
    private var unavailable: Bool { browser.busy || (remote && (browser.disconnected || browser.remotePath.isEmpty)) }
    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                Button("Copy", systemImage: remote ? "arrow.left" : "arrow.right") {
                    transfer(selection.wrappedValue)
                }.disabled(browser.busy || browser.disconnected || browser.remotePath.isEmpty || selectedFiles.isEmpty)
            }
            HStack(spacing: 6) {
                Button { home() } label: { Image(systemName: "house") }.help("Home directory")
                TextField(remote ? "Remote path" : "Local path", text: $path)
                    .textFieldStyle(.roundedBorder).onSubmit { navigate(path) }
                    .accessibilityLabel(remote ? "Remote directory" : "Local directory")
                Button { navigate(directory) } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                Button { newItem(file: true) } label: { Image(systemName: "doc.badge.plus") }.help("New file").disabled(unavailable)
                Button { newItem(file: false) } label: { Image(systemName: "folder.badge.plus") }.help("New folder").disabled(unavailable)
            }.disabled(browser.busy || (remote && browser.disconnected))
            Table(of: BrowserFile.self, selection: selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { file in
                    HStack(spacing: 5) {
                        Image(systemName: file.isSymlink ? "link" : file.isDirectory ? "folder.fill" : "doc")
                            .foregroundStyle(file.isDirectory ? Color.accentColor : Color.secondary)
                        Text(file.name).lineLimit(1).help(file.name)
                    }
                }.width(min: 110, ideal: 220)
                TableColumn("Size", value: \.sortSize) { file in
                    Text(file.isDirectory ? "—" : file.size.map(SFTPBrowserView.bytes) ?? "—")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.width(min: 55, ideal: 70, max: 95)
                TableColumn("Modified", value: \.sortModified) { file in
                    Text(file.modified?.formatted(date: .numeric, time: .shortened) ?? "—")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.width(min: 95, ideal: 120, max: 160)
            } rows: {
                ForEach(rows) { file in TableRow(file).itemProvider { file.name == ".." ? nil : drag(file) } }
                    .onInsert(of: remote ? [.fileURL] : [UTType(exportedAs: Self.dragType, conformingTo: .data)]) { _, providers in _ = drop(providers) }
            }
            .contextMenu(forSelectionType: String.self) { selected in
                let ids = selected.intersection(Set(files.map(\.id)))
                if remote {
                    Button("View…") {
                        if let file = files.first(where: { ids.contains($0.id) }) { browser.openEditor(file, readOnly: true) }
                    }.disabled(ids.count != 1 || unavailable || files.contains { ids.contains($0.id) && ($0.isDirectory || $0.isSymlink) })
                    Button("Edit…") {
                        if let file = files.first(where: { ids.contains($0.id) }) { browser.openEditor(file, readOnly: false) }
                    }.disabled(ids.count != 1 || unavailable || files.contains { ids.contains($0.id) && ($0.isDirectory || $0.isSymlink) })
                    Button("Permissions…") {
                        if let file = files.first(where: { ids.contains($0.id) }) {
                            Task {
                                do { permissions = try await browser.currentPermissions(file); permissionsFile = file; permissionsPrompt = true }
                                catch { browser.error = error.localizedDescription }
                            }
                        }
                    }.disabled(ids.count != 1 || unavailable)
                    Divider()
                }
                Button("Copy to " + (remote ? "Local" : "Remote")) { transfer(ids) }
                    .disabled(ids.isEmpty || browser.busy || browser.disconnected || browser.remotePath.isEmpty)
                Button("New File…") { newItem(file: true) }.disabled(unavailable)
                Button("New Folder…") { newItem(file: false) }.disabled(unavailable)
                Button("Rename…") {
                    if let file = files.first(where: { ids.contains($0.id) }) { renaming = file; name = file.name; namePrompt = true }
                }.disabled(ids.count != 1 || unavailable)
                Button(remote ? "Remove…" : "Move to Trash…", role: .destructive) {
                    selection.wrappedValue = ids; browser.removeSelection(remote: remote)
                }.disabled(ids.isEmpty || unavailable)
            } primaryAction: { ids in
                guard !unavailable, ids.count == 1, let file = rows.first(where: { ids.contains($0.id) }), file.isDirectory || file.isSymlink else { return }
                navigate(file.path)
            }
            Text("\(files.count) items").font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8).frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: remote ? [UTType.fileURL.identifier] : [Self.dragType], isTargeted: nil, perform: drop)
        .controlSize(.small)
        .onAppear { path = directory }
        .onChange(of: directory) { _, value in path = value }
        .alert("Unix Permissions", isPresented: $permissionsPrompt) {
            TextField("Octal mode (0644)", text: $permissions)
            Button("Cancel", role: .cancel) {}
            Button("Apply") { if let file = permissionsFile { browser.changePermissions(file, mode: permissions) } }
        }
        .alert(renaming != nil ? "Rename Item" : creatingFile ? "New File" : "New Folder", isPresented: $namePrompt) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button(renaming == nil ? "Create" : "Rename") {
                if let file = renaming { browser.rename(file, to: name, remote: remote) }
                else if creatingFile { browser.makeFile(name, remote: remote) }
                else { browser.makeFolder(name, remote: remote) }
            }.disabled(!BrowserFile.validName(name))
        }
    }
    private func navigate(_ value: String) { if remote { browser.navigateRemote(value) } else { browser.navigateLocal(value) } }
    private func home() { if remote { browser.goRemoteHome() } else { browser.localHome() } }
    private func newItem(file: Bool) { creatingFile = file; renaming = nil; name = ""; namePrompt = true }
    private func transfer(_ ids: Set<String>) {
        selection.wrappedValue = ids
        if remote { browser.downloadSelection() } else { browser.uploadSelection() }
    }
    private func drag(_ file: BrowserFile) -> NSItemProvider {
        if !remote { return NSItemProvider(object: URL(fileURLWithPath: file.path) as NSURL) }
        let provider = NSItemProvider(), data = browser.remoteDrag(file)
        provider.registerDataRepresentation(forTypeIdentifier: Self.dragType, visibility: .all) { completion in completion(data, nil); return nil }
        return provider
    }
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard !browser.busy, !browser.disconnected, !browser.remotePath.isEmpty, !providers.isEmpty else { return false }
        let model = browser
        let expectedLocal = browser.localPath, expectedRemote = browser.remotePath
        if remote {
            let batch = SFTPDropBatch(), group = DispatchGroup()
            for provider in providers {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    let url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else { url = item as? URL }
                    batch.add(url)
                }
            }
            group.notify(queue: .main) { [weak model] in
                guard model?.remotePath == expectedRemote, model?.localPath == expectedLocal else { model?.error = "Directory changed. Drop the files again."; return }
                let value = batch.result()
                if value.failed { model?.error = "Some dropped files could not be read." }
                else { model?.upload(value.urls) }
            }
        } else {
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: Self.dragType) { [weak model] data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async {
                        guard model?.localPath == expectedLocal, model?.remotePath == expectedRemote else { model?.error = "Directory changed. Drop the files again."; return }
                        model?.acceptRemoteDrag(data)
                    }
                }
            }
        }
        return true
    }
}
private final class SFTPDropBatch: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var failed = false
    func add(_ url: URL?) {
        lock.lock(); defer { lock.unlock() }
        if let url, url.isFileURL { urls.append(url) } else { failed = true }
    }
    func result() -> (urls: [URL], failed: Bool) { lock.lock(); defer { lock.unlock() }; return (urls, failed) }
}
