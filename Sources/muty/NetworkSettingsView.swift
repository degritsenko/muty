import SwiftUI

struct JumpHostPicker: View {
    @Binding var selection: UUID?
    @ObservedObject var model: AppModel
    var excluding: UUID? = nil
    @ViewState private var showingChoices = false
    @ViewState private var query = ""
    @FocusState private var searchFocused: Bool

    private var choices: [SessionProfile] {
        model.profiles.filter { $0.id != excluding && $0.connectionType == .ssh && $0.jumpHostID == nil }
    }

    private var title: String {
        guard let selection else { return "None (direct connection)" }
        guard let profile = choices.first(where: { $0.id == selection }) else { return "Unavailable — select another" }
        return [profile.folder, profile.name].compactMap { $0 }.joined(separator: "/")
    }

    var body: some View {
        Button {
            query = ""
            showingChoices = true
        } label: {
            HStack(spacing: 8) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.caption)
            }
        }
        .frame(maxWidth: 275, alignment: .leading)
        .accessibilityLabel("Jump Host")
        .accessibilityValue(title)
        .help(title)
        .popover(isPresented: $showingChoices, arrowEdge: .bottom) { chooser }
    }

    private var chooser: some View {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = search.isEmpty
            ? choices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            : SavedSessionSearch.matches(choices, query: search)
        return VStack(alignment: .leading, spacing: 10) {
            TextField("Search sessions or folders", text: $query)
                .focused($searchFocused)
                .onSubmit {
                    if !search.isEmpty, visible.count == 1 { select(visible[0].id) }
                }
            Button { select(nil) } label: {
                Label("None (direct connection)", systemImage: selection == nil ? "checkmark" : "arrow.right")
            }.buttonStyle(.plain)
            Divider()
            if visible.isEmpty {
                Text(search.isEmpty ? "No saved Jump Hosts available" : "No matching sessions")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        PaneSessionBranch(parent: nil, profiles: visible, searching: !search.isEmpty, model: model) {
                            select($0.id)
                        }
                    }
                }.frame(height: 240)
            }
        }
        .padding(12)
        .frame(width: 360)
        .onAppear { searchFocused = true }
        .onExitCommand { showingChoices = false }
    }

    private func select(_ id: UUID?) {
        selection = id
        showingChoices = false
    }
}

