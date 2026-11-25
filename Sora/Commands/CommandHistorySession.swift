import AppKit

/// A history preview never edits ZLE. Cancel can therefore restore the exact
/// draft and cursor without replaying editing keys or racing shell redraws.
final class CommandHistorySession {
    private(set) var isPresented = false
    private(set) var isLoading = false
    private(set) var entries: [CommandHistoryEntry] = [] // newest first
    private(set) var selectedIndex = 0
    private(set) var draft = ""
    private(set) var errorMessage: String?
    var onChange: (() -> Void)?
    private let worker: DispatchQueue
    private var requestID = UUID()

    init(worker: DispatchQueue = DispatchQueue(label: "dev.sora.history-recall", qos: .userInitiated)) {
        self.worker = worker
    }

    var selected: CommandHistoryEntry? {
        entries.indices.contains(selectedIndex) ? entries[selectedIndex] : nil
    }

    func open(draft: String, load: @escaping (String) throws -> [CommandHistoryEntry]) {
        self.draft = draft
        entries = []
        selectedIndex = 0
        errorMessage = nil
        isPresented = true
        isLoading = true
        requestID = UUID()
        let request = requestID
        onChange?()
        worker.async { [weak self] in
            let result = Result { try load(draft) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPresented, self.requestID == request else { return }
                self.isLoading = false
                switch result {
                case .success(let entries):
                    self.entries = entries
                    self.selectedIndex = min(self.selectedIndex, max(0, entries.count - 1))
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
                self.onChange?()
            }
        }
    }

    func move(older: Bool) {
        guard isPresented else { return }
        if older {
            selectedIndex = isLoading ? selectedIndex + 1 : min(selectedIndex + 1, max(0, entries.count - 1))
        } else if selectedIndex > 0 {
            selectedIndex -= 1
        } else {
            dismiss()
            return
        }
        onChange?()
    }

    func select(index: Int) {
        guard entries.indices.contains(index) else { return }
        selectedIndex = index
        onChange?()
    }

    func dismiss() {
        guard isPresented else { return }
        requestID = UUID()
        isPresented = false
        isLoading = false
        entries = []
        selectedIndex = 0
        errorMessage = nil
        onChange?()
    }
}

enum CommandHistoryInput {
    static func opensHistory(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                             promptReady: Bool, hasShellIntegration: Bool,
                             draft: String, cursorOffset: Int) -> Bool {
        guard promptReady, hasShellIntegration,
              modifiers.isDisjoint(with: [.command, .control, .option, .shift]),
              keyCode == PromptEvent.upArrow || keyCode == PromptEvent.downArrow else { return false }
        let scalars = Array(draft.unicodeScalars)
        let cursor = min(max(0, cursorOffset), scalars.count)
        // Vertical movement inside a multiline draft still belongs to ZLE.
        if keyCode == PromptEvent.upArrow { return !scalars[..<cursor].contains("\n") }
        return !scalars[cursor...].contains("\n")
    }
}

/// Keep a selected row visible even above a six-line input at the window's
/// minimum height. The picker gives up chrome before it gives up its rows.
struct CommandHistoryLayout {
    static func panelHeight(preferred: CGFloat, pane: CGFloat, input: CGFloat) -> CGFloat {
        min(preferred, max(0, pane - input))
    }

    let height: CGFloat
    var header: CGFloat { height >= 98 ? 35 : 0 }
    var footer: CGFloat { height >= 66 ? 33 : (height >= 48 ? 18 : 0) }
    var rows: CGFloat { max(0, height - header - footer) }
}
