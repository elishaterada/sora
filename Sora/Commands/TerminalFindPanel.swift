import AppKit

/// Ghostty searches live terminal state. Block scope and line filtering use a
/// clearly labelled immutable snapshot, without replacing the terminal grid.
final class TerminalFindPanel: NSObject, NSSearchFieldDelegate, NSWindowDelegate {
    private weak var surface: GhosttySurfaceView?
    private weak var previousResponder: NSResponder?
    private let panel = TerminalFindWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 146),
        styleMask: [.titled, .closable, .utilityWindow, .resizable], backing: .buffered, defer: false)
    private let field = NSSearchField()
    private let scopeControl = NSSegmentedControl(labels: ["Terminal", "Selected block"], trackingMode: .selectOne, target: nil, action: nil)
    private let filter = NSButton(checkboxWithTitle: "Only matching lines", target: nil, action: nil)
    private let refresh = NSButton(title: "Refresh Snapshot", target: nil, action: nil)
    private let reset = NSButton(title: "Show All Lines", target: nil, action: nil)
    private let count = NSTextField(labelWithString: "Type to search output")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let previous = NSButton(title: "↑", target: nil, action: nil)
    private let next = NSButton(title: "↓", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let output = NSTextView()
    private let worker = OutputSearchWorker()
    private var snapshot: OutputSearchSnapshot?
    private var result: OutputSearchText.Result?
    private var selectedMatch: Int?
    private var nativeTotal = -1
    private var nativeSelected = -1
    private var restoreFocusOnClose = true
    private var expanded = false
    private var scope: OutputSearchScope { OutputSearchScope(rawValue: scopeControl.selectedSegment) ?? .terminal }
    private var readsSnapshot: Bool { scope == .selectedBlock || filter.state == .on }

    init(surface: GhosttySurfaceView) {
        self.surface = surface
        super.init()
        panel.title = "Find in Terminal Output"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 660, height: 168)
        let root = OutputSearchContentView()
        root.onLayout = { [weak self] bounds in self?.layout(in: bounds) }
        panel.contentView = root
        panel.onFind = { [weak self] in guard let self else { return }; self.panel.makeFirstResponder(self.field) }
        field.placeholderString = "Find in output"
        field.setAccessibilityLabel("Find in output")
        field.delegate = self
        field.sendsSearchStringImmediately = true
        scopeControl.selectedSegment = 0
        scopeControl.target = self; scopeControl.action = #selector(scopeChanged)
        scopeControl.setAccessibilityLabel("Search scope")
        filter.target = self; filter.action = #selector(filterChanged)
        refresh.target = self; refresh.action = #selector(refreshSnapshot)
        reset.target = self; reset.action = #selector(resetFilter)
        previous.target = self; previous.action = #selector(previousMatch)
        next.target = self; next.action = #selector(nextMatch)
        previous.setAccessibilityLabel("Previous match")
        next.setAccessibilityLabel("Next match")
        count.font = .systemFont(ofSize: 12)
        count.setAccessibilityLabel("Search match position")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        output.isEditable = false
        output.isSelectable = true
        output.isRichText = false
        output.isAutomaticLinkDetectionEnabled = false
        output.isAutomaticDataDetectionEnabled = false
        output.font = SoraTheme.terminalFont
        output.textColor = .textColor
        output.backgroundColor = .textBackgroundColor
        output.isVerticallyResizable = true
        output.isHorizontallyResizable = false
        output.autoresizingMask = [.width]
        output.textContainer?.widthTracksTextView = true
        output.textContainerInset = NSSize(width: 12, height: 12)
        output.setAccessibilityLabel("Output snapshot, read only")
        scroll.documentView = output
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        for view in [field, scopeControl, filter, refresh, reset, count, status, previous, next, scroll] { root.addSubview(view) }
        worker.onResult = { [weak self] result in
            guard let self, self.panel.isVisible, self.readsSnapshot else { return }
            self.result = result
            self.output.string = result.text
            self.selectedMatch = result.next(from: nil, previous: false)
            self.updateResultSelection()
            self.updateStatus()
        }
    }

    func show(scope: OutputSearchScope, query: String?) {
        guard let surface, let window = surface.window else { return }
        previousResponder = window.firstResponder
        restoreFocusOnClose = true
        scopeControl.setEnabled(surface.isBrowsingCommandBlocks, forSegment: 1)
        scopeControl.selectedSegment = scope.rawValue
        filter.state = .off
        snapshot = nil
        if let query { field.stringValue = String(query.prefix(512)) }
        panel.setFrameTopLeftPoint(NSPoint(x: window.frame.maxX - panel.frame.width - 20, y: window.frame.maxY - 70))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.selectText(nil)
        changeMode(capture: true)
    }

    func setCount(_ total: Int) {
        guard panel.isVisible, !readsSnapshot else { return }
        nativeTotal = total
        updateNativeCount()
    }
    func setSelected(_ index: Int) {
        guard panel.isVisible, !readsSnapshot else { return }
        nativeSelected = index
        updateNativeCount()
    }
    func dismiss(returnFocus: Bool = true) {
        guard panel.isVisible else { return }
        restoreFocusOnClose = returnFocus
        panel.close()
    }

    private func layout(in bounds: NSRect) {
        let width = bounds.width, top = bounds.height
        field.frame = NSRect(x: 12, y: top - 36, width: width - 242, height: 24)
        previous.frame = NSRect(x: width - 220, y: top - 39, width: 36, height: 28)
        next.frame = NSRect(x: width - 180, y: top - 39, width: 36, height: 28)
        count.frame = NSRect(x: width - 136, y: top - 34, width: 124, height: 20)
        scopeControl.frame = NSRect(x: 12, y: top - 75, width: 224, height: 28)
        filter.frame = NSRect(x: 250, y: top - 73, width: 170, height: 24)
        refresh.frame = NSRect(x: width - 146, y: top - 75, width: 134, height: 28)
        status.frame = NSRect(x: 12, y: top - 136, width: width - 148, height: 50)
        reset.frame = NSRect(x: width - 132, y: top - 118, width: 120, height: 28)
        scroll.frame = NSRect(x: 12, y: 12, width: width - 24, height: max(0, top - 156))
    }

    @objc private func scopeChanged() { snapshot = nil; changeMode(capture: true) }
    @objc private func filterChanged() { changeMode(capture: snapshot == nil) }
    @objc private func resetFilter() { filter.state = .off; changeMode(capture: false) }
    @objc private func refreshSnapshot() {
        guard let copy = surface?.captureOutputSearchSnapshot(scope: scope) else {
            status.stringValue = "The source is unavailable. Select a block again to refresh it; the existing snapshot has been kept."
            return
        }
        snapshot = copy
        searchCurrentQuery()
    }
    private func changeMode(capture: Bool) {
        worker.cancel()
        result = nil
        selectedMatch = nil
        if readsSnapshot {
            surface?.endFind()
            if capture { snapshot = surface?.captureOutputSearchSnapshot(scope: scope) }
        }
        refresh.isEnabled = readsSnapshot
        reset.isEnabled = filter.state == .on
        scroll.isHidden = !readsSnapshot
        panel.minSize = NSSize(width: 660, height: readsSnapshot ? 360 : 168)
        if readsSnapshot != expanded {
            expanded = readsSnapshot
            let top = panel.frame.maxY
            panel.setContentSize(NSSize(width: panel.contentView?.bounds.width ?? 700, height: expanded ? 540 : 146))
            panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
        }
        output.font = SoraTheme.terminalFont
        panel.contentView?.needsLayout = true
        if let visible = surface?.window?.screen?.visibleFrame {
            var frame = panel.frame
            frame.size.height = min(frame.height, visible.height - 24)
            frame.origin.x = max(visible.minX + 12, min(frame.minX, visible.maxX - frame.width - 12))
            frame.origin.y = max(visible.minY + 12, min(frame.minY, visible.maxY - frame.height - 12))
            panel.setFrame(frame, display: true)
        }
        searchCurrentQuery()
    }
    func controlTextDidChange(_ obj: Notification) {
        field.stringValue = String(field.stringValue.prefix(512))
        searchCurrentQuery()
    }
    private func searchCurrentQuery() {
        result = nil
        selectedMatch = nil
        previous.isEnabled = false; next.isEnabled = false
        if readsSnapshot {
            guard let snapshot else {
                output.string = ""
                count.stringValue = "No output"
                status.stringValue = "Select a command block to search its output, or switch to Terminal."
                return
            }
            count.stringValue = "Searching…"
            worker.search(source: snapshot.text, query: field.stringValue, filtered: filter.state == .on)
        } else {
            worker.cancel()
            nativeTotal = -1; nativeSelected = -1
            surface?.searchOutput(field.stringValue)
            updateNativeCount()
        }
        updateStatus()
    }
    private func updateNativeCount() {
        if field.stringValue.isEmpty { count.stringValue = "Type to search" }
        else if nativeTotal < 0 { count.stringValue = "Searching…" }
        else if nativeSelected >= 0 && nativeSelected < nativeTotal { count.stringValue = "\(nativeSelected + 1) of \(nativeTotal)" }
        else { count.stringValue = "\(nativeTotal) matches" }
        previous.isEnabled = nativeTotal > 0 && !field.stringValue.isEmpty
        next.isEnabled = previous.isEnabled
    }
    private func updateStatus() {
        guard readsSnapshot else {
            status.stringValue = "Searching live terminal output. Return / Shift–Return moves between matches; Escape returns to the terminal."
            return
        }
        guard let snapshot else { return }
        var parts = ["Snapshot at \(snapshot.capturedAt.formatted(date: .omitted, time: .standard))"]
        if let command = snapshot.command { parts.append("Block: " + String(command.replacingOccurrences(of: "\n", with: " ↵ ").prefix(80))) }
        if snapshot.isExcerpt { parts.append("First 1 MB only") }
        if let lines = result?.matchingLines { parts.append("\(lines)\(result?.hasMoreLines == true ? "+" : "") matching lines") }
        if result?.hasMoreMatches == true { parts.append("First 10,000 matches shown") }
        if result?.hasMoreLines == true { parts.append("First 10,000 matching lines shown") }
        parts.append("Refresh to capture current output.")
        status.stringValue = parts.joined(separator: " · ")
        status.toolTip = status.stringValue
    }
    private func navigate(previous: Bool) {
        if readsSnapshot {
            selectedMatch = result?.next(from: selectedMatch, previous: previous)
            updateResultSelection()
        } else { surface?.navigateFind(previous: previous) }
    }
    private func updateResultSelection() {
        guard let result else { return }
        previous.isEnabled = !result.matches.isEmpty
        next.isEnabled = previous.isEnabled
        guard let selectedMatch, result.matches.indices.contains(selectedMatch) else {
            count.stringValue = field.stringValue.isEmpty ? "Type to search" : "0 matches"
            return
        }
        let range = result.matches[selectedMatch]
        output.setSelectedRange(range)
        output.scrollRangeToVisible(range)
        output.showFindIndicator(for: range)
        count.stringValue = "\(selectedMatch + 1) of \(result.matches.count)\(result.hasMoreMatches ? "+" : "")"
    }
    @objc private func previousMatch() { navigate(previous: true) }
    @objc private func nextMatch() { navigate(previous: false) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            navigate(previous: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) { panel.close(); return true }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        worker.cancel()
        surface?.endFind()
        if restoreFocusOnClose, let window = surface?.window {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(previousResponder ?? surface)
        }
    }
}

private final class OutputSearchContentView: NSView {
    var onLayout: ((NSRect) -> Void)?
    override func layout() { super.layout(); onLayout?(bounds) }
}

private final class TerminalFindWindow: NSPanel {
    var onFind: (() -> Void)?
    private var monitor: Any?
    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self else { return event }
                let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
                if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "f" { self.onFind?(); return nil }
                if (mods == .command && event.charactersIgnoringModifiers?.lowercased() == "w") || (mods.isEmpty && event.keyCode == 53) {
                    self.close(); return nil
                }
                return event
            }
        }
    }
    override func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        super.close()
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
