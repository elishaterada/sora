import AppKit
import SwiftUI

struct ShortcutSettingsSection: View {
    @ObservedObject var shortcuts: AppShortcutStore
    @State private var selected = AppShortcutAction.commandPalette
    var body: some View {
        Section("App shortcuts") {
            Picker("Action", selection: $selected) {
                ForEach(AppShortcutAction.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                Text(shortcuts.binding(selected).display).font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Current shortcut: " + shortcuts.binding(selected).display)
                Spacer()
                ShortcutRecorder { binding in _ = shortcuts.set(binding, for: selected) }
                    .id(selected).frame(width: 150, height: 28)
                Button("Reset") { shortcuts.reset(selected) }
            }
            Text("Record a Command shortcut. Escape cancels. Standard editing, tab numbers and terminal input keys stay available.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = shortcuts.errorMessage { Text(error).font(.caption).foregroundStyle(SoraTheme.danger) }
            Button("Restore All App Shortcuts") { shortcuts.resetAll() }
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let onRecord: (AppKeyBinding) -> Void
    func makeNSView(context: Context) -> ShortcutRecordButton {
        let button = ShortcutRecordButton()
        button.onRecord = onRecord
        return button
    }
    func updateNSView(_ nsView: ShortcutRecordButton, context: Context) { nsView.onRecord = onRecord }
    static func dismantleNSView(_ nsView: ShortcutRecordButton, coordinator: ()) { nsView.stopRecording() }
}

/// Captures only while this explicit control is recording in its key window.
/// It never registers a global listener or observes another app's keystrokes.
private final class ShortcutRecordButton: NSButton {
    var onRecord: ((AppKeyBinding) -> Void)?
    private var monitor: Any?
    private var windowObserver: NSObjectProtocol?
    init() {
        super.init(frame: .zero)
        title = "Record Shortcut"
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        setAccessibilityLabel("Record shortcut")
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }
    @objc private func startRecording() {
        stopRecording()
        title = "Press shortcut…"
        setAccessibilityLabel("Press a Command shortcut, or Escape to cancel")
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.window != nil, event.window === self.window, self.window?.isKeyWindow == true else {
                self.stopRecording()
                return event
            }
            self.stopRecording()
            if event.keyCode != 53 { self.onRecord?(AppKeyBinding(event: event)) }
            return nil
        }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in self?.stopRecording() }
    }
    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        title = "Record Shortcut"
        setAccessibilityLabel("Record shortcut")
    }
}
