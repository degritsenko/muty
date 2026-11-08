import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ViewState private var search = ""
    @ViewState private var sessionManagerVisible = false
    @ViewState private var outsideDismissEvent: Int?
    @ViewState private var dismissedByOutsideClick = false
    @FocusState private var sessionSearchFocused: Bool
    @ViewState private var terminalQuery = ""
    @ViewState private var matchFound = true
    @ViewState private var selectedRows: Set<SessionRowID> = []
    @ViewState private var favoritesExpanded = true
    @ViewState private var sessionsExpanded = true
    @ViewState private var rootDropTarget = false
    @ViewState private var folderName = ""
    @ViewState private var renameFolder: String?
    @ViewState private var renameValue = ""
    @ViewState private var showFolderPrompt = false
    @ViewState private var showRenamePrompt = false
    @GestureState private var managerDrag: CGFloat = 0
    @AppStorage("sessionManagerWidth") private var managerWidth = 280.0
    @AppStorage("sessionManagerFontSize") private var managerFontSize = 12
    @AppStorage("showButtonBar") private var showButtonBar = true
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    @AppStorage("terminalScrollback") private var scrollback = 10000.0
    @AppStorage("optionAsMetaKey") private var optionAsMetaKey = true
    @AppStorage("terminalTheme") private var theme = "Dark"
    @AppStorage("terminalFontName") private var fontName = ""

    private var filtered: [SessionProfile] {
        model.profiles.filter { profile in
            let matchesFolder: Bool
            if model.selectedFolder == "__favorites" { matchesFolder = profile.favorite }
            else { matchesFolder = profile.folder == model.selectedFolder }
            return matchesFolder && (search.isEmpty ||
                "\(profile.name) \(profile.endpoint)".localizedCaseInsensitiveContains(search))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }


    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Button { toggleSessionManager() } label: {
                    Text("Session Manager").font(.system(size: 12))
                        .fixedSize().rotationEffect(.degrees(-90))
                        .frame(width: 26, height: 130)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .background(sessionManagerVisible ? Color.accentColor.opacity(0.2) : Color.clear)
                    .accessibilityLabel("Session Manager")
                    .accessibilityValue(sessionManagerVisible ? "Expanded" : "Collapsed")
                    .help("Toggle Session Manager")
                Spacer(minLength: 0)
            }.frame(width: 26).background(.bar)
            Divider()
            terminalContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    sessionManager
                        .frame(width: boundedManagerWidth(managerWidth + managerDrag))
                        .frame(maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .background(OutsideClickObserver(active: sessionManagerVisible) { eventNumber in
                            outsideDismissEvent = eventNumber
                            dismissedByOutsideClick = true
                            sessionManagerVisible = false
                        })
                        .overlay(alignment: .trailing) { managerResizeHandle }
                        .shadow(color: .black.opacity(0.25), radius: 6, x: 3)
                        .offset(x: sessionManagerVisible ? 0 : -boundedManagerWidth(managerWidth) - 16)
                        .opacity(sessionManagerVisible ? 1 : 0)
                        .allowsHitTesting(sessionManagerVisible)
                        .accessibilityHidden(!sessionManagerVisible)
                }
                .clipped()
        }
        .animation(.easeInOut(duration: 0.18), value: sessionManagerVisible)
        .onChange(of: sessionManagerVisible) { _, visible in
            if visible { sessionSearchFocused = true }
            else {
                sessionSearchFocused = false
                if !dismissedByOutsideClick {
                    DispatchQueue.main.async {
                        guard !sessionManagerVisible, let connection = model.selectedConnection,
                              !connection.showingSFTP else { return }
                        connection.terminal.window?.makeFirstResponder(connection.terminal)
                    }
                }
                dismissedByOutsideClick = false
            }
        }
        .onChange(of: search) { _, _ in selectedRows = [] }
        .onChange(of: selectedRows) { _, rows in
            model.selectedProfile = rows.count == 1 ? rows.first?.profileID : nil
            if rows.count == 1, let row = rows.first {
                if row.location == .folder { model.selectedFolder = row.folderPath }
                else if let profile = model.profiles.first(where: { $0.id == row.profileID }) { model.selectedFolder = profile.folder }
            }
        }
        .overlay(alignment: .bottom) { OperationStatusView(model: model) }
        .frame(minWidth: 850, minHeight: 540)
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { connectionToolbar }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { connectionToolbar }
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 10) {
                    SavedSessionSearchField(model: model).frame(width: 190, height: 22)
                    HStack(spacing: 4) {
                        TerminalSearchField(text: $terminalQuery, request: model.terminalFindRequest) {
                            findInTerminal(backward: false)
                        }.frame(width: 190, height: 22)
                        if !terminalQuery.isEmpty {
                            Button { terminalQuery = ""; matchFound = true } label: { Image(systemName: "xmark.circle.fill") }.help("Clear search")
                        }
                        Button { findInTerminal(backward: true) } label: { Image(systemName: "chevron.up") }.help("Previous match")
                        Button { findInTerminal(backward: false) } label: { Image(systemName: "chevron.down") }.help("Next match")
                        if !matchFound { Image(systemName: "exclamationmark.magnifyingglass").help("No match found") }
                    }.disabled(model.selectedConnection == nil)
                }.controlSize(.small)
            }
        }
        .onChange(of: terminalQuery) { _, _ in matchFound = true }
        .onChange(of: model.selectedTab) { _, id in
            matchFound = true
            model.syncSplitSelection()
        }
        .sheet(isPresented: $model.fullBackupExport) { FullBackupExportView(model: model) }
        .sheet(item: $model.lockedBackup) { BackupUnlockView(model: model, backup: $0) }
        .sheet(item: $model.configurationImport) { ConfigurationImportView(model: model, backup: $0) }
        .sheet(item: $model.importPreview) { SessionImportView(model: model, preview: $0) }
        .sheet(item: $model.mobaXtermImport) { MobaXtermImportView(model: model, preview: $0) }
        .sheet(isPresented: $model.quickConnect) { QuickConnectView(model: model) }
        .sheet(item: $model.bulkEditing) { BulkSessionEditor(model: model, request: $0) }
        .sheet(item: $model.editing) { ProfileEditor(model: model, draft: $0) }
        .onChange(of: model.newFolderPrompt) { _, value in showFolderPrompt = value }
        .alert("New Folder", isPresented: $showFolderPrompt) {
            TextField("Folder name", text: $folderName)
            Button("Cancel", role: .cancel) { folderName = ""; model.newFolderPrompt = false }
            Button("Create") {
                let path = model.selectedFolder.map { $0 + "/" + folderName } ?? folderName
                model.createFolder(path); folderName = ""; model.newFolderPrompt = false
            }
        }
        .alert("Rename Folder", isPresented: $showRenamePrompt) {
            TextField("Folder name", text: $renameValue)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let renameFolder { model.renameFolder(renameFolder, to: renameValue) }
            }
        }
        .alert("muty", isPresented: Binding(get: { model.errorMessage != nil },
                                            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(L(model.errorMessage ?? "")) }
        .onAppear { fontSize = min(30, max(9, fontSize.isFinite ? fontSize : 13)) }
    }
    private func toggleSessionManager() {
        // The outside-click monitor has already closed the panel for this event.
        if let event = NSApp.currentEvent, event.eventNumber == outsideDismissEvent { return }
        sessionManagerVisible.toggle()
    }

    private func boundedManagerWidth(_ width: CGFloat) -> CGFloat {
        min(620, max(220, width.isFinite ? width : 280))
    }

    private var managerTextSize: Int { min(15, max(10, managerFontSize)) }
    private var managerTextFont: Font { .system(size: CGFloat(managerTextSize)) }

    private func connectFromManager(_ profiles: [SessionProfile]) {
        let previous = model.selectedTab
        for profile in profiles { model.connect(profile) }
        if model.selectedTab != previous { sessionManagerVisible = false }
    }

    private var managerResizeHandle: some View {
        Rectangle().fill(.clear)
            .frame(width: 8)
            .overlay(alignment: .trailing) { Divider() }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating($managerDrag) { value, width, _ in width = value.translation.width }
                .onEnded { value in managerWidth = boundedManagerWidth(managerWidth + value.translation.width) })
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.set() }
                else { NSCursor.arrow.set() }
            }
    }

    private var managerToolbar: some View {
        let items = selectedRows.filter { $0.profileID != nil || $0.folderPath != nil }
        return HStack(spacing: 8) {
            Button("New Session", systemImage: "plus") {
                var profile = SessionProfile()
                profile.folder = pasteDestination(selectedRows)
                model.editing = ProfileDraft(new: profile)
            }.disabled(model.readOnly).help("New Session")
            Button("New Folder", systemImage: "folder.badge.plus") {
                model.selectedFolder = pasteDestination(selectedRows)
                model.newFolderPrompt = true
            }.disabled(model.readOnly).help("New Folder")
            Divider().frame(height: 20)
            Button("Cut", systemImage: "scissors") { model.copySessionItems(items, cut: true) }
                .disabled(items.isEmpty || model.readOnly).help("Cut")
            Button("Copy", systemImage: "doc.on.doc") { model.copySessionItems(items, cut: false) }
                .disabled(items.isEmpty || model.readOnly).help("Copy")
            Button("Paste", systemImage: "clipboard") { model.pasteSessionItems(into: pasteDestination(selectedRows)) }
                .disabled(model.sessionClipboard == nil || model.readOnly).help("Paste")
            Button("Delete Selected Items", systemImage: "trash") { model.deleteSelectedItems(items) }
                .disabled(items.isEmpty || model.readOnly).help("Delete Selected Items")
            Spacer(minLength: 0)
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless)
        .font(.system(size: 16, weight: .semibold))
        .padding(.horizontal, 6).padding(.vertical, 6)
    }

    private var sessionManager: some View {
            VStack(spacing: 0) {
                HStack {
                    Text("Session Manager").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Menu {
                        ForEach(10...15, id: \.self) { size in
                            Button {
                                managerFontSize = size
                            } label: {
                                if size == managerTextSize { Label(LF("%ld pt", size), systemImage: "checkmark") }
                                else { Text(LF("%ld pt", size)) }
                            }
                        }
                    } label: { Image(systemName: "textformat.size") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Text Size").help("Session Manager Text Size")
                    Button { sessionManagerVisible = false } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    }.buttonStyle(.plain).help("Close Session Manager")
                }.padding(.horizontal, 8).padding(.vertical, 6)
                Divider()
                managerToolbar
                HStack {
                    HStack(spacing: 4) {
                        TextField("Search sessions", text: $search).textFieldStyle(.plain)
                            .font(managerTextFont).focused($sessionSearchFocused)
                        if !search.isEmpty {
                            Button { search = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.plain).help("Clear search")
                        }
                    }.padding(.horizontal, 6).padding(.vertical, 4).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }.padding(.horizontal, 6).padding(.vertical, 4)
                List(selection: $selectedRows) {
                    if !search.isEmpty {
                        Section("Search Results") {
                            ForEach(SavedSessionSearch.matches(model.profiles, query: search)) { profile in
                                SessionRow(profile: profile, location: .search, model: model, textFont: managerTextFont)
                            }
                        }
                    } else {
                        DisclosureGroup(isExpanded: $favoritesExpanded) {
                            ForEach(model.profiles.filter(\.favorite)) { profile in
                                SessionRow(profile: profile, location: .favorites, model: model, textFont: managerTextFont)
                            }
                            if !model.profiles.contains(where: \.favorite) {
                                Text("Mark sessions with a star to add them here.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } label: {
                            Label("Favorites", systemImage: "star.fill").font(managerTextFont).foregroundStyle(.yellow).padding(.vertical, 2)
                        }.listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        DisclosureGroup(isExpanded: $sessionsExpanded) {
                            FolderBranch(parent: nil, model: model, textFont: managerTextFont)
                        } label: {
                            Label { Text("Sessions").font(managerTextFont) } icon: { Image(systemName: "folder.fill").foregroundStyle(.blue) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                                .background(rootDropTarget ? Color.accentColor.opacity(0.25) : Color.clear)
                                .dropDestination(for: String.self) { items, _ in
                                    model.dropSessions(items, into: nil)
                                } isTargeted: { rootDropTarget = $0 }

                        }.tag(SessionRowID.folder(nil))
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))

                    }
                }
                .id(search)
                .listStyle(.sidebar)
                .environment(\.defaultMinListRowHeight, CGFloat(managerTextSize + 6))
                .font(managerTextFont)
                .controlSize(.small)
                .background(SessionManagerCommands(active: sessionManagerVisible,
                    copy: { model.copySessionItems(selectedRows, cut: false) },
                    cut: { model.copySessionItems(selectedRows, cut: true) },
                    paste: { model.pasteSessionItems(into: pasteDestination(selectedRows)) }))
                .contextMenu(forSelectionType: SessionRowID.self) { ids in
                    let canCopy = ids.contains { $0.profileID != nil || $0.folderPath != nil }
                    let profile = ids.count == 1 ? model.profiles.first { $0.id == ids.first?.profileID } : nil
                    let hasFolder = ids.contains { $0.location == .folder }
                    if ids.count > 1 {
                        let selected = Set(ids.compactMap(\.profileID))
                        if !selected.isEmpty {
                            Button("Connect Selected Sessions") {
                                connectFromManager(model.profiles.filter { selected.contains($0.id) })
                            }
                        }
                        Button("Bulk Edit Selected Sessions…") { model.editSelectedSessions(ids) }.disabled(model.readOnly)
                    } else if let profile {
                        SessionActions(profile: profile, model: model) { connectFromManager([profile]) }
                    } else if let row = ids.first, row.location == .folder {
                        Button("New Session…") {
                            var profile = SessionProfile(); profile.folder = row.folderPath
                            model.editing = ProfileDraft(new: profile)
                        }.disabled(model.readOnly)
                        Button(row.folderPath == nil ? "New Folder…" : "New Subfolder…") {
                            model.selectedFolder = row.folderPath; model.newFolderPrompt = true
                        }.disabled(model.readOnly)
                        if let path = row.folderPath {
                            Button("Rename Folder…") {
                                renameFolder = path; renameValue = path; showRenamePrompt = true
                            }.disabled(model.readOnly)
                        }
                        Button("Bulk Edit Sessions…") { model.editFolderSessions(row.folderPath) }.disabled(model.readOnly)
                    }
                    if !ids.isEmpty { Divider() }
                    Button("Cut") { model.copySessionItems(ids, cut: true) }.disabled(!canCopy || model.readOnly)
                    Button("Copy") { model.copySessionItems(ids, cut: false) }.disabled(!canCopy || model.readOnly)
                    Button("Paste") { model.pasteSessionItems(into: pasteDestination(ids)) }.disabled(model.sessionClipboard == nil || model.readOnly)
                    if let profile {
                        Divider()
                        Button("Delete Session", role: .destructive) { model.delete(profile) }.disabled(model.readOnly)
                    } else if ids.count > 1 || hasFolder {
                        Divider()
                        Button("Delete Selected Items…", role: .destructive) { model.deleteSelectedItems(ids) }.disabled(model.readOnly)
                    }
                } primaryAction: { ids in
                    if ids.count == 1, let id = ids.first, let profile = model.profiles.first(where: { $0.id == id.profileID }) {
                        connectFromManager([profile])
                    }
                }
            }
    }

    private func pasteDestination(_ rows: Set<SessionRowID>) -> String? {
        if rows.count == 1, let row = rows.first {
            if row.location == .folder { return row.folderPath }
            if let profile = model.profiles.first(where: { $0.id == row.profileID }) { return profile.folder }
        }
        return model.selectedFolder
    }

    private var terminalContent: some View {
            VStack(spacing: 0) {
                if model.tabs.isEmpty {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 2) {
                            ForEach(model.tabs) { connection in
                                SessionTab(connection: connection, model: model,
                                           selected: model.selectedTab == connection.id,
                                           select: { model.selectTab(connection.id) },
                                           close: { model.close(connection) })
                                .onDrag { NSItemProvider(object: connection.id.uuidString as NSString) }
                                .dropDestination(for: String.self) { items, _ in
                                    guard let value = items.first, let source = UUID(uuidString: value) else { return false }
                                    model.reorderTabs(from: source, to: connection.id)
                                    return true
                                }
                            }
                        }.padding(.horizontal, 6).padding(.vertical, 3)
                    }.scrollIndicators(.hidden).frame(height: 34).background(.bar)
                    Divider()
                    TerminalWorkspace(model: model) { connection, index in
                        SessionPane(connection: connection, model: model, fontSize: fontSize,
                            scrollback: Int(scrollback.isFinite ? max(1000, min(50000, scrollback)) : 10000), theme: theme,
                            optionAsMetaKey: optionAsMetaKey, fontName: fontName,
                            selected: model.selectedTab == connection.id, showPaneTitle: index != nil, paneIndex: index)
                    }

                }
                if showButtonBar {
                    if let connection = model.selectedConnection {
                        SessionButtonBar(connection: connection, model: model)
                    } else {
                        Divider()
                        SendStringButtonBar(model: model)
                    }
                }
            }

    }

    private var connectionToolbar: some View {
        HStack(spacing: 14) {
                Menu {
                    Button("New Session") { model.editing = ProfileDraft() }.disabled(model.readOnly)
                    Button("Connect Local Shell") {
                        var profile = SessionProfile()
                        profile.connectionType = .localShell; profile.name = "Local Shell"
                        model.connect(profile, temporary: true)
                    }
                    Button("Quick Connect…") { model.quickConnect = true }
                } label: { Image(systemName: "link") }
                    .help("Connections")
                Button {
                    if let connection = model.selectedConnection { model.reconnect(connection) }
                } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .disabled(model.selectedConnection == nil).help("Reconnect / Restart Shell")
                Button { model.selectedConnection?.disconnect() } label: {
                    Image(systemName: "xmark")
                }.disabled(model.selectedConnection?.running != true).help("Disconnect / Stop Shell")
        }
        .buttonStyle(.plain)
        .font(.system(size: 17, weight: .medium))
        .fixedSize()
    }

    private func findInTerminal(backward: Bool) {
        guard !terminalQuery.isEmpty, let terminal = model.selectedConnection?.terminal else { return }
        matchFound = backward ? terminal.findPrevious(terminalQuery) : terminal.findNext(terminalQuery)
    }

}

