import AppKit
import Combine
import SwiftUI

struct AgentTranscriptFollowPolicy {
    private(set) var following = true
    private(set) var hasNewResponse = false
    mutating func scrolled(distanceFromBottom: CGFloat) {
        following = distanceFromBottom <= 40
        if following { hasNewResponse = false }
    }
    mutating func receivedContent() -> Bool {
        if !following { hasNewResponse = true }
        return following
    }
    mutating func jump() { following = true; hasNewResponse = false }
}

@MainActor
final class AgentTranscriptScrollController: ObservableObject {
    @Published fileprivate(set) var hasNewResponse = false
    fileprivate weak var observer: AgentTranscriptScrollObserverView?
    func showLatest() { observer?.showLatest() }
    func preserveBeforePrepending() { observer?.preserveBeforePrepending() }
}

/// Observe the existing native scroll view. Scrolling never changes SwiftUI's
/// layout constraints or starts an animation for each streaming chunk.
struct AgentTranscriptScrollObserver: NSViewRepresentable {
    let controller: AgentTranscriptScrollController
    let revision: String
    func makeNSView(context: Context) -> AgentTranscriptScrollObserverView {
        AgentTranscriptScrollObserverView(controller: controller)
    }
    func updateNSView(_ view: AgentTranscriptScrollObserverView, context: Context) {
        view.receive(revision: revision)
    }
}

final class AgentTranscriptScrollObserverView: NSView {
    private weak var controller: AgentTranscriptScrollController?
    private weak var scroll: NSScrollView?
    private var observations = Set<AnyCancellable>()
    private var policy = AgentTranscriptFollowPolicy()
    private var revision = ""
    private var pendingTail = true
    private var tailUntil = Date.distantPast
    private var scheduled = false
    private var adjusting = false
    private var priorHeight: CGFloat = 0
    private var prepend: (height: CGFloat, origin: NSPoint)?

    init(controller: AgentTranscriptScrollController) {
        self.controller = controller
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }

    private func attach() {
        guard window != nil, let found = enclosingScrollView, found !== scroll,
              let document = found.documentView else { return }
        observations.removeAll()
        scroll = found
        controller?.observer = self
        priorHeight = document.bounds.height
        found.contentView.postsBoundsChangedNotifications = true
        document.postsFrameChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: found.contentView)
            .sink { [weak self] _ in self?.boundsChanged() }.store(in: &observations)
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: document)
            .sink { [weak self] _ in self?.documentChanged() }.store(in: &observations)
        NotificationCenter.default.publisher(for: NSScrollView.willStartLiveScrollNotification, object: found)
            .sink { [weak self] _ in
                self?.pendingTail = false
                self?.tailUntil = .distantPast
            }.store(in: &observations)
        schedule()
    }

    func receive(revision: String) {
        guard self.revision != revision else { return }
        self.revision = revision
        // Defer publication out of NSViewRepresentable's update phase.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.attach()
            self.pendingTail = self.policy.receivedContent()
            if self.pendingTail { self.tailUntil = Date().addingTimeInterval(0.3) }
            self.publish()
            self.schedule()
        }
    }

    func preserveBeforePrepending() {
        guard let scroll, let document = scroll.documentView else { return }
        prepend = (document.bounds.height, scroll.contentView.bounds.origin)
        pendingTail = false
        tailUntil = .distantPast
    }

    func showLatest() {
        policy.jump()
        pendingTail = true
        tailUntil = Date().addingTimeInterval(0.3)
        publish()
        schedule()
    }

    private func boundsChanged() {
        guard !adjusting, let scroll, let document = scroll.documentView else { return }
        // A taller document is new layout, not a user scrolling upward.
        if abs(document.bounds.height - priorHeight) > 1 { return }
        if pendingTail || Date() < tailUntil || prepend != nil { return }
        policy.scrolled(distanceFromBottom: distanceFromBottom())
        publish()
    }

    private func documentChanged() {
        guard let scroll, let document = scroll.documentView else { return }
        priorHeight = document.bounds.height
        if pendingTail || Date() < tailUntil || prepend != nil { schedule() }
        else { policy.scrolled(distanceFromBottom: distanceFromBottom()); publish() }
    }

    private func distanceFromBottom() -> CGFloat {
        guard let scroll, let document = scroll.documentView else { return 0 }
        return document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.maxY
            : scroll.contentView.bounds.minY - document.bounds.minY
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard let scroll = self.scroll, let document = scroll.documentView else { return }
            var point = scroll.contentView.bounds.origin
            if let anchor = self.prepend {
                if document.bounds.height == anchor.height { return }
                point = anchor.origin
                if document.isFlipped { point.y += document.bounds.height - anchor.height }
                self.prepend = nil
            } else if self.pendingTail || Date() < self.tailUntil {
                point.y = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height) : document.bounds.minY
                self.pendingTail = false
            } else { return }
            self.adjusting = true
            scroll.contentView.scroll(to: point)
            scroll.reflectScrolledClipView(scroll.contentView)
            self.adjusting = false
            self.priorHeight = document.bounds.height
        }
    }

    private func publish() {
        let unread = policy.hasNewResponse
        if controller?.hasNewResponse != unread { controller?.hasNewResponse = unread }
    }
}
