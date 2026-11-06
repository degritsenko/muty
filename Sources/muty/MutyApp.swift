import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url), icon.isValid {
            NSApplication.shared.applicationIconImage = icon
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let main = sender.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "muty" }) {
            main.makeKeyAndOrderFront(nil)
        }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard RemoteTextEditor.allowTermination() else { return .terminateCancel }
        if let model, model.tabs.contains(where: \.running) {
            guard model.confirm("Quit muty?", text: "All active sessions will be closed.", action: "Quit") else { return .terminateCancel }
        }
        guard let model else { return .terminateNow }
        model.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct MutyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @ViewState private var showingSettings = false
    @AppStorage("showButtonBar") private var showButtonBar = true
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    var body: some Scene {
        Window("muty", id: "main") {
            ContentView(model: model)
                .sheet(isPresented: $showingSettings) {
                    AppSettingsView(model: model, library: model.keyLibrary)
                }
                .background(WindowTitleHider().frame(width: 0, height: 0)).onAppear { delegate.model = model; model.openStartupSession() }
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1150, height: 740)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { showingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Quick Connect…") { model.quickConnect = true }
                    .keyboardShortcut("k")
                Button("New Session") { model.editing = ProfileDraft() }
                    .keyboardShortcut("n").disabled(model.readOnly)
                Button("Connect Local Shell") {
                    var profile = SessionProfile()
                    profile.connectionType = .localShell; profile.name = "Local Shell"
                    model.connect(profile, temporary: true)
                }.keyboardShortcut("l", modifiers: .command)
            }
            CommandMenu("Import & Backup") {
                Button("Back Up…") { model.beginFullBackupExport() }.disabled(model.readOnly)
                Button("Restore Backup…") { model.chooseConfigurationImport(restoringBackup: true) }.disabled(model.readOnly)
                Divider()
                Button("Import SecureCRT XML…") { model.chooseSecureCRTImport() }.disabled(model.readOnly)
                Button("Import MobaXterm Sessions…") { model.chooseMobaXtermImport() }.disabled(model.readOnly)
            }
            CommandGroup(replacing: .textEditing) {
                Button("Find in Terminal…") {
                    model.terminalFindRequest = UUID()
                }.keyboardShortcut("f", modifiers: .command).disabled(showingSettings || model.selectedConnection == nil)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Button Bar", isOn: $showButtonBar)
                Divider()
                Button("Increase Terminal Font Size") { resizeFont(1) }.keyboardShortcut("=", modifiers: .command)
                Button("Decrease Terminal Font Size") { resizeFont(-1) }.keyboardShortcut("-", modifiers: .command)
                Button("Reset Terminal Font Size") { fontSize = 13 }.keyboardShortcut("0", modifiers: .command)
            }
            CommandGroup(before: .windowSize) {
                Menu("Split Left / Right") {
                    ForEach(model.tabs.filter { $0.id != model.selectedTab }) { tab in
                        Button(tab.tabName ?? tab.profile.name) { model.split("right", secondary: tab.id) }
                    }
                }.disabled(model.tabs.count < 2)
                Menu("Split Top / Bottom") {
                    ForEach(model.tabs.filter { $0.id != model.selectedTab }) { tab in
                        Button(tab.tabName ?? tab.profile.name) { model.split("bottom", secondary: tab.id) }
                    }
                }.disabled(model.tabs.count < 2)
                Button("3 Panes — Left + Two Right") { model.split("three") }.disabled(model.tabs.isEmpty)
                Button("4 Panes — Grid") { model.split("four") }.disabled(model.tabs.isEmpty)
                Button("Single Pane") { model.split("none") }.disabled(model.splitMode == "none")
                Divider()
                Button("Close Tab") {
                    if let tab = model.tabs.first(where: { $0.id == model.selectedTab }) { model.close(tab) }
                }.keyboardShortcut("w").disabled(showingSettings || model.tabs.isEmpty)
                Button("Next Tab") { cycle(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { cycle(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
            }
        }
    }
    private func resizeFont(_ delta: Double) {
        fontSize = min(30, max(9, (fontSize.isFinite ? fontSize : 13) + delta))
    }
    private func cycle(_ direction: Int) {
        guard !model.tabs.isEmpty else { return }
        let current = model.tabs.firstIndex { $0.id == model.selectedTab } ?? 0
        model.selectedTab = model.tabs[(current + direction + model.tabs.count) % model.tabs.count].id
    }
}

private struct WindowTitleHider: NSViewRepresentable {
    final class TitleView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titleVisibility = .hidden
        }
    }
    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ view: TitleView, context: Context) { view.window?.titleVisibility = .hidden }
}