private struct SessionButtonBar: View {
    @ObservedObject var connection: SSHConnection
    @ObservedObject var model: AppModel

    var body: some View {
        if !connection.showingSFTP {
            Divider()
            SendStringButtonBar(model: model)
        }
    }
}

private struct SessionTab: View {
    @ObservedObject var connection: SSHConnection
    @ObservedObject var model: AppModel
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @ViewState private var tunnelsVisible = false
    @ViewState private var renaming = false
    @ViewState private var nameDraft = ""

    @ViewBuilder private var connectionIndicator: some View {
        if !connection.running && connection.status != "Not Started" {
            Image(systemName: "minus.circle.fill").symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red).font(.system(size: 14, weight: .bold))
                .help("Disconnected")
        } else if connection.running && (connection.profile.connectionType == .localShell || connection.transportReady) {
            Image(systemName: "checkmark").foregroundStyle(.green).font(.system(size: 14, weight: .heavy))
                .help("Session active")
        } else {
            Image(systemName: "hourglass").foregroundStyle(.yellow).font(.system(size: 13, weight: .semibold))
                .help("Connecting / waiting for SSH transport")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                HStack(spacing: 7) {
                    connectionIndicator.frame(width: 14, height: 14)
                    if connection.isLogging { Image(systemName: "record.circle.fill").foregroundStyle(.red).help("Logging session output") }
                    Text(connection.tabName ?? connection.profile.name).lineLimit(1)
                    if let color = connection.profile.color {
                        Circle().fill(sessionColor(color)).frame(width: 8, height: 8).help(color)
                    }
                }.padding(.vertical, 5)
            }.buttonStyle(.plain)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.borderless).help("Close tab")
        }
        .padding(.horizontal, 12).frame(minWidth: 120, maxWidth: 240)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .contextMenu {
            Button(connection.profile.connectionType == .localShell ? "Restart Shell" : "Reconnect") { model.reconnect(connection) }
            Button(connection.profile.connectionType == .localShell ? "Stop Shell" : "Disconnect") { connection.disconnect() }.disabled(!connection.running)
            if !connection.running && connection.profile.connectionType == .ssh && connection.profile.authentication == .password {
                Button("Enter Password Again…") { model.reconnect(connection, promptForPassword: true) }
            }
            Divider()
            SessionLoggingMenu(connection: connection)
            Divider()
            if connection.activeTunnels != nil {
                Button("Manage Tunnels…") { tunnelsVisible = true }
            }
            Button("Rename Tab…") {
                nameDraft = connection.tabName ?? connection.profile.name
                renaming = true
            }
            Button("Duplicate Tab") { model.duplicateTab(connection) }
            if connection.temporary {
                Button("Save as Session…") { model.saveTemporaryProfile(connection) }
            } else if let profile = model.profiles.first(where: { $0.id == connection.profile.id }) {
                SessionPasswordAction(profile: profile, model: model)
            }
            Divider()
            Button("Close Tab") { model.close(connection) }
        }
        .sheet(isPresented: $tunnelsVisible) {
            if let tunnels = connection.activeTunnels { ActiveTunnelsView(manager: tunnels, model: model, profile: connection.profile) }
        }
        .alert("Rename Tab", isPresented: $renaming) {
            TextField("Tab name", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                model.renameTab(connection, to: name.isEmpty ? nil : name)
            }
        } message: {
            Text("Changes only this tab. Leave empty to use the session name.")
        }
        .help(connection.profile.endpoint)
    }
}

