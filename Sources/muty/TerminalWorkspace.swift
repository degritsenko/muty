import SwiftUI
import AppKit

struct TerminalPaneLayout {
    let frames: [CGRect]
    let column: CGFloat?
    let row: CGFloat?
    let rowStart: CGFloat
    let rowWidth: CGFloat
    init(mode: String, size: CGSize, x: CGFloat, y: CGFloat) {
        let w = max(1, size.width), h = max(1, size.height)
        let minX = min(0.45, 180 / w), minY = min(0.45, 100 / h)
        let dx = (w * min(1 - minX, max(minX, x))).rounded()
        let dy = (h * min(1 - minY, max(minY, y))).rounded()
        let left = CGRect(x: 0, y: 0, width: dx, height: h)
        let right = CGRect(x: dx + 1, y: 0, width: max(1, w - dx - 1), height: h)
        let top = CGRect(x: 0, y: 0, width: w, height: dy)
        let bottom = CGRect(x: 0, y: dy + 1, width: w, height: max(1, h - dy - 1))
        switch mode {
        case "right": frames = [left, right]; column = dx; row = nil; rowStart = 0
        case "bottom": frames = [top, bottom]; column = nil; row = dy; rowStart = 0
        case "three":
            frames = [left, CGRect(x: right.minX, y: 0, width: right.width, height: dy), CGRect(x: right.minX, y: dy + 1, width: right.width, height: bottom.height)]
            column = dx; row = dy; rowStart = right.minX
        case "three-left":
            frames = [CGRect(x: 0, y: 0, width: dx, height: dy),
                      CGRect(x: 0, y: bottom.minY, width: dx, height: bottom.height), right]
            column = dx; row = dy; rowStart = 0
        case "four":
            frames = [CGRect(x: 0, y: 0, width: dx, height: dy), CGRect(x: right.minX, y: 0, width: right.width, height: dy), CGRect(x: 0, y: bottom.minY, width: dx, height: bottom.height), CGRect(x: right.minX, y: bottom.minY, width: right.width, height: bottom.height)]
            column = dx; row = dy; rowStart = 0
        default: frames = [CGRect(origin: .zero, size: size)]; column = nil; row = nil; rowStart = 0
        }
        rowWidth = mode == "three-left" ? dx : max(1, w - rowStart)
    }
}

