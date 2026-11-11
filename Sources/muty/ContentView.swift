import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ViewState private var search = ""
    @ViewState private var sessionManagerVisible = UserDefaults.standard.bool(forKey: "sessionManagerPinned")
    @AppStorage("sessionManagerPinned") private var sessionManagerPinned = false
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
    @AppStorage("terminalTheme") private var theme = TerminalColorScheme.mutyDark.rawValue
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
            if sessionManagerPinned && sessionManagerVisible {
                sessionManager
                    .frame(width: boundedManagerWidth(managerWidth + managerDrag))
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .trailing) { managerResizeHandle }
                Divider()
            }
            terminalContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    if !sessionManagerPinned {
                    sessionManager
                        .frame(width: boundedManagerWidth(managerWidth + managerDrag))
                        .frame(maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .background(OutsideClickObserver(active: sessionManagerVisible && !sessionManagerPinned) { eventNumber in
                            guard !model.deletingSessionItems else { return }
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
        .onChange(of: search) { _, _ in
            selectedRows = []
            if !search.isEmpty { sessionsExpanded = true }
        }
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
                    SavedSessionSearchField(model: model).frame(width: 190, height: 24)
                    Divider().frame(height: 18).padding(.horizontal, 6)
                    HStack(spacing: 4) {
                        TerminalSearchField(text: $terminalQuery, request: model.terminalFindRequest) {
                            findInTerminal(backward: false)
                        }.frame(width: 190, height: 24)
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
        .background(TabKeyboardShortcuts(model: model).frame(width: 0, height: 0))
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
        .modifier(TemporaryTabEditorSheet(model: model))
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
        } message: { Text(model.errorMessage ?? "") }
        .onAppear { fontSize = min(30, max(9, fontSize.isFinite ? fontSize : 13)) }
    }
    private func deleteFromManager(_ rows: Set<SessionRowID>) {
        model.deleteSelectedItems(rows)
        sessionManagerVisible = true
        DispatchQueue.main.async { sessionSearchFocused = true }
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
        if model.selectedTab != previous && !sessionManagerPinned { sessionManagerVisible = false }
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
            Button("Delete Selected Items", systemImage: "trash") { deleteFromManager(items) }
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
                    Button {
                        sessionManagerPinned.toggle()
                        if !sessionManagerPinned { sessionManagerVisible = false }
                    } label: {
                        Image(systemName: sessionManagerPinned ? "pin.fill" : "pin")
                            .foregroundStyle(sessionManagerPinned ? Color.accentColor : Color.secondary)
                    }.buttonStyle(.plain)
                        .help(sessionManagerPinned ? "Unpin Session Manager" : "Keep Session Manager open")
                        .accessibilityLabel(sessionManagerPinned ? "Unpin Session Manager" : "Pin Session Manager")
                    Menu {
                        ForEach(10...15, id: \.self) { size in
                            Button {
                                managerFontSize = size
                            } label: {
                                if size == managerTextSize { Label("\(size) pt", systemImage: "checkmark") }
                                else { Text("\(size) pt") }
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
                        DisclosureGroup(isExpanded: $sessionsExpanded) {
                            SessionSearchBranch(parent: nil,
                                profiles: SavedSessionSearch.matches(model.profiles, query: search),
                                model: model, textFont: managerTextFont)
                        } label: {
                            Label { Text("Sessions").foregroundStyle(.primary) } icon: {
                                Image(systemName: "folder.fill").foregroundStyle(.blue)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
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
                            Menu("Folder Color") {
                                Button("Default") { model.setFolderColor(nil, for: path) }
                                Divider()
                                ForEach(["Red", "Orange", "Yellow", "Green", "Blue", "Purple"], id: \.self) { color in
                                    Button {
                                        model.setFolderColor(color, for: path)
                                    } label: {
                                        HStack {
                                            Circle().fill(sessionColor(color)).frame(width: 8, height: 8)
                                            Text(color)
                                            if model.folderColor(path) == color { Image(systemName: "checkmark") }
                                        }
                                    }
                                }
                            }
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
                        Button("Delete Session", role: .destructive) {
                            model.delete(profile)
                            sessionManagerVisible = true
                            DispatchQueue.main.async { sessionSearchFocused = true }
                        }.disabled(model.readOnly)
                    } else if ids.count > 1 || hasFolder {
                        Divider()
                        Button("Delete Selected Items…", role: .destructive) { deleteFromManager(ids) }.disabled(model.readOnly)
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
                    HStack(spacing: 8) {
                    ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 2) {
                            ForEach(model.tabs) { connection in
                                SessionTab(connection: connection, model: model,
                                           selected: model.selectedTab == connection.id,
                                           select: { model.selectTab(connection.id) },
                                           close: { model.close(connection) })
                                .id(connection.id)
                                .onDrag { NSItemProvider(object: connection.id.uuidString as NSString) }
                                .dropDestination(for: String.self) { items, _ in
                                    guard let value = items.first, let source = UUID(uuidString: value) else { return false }
                                    model.reorderTabs(from: source, to: connection.id)
                                    return true
                                }
                            }
                        }.padding(.horizontal, 6).padding(.vertical, 2)
                    }.scrollIndicators(.hidden)
                    .onChange(of: model.selectedTab) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                    .onChange(of: model.tabs.map(\.id)) { _, _ in
                        if let id = model.selectedTab { proxy.scrollTo(id) }
                    }
                    }
                    if let connection = model.selectedConnection,
                       connection.profile.connectionType == .ssh, !connection.profile.tunnelOnly,
                       connection.profile.sshEnabled, connection.profile.sftpEnabled {
                        SessionModePicker(connection: connection, model: model)
                            .padding(.trailing, 8)
                    }
                    }.frame(height: 26).background(.bar)
                    Divider()
                    TerminalWorkspace(model: model) { connection, index in
                        SessionPane(connection: connection, model: model, fontSize: fontSize,
                            scrollback: scrollback, profileTheme: (model.profiles.first(where: { $0.id == connection.profile.id }) ?? connection.profile).terminalTheme, globalTheme: theme,
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
                Button {
                    if let connection = model.selectedConnection { model.reconnect(connection) }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                    .disabled(model.selectedConnection == nil).help("Reconnect / Restart Shell")
                Button { model.selectedConnection?.disconnect() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }.disabled(model.selectedConnection?.running != true).help("Disconnect / Stop Shell")
        }
        .buttonStyle(.plain)
        .font(.system(size: 17, weight: .medium))
        .padding(.leading, 8)
        .fixedSize()
    }

    private func findInTerminal(backward: Bool) {
        guard !terminalQuery.isEmpty, let terminal = model.selectedConnection?.terminal else { return }
        matchFound = backward ? terminal.findPrevious(terminalQuery) : terminal.findNext(terminalQuery)
    }

}

private struct TemporaryTabEditorSheet: ViewModifier {
    @ObservedObject var model: AppModel
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { model.editingTabConnection }, set: { model.editingTab = $0?.id })) { connection in
            ProfileEditor(model: model, draft: ProfileDraft(connection.profile), onSave: { updated in
                try model.updateTemporaryTab(connection, profile: updated)
            })
        }
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

private struct SessionModePicker: View {
    @ObservedObject var connection: SSHConnection
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            Button("SSH") {
                connection.showingSFTP = false
                connection.terminal.window?.makeFirstResponder(connection.terminal)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(connection.showingSFTP ? Color.clear : Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            Button("SFTP") { connection.openFileBrowser(app: model) }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(connection.showingSFTP ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .disabled(!connection.canOpenSFTP && connection.fileBrowser == nil)
        }
        .buttonStyle(.plain).font(.system(size: 11))
        .fixedSize()
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
            Circle().fill(.red).help("Disconnected").accessibilityLabel("Disconnected")
        } else if connection.running && (connection.profile.connectionType == .localShell || connection.transportReady) {
            Circle().fill(.green).help("Session active").accessibilityLabel("Session active")
        } else {
            Circle().fill(.yellow).help("Connecting / waiting for SSH transport").accessibilityLabel("Connecting")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 7) {
                    connectionIndicator.frame(width: 6, height: 6)
                    if let index = model.tabs.firstIndex(where: { $0.id == connection.id }), index < 9 {
                        Text("\(index + 1)").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    if connection.isLogging { Image(systemName: "record.circle.fill").foregroundStyle(.red).help("Logging session output") }
                    Text(connection.tabName ?? connection.profile.name).lineLimit(1)
                    if let color = (model.profiles.first(where: { $0.id == connection.profile.id }) ?? connection.profile).color {
                        Circle().fill(sessionColor(color)).frame(width: 8, height: 8).help(color)
                    }
                }.padding(.vertical, 1)
            }.buttonStyle(.plain)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.borderless).help("Close tab")
        }
        .padding(.horizontal, 9).frame(minWidth: 100, maxWidth: 240)
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
            Button("Session Settings…") {
                if connection.temporary { model.editingTab = connection.id }
                else if let profile = model.profiles.first(where: { $0.id == connection.profile.id }) {
                    model.editing = ProfileDraft(profile)
                }
            }.disabled(!connection.temporary && model.profiles.first(where: { $0.id == connection.profile.id }) == nil)
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
    @AppStorage("showStatusBar") private var showStatusBar = true
    @ObservedObject var connection: SSHConnection
    @ObservedObject var model: AppModel
    let fontSize: Double
    let scrollback: Double
    let profileTheme: String?
    let globalTheme: String
    let optionAsMetaKey: Bool
    let fontName: String
    let selected: Bool
    var showPaneTitle = false
    var paneIndex: Int?
    @ViewState private var tunnelsVisible = false
    private var settings: TerminalSettings {
        TerminalSettings.resolve(
            profileTheme: profileTheme, fontSize: fontSize, scrollback: scrollback, globalTheme: globalTheme,
            optionAsMetaKey: optionAsMetaKey, fontName: fontName
        )
    }

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
                    Button("Active Tunnels (\(tunnels.entries.filter { $0.active }.count))…") { tunnelsVisible = true }
                    Spacer()
                }.font(.caption).padding(.horizontal, 8).frame(height: 26)
            }

            if connection.profile.tunnelOnly {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Tunnel only · " + connection.status, systemImage: "network")
                    Text("No shell is started. Closing or disconnecting this tab stops the forwards.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(connection.profile.forwards.filter { $0.enabled != false }) { rule in
                        Text("\(rule.kind.title): \(rule.bindAddress):\(rule.listenPort)" + (rule.kind == .socks ? "" : " → \(rule.destinationHost):\(rule.destinationPort)"))
                            .font(.caption.monospaced())
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            ZStack {
                TerminalPane(connection: connection, fontSize: settings.fontSize, fontName: settings.fontName, selected: selected && !connection.showingSFTP)
                    .opacity(connection.showingSFTP ? 0 : 1)
                    .allowsHitTesting(!connection.showingSFTP)
                    .accessibilityHidden(connection.showingSFTP)
                if connection.showingSFTP, let browser = connection.fileBrowser {
                    SFTPBrowserView(browser: browser, endpoint: connection.profile.endpoint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
                }
            }
            if showStatusBar && (connection.profile.connectionType == .ssh || connection.error != nil || (!connection.running && connection.status != "Not Started")) {
                Divider()
                ConnectionStatusBar(connection: connection)
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
            .onChange(of: profileTheme) { _, _ in applySettings() }
            .onChange(of: globalTheme) { _, _ in applySettings() }
            .onChange(of: optionAsMetaKey) { _, _ in applySettings() }
            .onChange(of: fontName) { _, _ in connection.setFontSize(settings.fontSize, fontName: settings.fontName) }
    }

    private func openSFTPIfNeeded() {
        guard connection.profile.connectionType == .ssh,
              !connection.profile.sshEnabled, connection.profile.sftpEnabled,
              !connection.profile.tunnelOnly, connection.canOpenSFTP, connection.fileBrowser == nil else { return }
        connection.openFileBrowser(app: model)
    }

    private func applySettings() {
        connection.setScrollback(settings.scrollback)
        connection.setTheme(settings.theme)
        connection.setOptionAsMeta(settings.optionAsMetaKey)
        connection.setFontSize(settings.fontSize, fontName: settings.fontName)
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

private struct SessionSearchBranch: View {
    let parent: String?
    let profiles: [SessionProfile]
    @ObservedObject var model: AppModel
    let textFont: Font

    private var children: [String] {
        let prefix = parent.map { $0 + "/" } ?? ""
        return Set(profiles.compactMap { profile -> String? in
            guard let folder = profile.folder, folder.hasPrefix(prefix) else { return nil }
            let remainder = folder.dropFirst(prefix.count)
            guard let next = remainder.split(separator: "/").first else { return nil }
            return prefix + next
        }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        ForEach(children, id: \.self) { folder in
            SessionSearchFolder(folder: folder, profiles: profiles, model: model, textFont: textFont)
        }
        ForEach(profiles.filter { $0.folder == parent }) { profile in
            SessionRow(profile: profile, location: .search, model: model, textFont: textFont)
        }
    }
}

private struct SessionSearchFolder: View {
    let folder: String
    let profiles: [SessionProfile]
    @ObservedObject var model: AppModel
    let textFont: Font
    @ViewState private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            AnyView(SessionSearchBranch(parent: folder, profiles: profiles, model: model, textFont: textFont))
        } label: {
            Label {
                Text(String(folder.split(separator: "/").last ?? "")).foregroundStyle(.primary)
            } icon: {
                Image(systemName: "folder.fill").foregroundStyle(.blue)
            }.font(textFont)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
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
                Label { Text(String(path.split(separator: "/").last ?? "")).font(textFont).lineLimit(1) } icon: {
                    Image(systemName: "folder.fill").foregroundStyle(model.folderColor(path).map(sessionColor) ?? .blue)
                }
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