struct ForwardingSettingsView: View {
    @Binding var profile: SessionProfile
    @ViewState private var selected: UUID?
    private var selectedRule: PortForward? { profile.forwards.first { $0.id == selected } }
    private var ruleBinding: Binding<PortForward>? {
        guard let id = selected, profile.forwards.contains(where: { $0.id == id }) else { return nil }
        return Binding(get: { profile.forwards.first(where: { $0.id == id }) ?? PortForward() }, set: { value in
            if let index = profile.forwards.firstIndex(where: { $0.id == id }) { profile.forwards[index] = value }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 6) {
                    List(selection: $selected) {
                        ForEach(profile.forwards) { rule in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rule.name?.isEmpty == false ? rule.name! : rule.kind.title).lineLimit(1)
                                Text(rule.kind.title + " · " + String(rule.listenPort) + (rule.enabled == false ? " · Off" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 3).tag(rule.id)
                        }
                    }.listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    HStack {
                        Button { add() } label: { Image(systemName: "plus") }.help("Add forwarding rule").disabled(profile.forwards.count >= 32)
                        Button { duplicate() } label: { Image(systemName: "doc.on.doc") }.help("Duplicate rule (disabled initially)").disabled(selectedRule == nil || profile.forwards.count >= 32)
                        Spacer(minLength: 0)
                        Button(role: .destructive) { remove() } label: { Image(systemName: "minus") }.help("Delete rule").disabled(selectedRule == nil)
                    }
                }.frame(width: 165)
                Divider()
                if let binding = ruleBinding {
                    ForwardRuleFields(rule: binding, server: profile.host)
                } else {
                    VStack(spacing: 10) {
                        Text("No forwarding rule selected").foregroundStyle(.secondary)
                        Button("Add Rule") { add() }.disabled(profile.forwards.count >= 32)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxHeight: .infinity)
            Divider()
            Toggle("Do not request a shell (tunnel only)", isOn: $profile.tunnelOnly)
        }
        .onAppear { if selectedRule == nil { selected = profile.forwards.first?.id } }
    }
    private func add() {
        guard profile.forwards.count < 32 else { return }
        var rule = PortForward()
        let used = Set(profile.forwards.filter { $0.enabled != false && $0.kind != .remote }.map(\.listenPort))
        while used.contains(rule.listenPort), rule.listenPort < 65535 { rule.listenPort += 1 }
        profile.forwards.append(rule); selected = rule.id
    }
    private func duplicate() {
        guard var rule = selectedRule, profile.forwards.count < 32 else { return }
        rule.id = UUID(); rule.name = (rule.name ?? rule.kind.title) + " Copy"; rule.enabled = false
        profile.forwards.append(rule); selected = rule.id
    }
    private func remove() {
        guard let id = selected, let index = profile.forwards.firstIndex(where: { $0.id == id }) else { return }
        profile.forwards.remove(at: index)
        selected = profile.forwards.isEmpty ? nil : profile.forwards[min(index, profile.forwards.count - 1)].id
    }
}

struct ForwardRuleFields: View {
    @Binding var rule: PortForward
    let server: String
    private var serverLabel: String { "SSH server (" + (server.isEmpty ? "session host" : server) + ")" }
    private var route: String {
        let listen = PortForward.address(rule.bindAddress) + ":" + String(rule.listenPort)
        let destination = PortForward.address(rule.destinationHost) + ":" + String(rule.destinationPort)
        switch rule.kind {
        case .local: return "This Mac " + listen + " → " + serverLabel + " → " + destination
        case .remote: return serverLabel + " " + listen + " → This Mac → " + destination
        case .socks: return "Apps → This Mac " + listen + " (SOCKS) → " + serverLabel + " → destination"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Name").foregroundStyle(.secondary)
                    TextField("Rule name", text: Binding(get: { rule.name ?? "" }, set: { rule.name = $0.isEmpty ? nil : $0 }))
                        .accessibilityLabel("Rule name")
                }
                GridRow {
                    Text("Type").foregroundStyle(.secondary)
                    HStack {
                        Picker("Type", selection: $rule.kind) {
                            ForEach(PortForward.Kind.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(maxWidth: 140)
                        Spacer(minLength: 4)
                        Toggle("Enabled", isOn: Binding(get: { rule.enabled != false }, set: { rule.enabled = $0 }))
                            .toggleStyle(.switch)
                    }
                }
            }
            Divider().padding(.vertical, 2)
            Text(rule.kind == .remote ? "Listen on " + serverLabel : "Listen on This Mac")
                .font(.caption.weight(.semibold))
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Interface").font(.caption).foregroundStyle(.secondary)
                    TextField("Listening interface", text: $rule.bindAddress).accessibilityLabel("Listening interface")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Port").font(.caption).foregroundStyle(.secondary)
                    TextField("Port", value: $rule.listenPort, format: .number.grouping(.never)).accessibilityLabel("Listening port")
                }.frame(width: 75)
            }
            if rule.kind != .socks {
                Text(rule.kind == .remote ? "Destination reached from This Mac" : "Destination reached from " + serverLabel)
                    .font(.caption.weight(.semibold)).padding(.top, 4)
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Host / IP").font(.caption).foregroundStyle(.secondary)
                        TextField("Destination host / IP", text: $rule.destinationHost).accessibilityLabel("Destination host / IP")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Port").font(.caption).foregroundStyle(.secondary)
                        TextField("Port", value: $rule.destinationPort, format: .number.grouping(.never)).accessibilityLabel("Destination port")
                    }.frame(width: 75)
                }
            }
            Spacer(minLength: 0)
            Text(rule.kind == .remote ? "Destination localhost means this Mac. The listening interface belongs to the SSH server." : rule.kind == .local ? "Destination localhost means the SSH server. The listening interface belongs to this Mac." : "The SOCKS proxy listens on this Mac; connections are made from the SSH server.")
                .font(.caption).foregroundStyle(.secondary)
            Text(route).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }.textFieldStyle(.roundedBorder).controlSize(.small)
            .frame(maxWidth: .infinity)
    }
}