private struct SessionPane: View {
    @ObservedObject var connection: SSHConnection
    @ObservedObject var model: AppModel
    let fontSize: Double
    let scrollback: Int
    let theme: String
    let optionAsMetaKey: Bool
    let fontName: String
    let selected: Bool
    var showPaneTitle = false
    var paneIndex: Int?
    @ViewState private var tunnelsVisible = false

    var body: some View {
        VStack(spacing: 0) {
            if showPaneTitle {
                HStack(spacing: 8) {
                    Text(connection.tabName ?? connection.profile.name)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if connection.profile.connectionType == .ssh {
                        Text(connection.profile.endpoint).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if let paneIndex {
                        Menu {
                            ForEach(model.tabs) { tab in
                                Button(tab.tabName ?? tab.profile.name) { model.assignSplitTab(tab.id, to: paneIndex) }
                            }
                        } label: { Image(systemName: "chevron.down") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Choose session for this pane")
                    }
                }
                .padding(.horizontal, 8).frame(height: 26)
                .background(selected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .bottom) { Rectangle().fill(selected ? Color.accentColor : Color.clear).frame(height: 2) }
                .contentShape(Rectangle()).onTapGesture { model.selectTab(connection.id) }
                .help(connection.profile.endpoint)
            }
            if let tunnels = connection.activeTunnels, tunnels.entries.contains(where: { $0.active }) {
                HStack {
                    Button(LF("Active Tunnels (%ld)…", tunnels.entries.filter { $0.active }.count)) { tunnelsVisible = true }
                    Spacer()
                }.font(.caption).padding(.horizontal, 8).frame(height: 26)
            }

            if connection.profile.tunnelOnly {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L("Tunnel only") + " · " + L(connection.status), systemImage: "network")
                    Text("No shell is started. Closing or disconnecting this tab stops the forwards.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(connection.profile.forwards.filter { $0.enabled != false }) { rule in
                        Text(L(rule.kind.title) + ": " + rule.bindAddress + ":" + String(rule.listenPort) + (rule.kind == .socks ? "" : " → " + rule.destinationHost + ":" + String(rule.destinationPort)))
                            .font(.caption.monospaced())
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if connection.profile.connectionType == .ssh && !connection.profile.tunnelOnly && connection.profile.sshEnabled && connection.profile.sftpEnabled {
                HStack(spacing: 4) {
                    Button("SSH") {
                        connection.showingSFTP = false
                        connection.terminal.window?.makeFirstResponder(connection.terminal)
                    }.padding(.horizontal, 6).background(connection.showingSFTP ? Color.clear : Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                    Button("SFTP") { connection.openFileBrowser(app: model) }
                        .padding(.horizontal, 6).background(connection.showingSFTP ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                        .disabled(!connection.canOpenSFTP && connection.fileBrowser == nil)
                    Spacer()
                }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 8).frame(height: 28).background(.bar)
                Divider()
            }
            ZStack {
                TerminalPane(connection: connection, fontSize: fontSize, selected: selected && !connection.showingSFTP)
                    .opacity(connection.showingSFTP ? 0 : 1)
                    .allowsHitTesting(!connection.showingSFTP)
                    .accessibilityHidden(connection.showingSFTP)
                if connection.showingSFTP, let browser = connection.fileBrowser {
                    SFTPBrowserView(browser: browser, endpoint: connection.profile.endpoint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
                }
            }
            if connection.error != nil || (!connection.running && connection.status != "Not Started") {
                Divider()
                HStack(spacing: 8) {
                    if let error = connection.error {
                        Label(L(error), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    } else {
                        Text(L(connection.status)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if !connection.running {
                        Text(connection.profile.connectionType == .localShell ? L("Press Enter to restart shell") : L("Press Enter to reconnect"))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.bar)
            }
        }.sheet(isPresented: $tunnelsVisible) {
            if let tunnels = connection.activeTunnels { ActiveTunnelsView(manager: tunnels, model: model, profile: connection.profile) }
        }.onAppear {
            applySettings()
            openSFTPIfNeeded()
            connection.terminal.onFindRequested = { [weak model] in model?.terminalFindRequest = UUID() }
            connection.terminal.reconnectOnReturn = { [weak model, weak connection] in
                guard let connection, let model, !connection.running else { return false }
                model.reconnect(connection)
                return true
            }
        }
            .onChange(of: connection.canOpenSFTP) { _, _ in openSFTPIfNeeded() }
            .onChange(of: scrollback) { _, _ in applySettings() }
            .onChange(of: theme) { _, _ in applySettings() }
            .onChange(of: optionAsMetaKey) { _, _ in applySettings() }
            .onChange(of: fontName) { _, _ in connection.setFontSize(fontSize) }
    }

    private func openSFTPIfNeeded() {
        guard connection.profile.connectionType == .ssh,
              !connection.profile.sshEnabled, connection.profile.sftpEnabled,
              !connection.profile.tunnelOnly, connection.canOpenSFTP, connection.fileBrowser == nil else { return }
        connection.openFileBrowser(app: model)
    }

    private func applySettings() {
        connection.setScrollback(scrollback)
        connection.setTheme(theme)
        connection.setOptionAsMeta(optionAsMetaKey)
    }
}

private struct SessionActions: View {
    let profile: SessionProfile
    @ObservedObject var model: AppModel
    let connect: () -> Void
    var body: some View {
        Button("Connect", action: connect)
        Button("Edit Session…") { model.editing = ProfileDraft(profile) }.disabled(model.readOnly)
        Button(profile.favorite ? "Remove from Favorites" : "Add to Favorites") {
            model.toggleFavorite(profile)
        }.disabled(model.readOnly)
        Menu("Move to Folder") {
            Button("Sessions (Root)") { model.move(profile, to: nil) }
            ForEach(model.folders, id: \.self) { folder in
                Button(folder) { model.move(profile, to: folder) }
            }
        }.disabled(model.readOnly)
        Button("Duplicate Session") { model.duplicate(profile) }.disabled(model.readOnly)
        SessionPasswordAction(profile: profile, model: model)
    }
}

private struct SessionPasswordAction: View {
    let profile: SessionProfile
    @ObservedObject var model: AppModel

    var body: some View {
        if profile.connectionType == .ssh && profile.authentication == .password
            && (profile.savePassword || profile.credentialID != nil) {
            Button(profile.credentialID == nil ? "Forget Saved Password…" : "Unlink Shared Credential…") {
                model.forgetSavedPassword(profile)
            }.disabled(model.readOnly)
        }
    }
}

private struct SessionRow: View {
    let profile: SessionProfile
    var location: SessionRowID.Location = .sessions
    @ObservedObject var model: AppModel
    let textFont: Font
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: profile.connectionType.icon)
                .foregroundStyle(profile.color == nil && profile.connectionType == .ssh ? Color.cyan : sessionColor(profile.color))
            Text(profile.name).font(textFont).lineLimit(1)
            Spacer(minLength: 4)
            Button { model.toggleFavorite(profile) } label: {
                Image(systemName: profile.favorite ? "star.fill" : "star")
                    .foregroundStyle(profile.favorite ? Color.yellow : Color.secondary)
            }.buttonStyle(.borderless).disabled(model.readOnly)
                .help(profile.favorite ? "Remove from Favorites" : "Add to Favorites")
        }.padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
            .contentShape(Rectangle()).tag(SessionRowID(profileID: profile.id, location: location))
            .help(profile.endpoint)
            .draggable("muty-session:" + profile.id.uuidString) {
                Label(profile.name, systemImage: "desktopcomputer")
                    .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
    }
}

private struct FolderBranch: View {
    let parent: String?
    @ObservedObject var model: AppModel
    let textFont: Font
    @ViewState private var dropTarget: String?

    private var children: [String] {
        model.folders.filter { path in
            let components = path.split(separator: "/")
            let parentPath = components.dropLast().joined(separator: "/")
            return parentPath == (parent ?? "")
        }
    }

    var body: some View {
        ForEach(children, id: \.self) { path in
            DisclosureGroup {
                AnyView(FolderBranch(parent: path, model: model, textFont: textFont))
            } label: {
                Label { Text(String(path.split(separator: "/").last ?? "")).font(textFont).lineLimit(1) } icon: { Image(systemName: "folder.fill").foregroundStyle(.blue) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .background(dropTarget == path ? Color.accentColor.opacity(0.25) : .clear)
                    .draggable("muty-folder:" + path)
                    .dropDestination(for: String.self) { items, _ in
                        model.dropSessions(items, into: path)
                    } isTargeted: { targeted in
                        if targeted { dropTarget = path }
                        else if dropTarget == path { dropTarget = nil }
                    }

            }.tag(SessionRowID.folder(path))
            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
        }
        ForEach(model.profiles(in: parent).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { profile in
            SessionRow(profile: profile, model: model, textFont: textFont)
        }

    }
}

private func sessionColor(_ name: String?) -> Color {
    switch name {
    case "Red": return .red
    case "Orange": return .orange
    case "Yellow": return .yellow
    case "Green": return .green
    case "Blue": return .blue
    case "Purple": return .purple
    default: return .secondary
    }
}
