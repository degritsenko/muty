import SwiftUI
import AppKit

enum SavedSessionSearch {
    static func matches(_ profiles: [SessionProfile], query: String) -> [SessionProfile] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return profiles.filter {
            [$0.name, $0.host].contains { $0.localizedStandardContains(query) }
        }.sorted {
            let leftPrefix = $0.name.lowercased().hasPrefix(query.lowercased()) || $0.host.lowercased().hasPrefix(query.lowercased())
            let rightPrefix = $1.name.lowercased().hasPrefix(query.lowercased()) || $1.host.lowercased().hasPrefix(query.lowercased())
            if leftPrefix != rightPrefix { return leftPrefix }
            let order = $0.name.localizedStandardCompare($1.name)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

private final class SessionSuggestionsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct SavedSessionSearchField: NSViewRepresentable {
    @ObservedObject var model: AppModel
    var onSelect: ((SessionProfile) -> Void)? = nil
    var selectedName: String? = nil
    var focusOnAppear = false

    func makeCoordinator() -> Coordinator { Coordinator(model: model, onSelect: onSelect) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Find saved session"
        field.setAccessibilityLabel("Find saved session")
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        context.coordinator.field = field
        if focusOnAppear {
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.profiles = model.profiles
        context.coordinator.onSelect = onSelect
        if let selectedName, field.currentEditor() == nil { field.stringValue = selectedName }
        if context.coordinator.panel.isVisible { context.coordinator.refresh() }
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.dismiss()
        field.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        weak var field: NSSearchField?
        private weak var model: AppModel?
        var profiles: [SessionProfile]
        var onSelect: ((SessionProfile) -> Void)?
        fileprivate let panel = SessionSuggestionsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                                        backing: .buffered, defer: false)
        private var results: [SessionProfile] = []
        private var selected = 0
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []

        init(model: AppModel, onSelect: ((SessionProfile) -> Void)?) {
            self.onSelect = onSelect
            self.model = model
            profiles = model.profiles
            super.init()
            panel.isReleasedWhenClosed = false
            panel.hasShadow = true
            panel.backgroundColor = .windowBackgroundColor
            panel.hidesOnDeactivate = true
        }

        func controlTextDidChange(_ notification: Notification) {
            selected = 0
            refresh()
        }

        func controlTextDidBeginEditing(_ notification: Notification) { refresh() }
        func controlTextDidEndEditing(_ notification: Notification) { dismiss() }

        @objc func submit(_ sender: NSSearchField) {
            guard !sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !results.isEmpty else { return }
            connect(results[selected])
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            if command == #selector(NSResponder.cancelOperation(_:)) {
                dismiss()
                field?.stringValue = ""
                field?.window?.makeFirstResponder(nil)
                return true
            }
            if command == #selector(NSResponder.insertNewline(_:)) {
                if !results.isEmpty { connect(results[selected]) }
                return true
            }
            if command == #selector(NSResponder.moveDown(_:)) || command == #selector(NSResponder.moveUp(_:)) {
                guard !results.isEmpty else { return true }
                selected = max(0, min(results.count - 1, selected + (command == #selector(NSResponder.moveDown(_:)) ? 1 : -1)))
                render()
                return true
            }
            return false
        }

        func refresh() {
            guard let field, field.window != nil else { dismiss(); return }
            results = Array(SavedSessionSearch.matches(profiles, query: field.stringValue).prefix(12))
            selected = max(0, min(selected, results.count - 1))
            guard !results.isEmpty else { dismiss(); return }
            render()
            if !panel.isVisible, let parent = field.window {
                parent.addChildWindow(panel, ordered: .above)
                panel.orderFront(nil)
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    guard let self else { return event }
                    if event.window === self.panel { return event }
                    if let field = self.field, event.window === field.window,
                       field.bounds.contains(field.convert(event.locationInWindow, from: nil)) { return event }
                    self.dismiss()
                    return event
                }
                for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.position() }
                    })
                }
                observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: parent, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dismiss() }
                })
            }
        }

        private func render() {
            guard !results.isEmpty else { dismiss(); return }
            let height = CGFloat(min(results.count, 6) * 48)
            panel.contentView = NSHostingView(rootView: ScrollViewReader { [self] proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, profile in
                                Button { [weak self] in self?.connect(profile) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.folder.map { $0 + "/" + profile.name } ?? profile.name)
                                            .lineLimit(1)
                                        Text(profile.connectionType == .localShell ? "Local shell" : profile.endpoint)
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(index == selected ? Color.accentColor.opacity(0.2) : .clear)
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain).id(profile.id)
                            }
                    }
                }.onAppear {
                    if !results.isEmpty { proxy.scrollTo(results[selected].id) }
                }
            }.frame(width: 340, height: height))
            panel.setContentSize(NSSize(width: 340, height: height))
            position()
        }

        private func position() {
            guard let field, let parent = field.window else { return }
            let anchor = parent.convertToScreen(field.convert(field.bounds, to: nil))
            let visible = onSelect == nil ? (parent.screen?.visibleFrame ?? parent.frame) : parent.frame
            panel.setFrameOrigin(NSPoint(x: max(visible.minX, min(anchor.minX, visible.maxX - panel.frame.width)),
                                         y: max(visible.minY, anchor.minY - panel.frame.height - 4)))
        }

        private func connect(_ profile: SessionProfile) {
            guard let current = model?.profiles.first(where: { $0.id == profile.id }) else { dismiss(); return }
            dismiss()
            field?.stringValue = ""
            field?.window?.makeFirstResponder(nil)
            if let onSelect {
                field?.stringValue = current.name
                onSelect(current)
            } else { model?.connect(current) }
        }

        func dismiss() {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }
}