struct TerminalWorkspace<Pane: View>: View {
    @ObservedObject var model: AppModel
    let pane: (SSHConnection) -> Pane
    @ViewState private var sessionPickerIndex: Int?
    @ViewState private var sessionQuery = ""
    private let tabBarHeight: CGFloat = 26
    var body: some View {
        GeometryReader { geometry in
            let layout = TerminalPaneLayout(mode: model.splitMode, size: geometry.size, x: model.splitColumnFraction, y: model.splitRowFraction)
            let split = model.splitMode != "none"
            let groups = split ? model.splitGroups : [.init(tabs: model.tabs.map(\.id), selected: model.selectedTab)]
            let connections = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0) })
            ZStack(alignment: .topLeading) {
                // Keep a single view identity per connection as tabs move between groups.
                ForEach(model.tabs) { connection in
                    let index = groups.firstIndex { $0.selected == connection.id }
                    let frame = layout.frames[min(index ?? 0, layout.frames.count - 1)]
                    pane(connection)
                        .frame(width: frame.width, height: max(1, frame.height - tabBarHeight))
                        .clipped()
                        .offset(x: frame.minX, y: frame.minY + tabBarHeight)
                        .opacity(index != nil ? 1 : 0)
                        .allowsHitTesting(index != nil)
                        .accessibilityHidden(index == nil)
                        .simultaneousGesture(TapGesture().onEnded { model.selectTab(connection.id) })
                }
                ForEach(layout.frames.indices, id: \.self) { index in
                    if groups.indices.contains(index) {
                        let frame = layout.frames[index]
                        let group = groups[index]
                        if group.tabs.isEmpty {
                            Color(nsColor: .windowBackgroundColor)
                                .overlay {
                                    emptyPaneActions(group, index: index)
                                }
                                .frame(width: frame.width, height: max(1, frame.height - tabBarHeight))
                                .contentShape(Rectangle())
                                .onTapGesture { model.focusGroup(index) }
                                .dropDestination(for: String.self) { items, _ in
                                    dropTab(items, in: index)
                                }
                                .offset(x: frame.minX, y: frame.minY + tabBarHeight)
                        }
                        tabBar(group, connections: connections, index: index, split: split)
                            .frame(width: frame.width, height: tabBarHeight)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                if let x = layout.column {
                    Rectangle().fill(Color.clear).frame(width: 7, height: geometry.size.height)
                        .overlay { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1) }
                        .contentShape(Rectangle()).offset(x: x - 3)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("mutyWorkspace")).onChanged { event in
                            model.splitColumnFraction = min(0.85, max(0.15, event.location.x / max(1, geometry.size.width)))
                        }.onEnded { _ in model.persistWorkspace() })
                        .onHover { inside in if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() } }
                        .accessibilityLabel("Resize columns")
                }
                if let y = layout.row {
                    Rectangle().fill(Color.clear).frame(width: layout.rowWidth, height: 7)
                        .overlay { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
                        .contentShape(Rectangle()).offset(x: layout.rowStart, y: y - 3)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("mutyWorkspace")).onChanged { event in
                            model.splitRowFraction = min(0.85, max(0.15, event.location.y / max(1, geometry.size.height)))
                        }.onEnded { _ in model.persistWorkspace() })
                        .onHover { inside in if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() } }
                        .accessibilityLabel("Resize rows")
                }
            }.sheet(isPresented: Binding(get: { sessionPickerIndex != nil }, set: { if !$0 { sessionPickerIndex = nil } })) {
                savedSessionPicker
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .coordinateSpace(name: "mutyWorkspace").clipped()
        }
    }

    private func emptyPaneActions(_ group: AppModel.TabGroup, index: Int) -> some View {
        VStack(spacing: 10) {
            sessionMenu(group, index: index) { Text("Open or Move Session") }
            Button("New Local Shell") {
                model.focusGroup(index)
                var profile = SessionProfile()
                profile.connectionType = .localShell
                profile.name = "Local Shell"
                model.connect(profile, manual: true, temporary: true)
            }.buttonStyle(.borderless)
        }.fixedSize()
    }

    private func sessionMenu<MenuLabel: View>(_ group: AppModel.TabGroup, index: Int,
                                          @ViewBuilder label: () -> MenuLabel) -> some View {
        Menu {
            Button("Open Saved Session…") {
                sessionQuery = ""
                sessionPickerIndex = index
            }
            let otherTabs = model.tabs.filter { !group.tabs.contains($0.id) }
            if !otherTabs.isEmpty {
                Menu("Move Open Tab Here") {
                    ForEach(otherTabs) { connection in
                        Button(connection.tabName ?? connection.profile.name) {
                            model.moveTab(connection.id, to: index)
                        }
                    }
                }
            }
        } label: { label() }
    }

    private var savedSessionPicker: some View {
        let query = sessionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let profiles = query.isEmpty
            ? model.profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            : SavedSessionSearch.matches(model.profiles, query: query)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Open Saved Session").font(.headline)
            TextField("Search sessions or folders", text: $sessionQuery)
            if profiles.isEmpty {
                Text(query.isEmpty ? "No saved sessions" : "No matching sessions")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    PaneSessionBranch(parent: nil, profiles: profiles) { profile in
                        guard let index = sessionPickerIndex, model.splitGroups.indices.contains(index) else { return }
                        model.focusGroup(index)
                        sessionPickerIndex = nil
                        model.connect(profile)
                    }
                }
            }
            HStack { Spacer(); Button("Cancel") { sessionPickerIndex = nil }.keyboardShortcut(.cancelAction) }
        }.padding().frame(width: 420, height: 360)
    }

    private func tabBar(_ group: AppModel.TabGroup, connections: [UUID: SSHConnection], index: Int, split: Bool) -> some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(group.tabs, id: \.self) { id in
                            if let connection = connections[id] {
                                SessionTab(connection: connection, model: model, selected: group.selected == id,
                                           select: { model.selectTab(id) }, close: { model.close(connection) })
                                    .id(id)
                                    .onDrag { NSItemProvider(object: id.uuidString as NSString) }
                                    .dropDestination(for: String.self) { items, _ in
                                        dropTab(items, in: index, before: id)
                                    }
                            }
                        }
                    }.padding(.horizontal, 6).padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .onChange(of: group.selected, initial: true) { _, selected in
                    if let selected { proxy.scrollTo(selected) }
                }
                .onChange(of: group.tabs) { _, _ in
                    if let selected = group.selected { proxy.scrollTo(selected) }
                }
            }
            if let id = group.selected, let connection = connections[id],
               connection.profile.connectionType == .ssh, !connection.profile.tunnelOnly,
               connection.profile.sshEnabled, connection.profile.sftpEnabled {
                SessionModePicker(connection: connection, model: model).padding(.trailing, 8)
            }
            if split && !group.tabs.isEmpty {
                sessionMenu(group, index: index) {
                    Image(systemName: "chevron.down").accessibilityLabel("Open or Move Session")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.trailing, 8)
                .help("Open or Move Session")
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(split && model.activeSplitIndex == index ? Color.accentColor : Color(nsColor: .separatorColor))
                .frame(height: 1).allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            dropTab(items, in: index)
        }
    }

    private func dropTab(_ items: [String], in index: Int, before target: UUID? = nil) -> Bool {
        guard let value = items.first, let source = UUID(uuidString: value),
              model.tabs.contains(where: { $0.id == source }) else { return false }
        if model.splitMode != "none" { return model.moveTab(source, to: index, before: target) }
        guard let target, source != target else { return false }
        model.reorderTabs(from: source, to: target)
        return true
    }
}

private struct PaneSessionBranch: View {
    let parent: String?
    let profiles: [SessionProfile]
    let select: (SessionProfile) -> Void

    private var children: [String] {
        let prefix = parent.map { $0 + "/" } ?? ""
        return Set(profiles.compactMap { profile -> String? in
            guard let folder = profile.folder, folder.hasPrefix(prefix),
                  let next = folder.dropFirst(prefix.count).split(separator: "/").first else { return nil }
            return prefix + next
        }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        ForEach(children, id: \.self) { folder in
            PaneSessionFolder(folder: folder, profiles: profiles, select: select)
        }
        ForEach(profiles.filter { $0.folder == parent }) { profile in
            Button { select(profile) } label: {
                VStack(alignment: .leading) {
                    Text(profile.name)
                    Text(profile.endpoint).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
        }
    }
}

private struct PaneSessionFolder: View {
    let folder: String
    let profiles: [SessionProfile]
    let select: (SessionProfile) -> Void
    @ViewState private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            AnyView(PaneSessionBranch(parent: folder, profiles: profiles, select: select))
        } label: {
            Label(String(folder.split(separator: "/").last ?? ""), systemImage: "folder.fill")
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}
