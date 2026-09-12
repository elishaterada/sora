import Foundation

enum PaneSplitAxis: String, Codable, Sendable { case right, below }
enum PaneFocusDirection { case left, right, up, down }

/// The same bounded tree uses session UUIDs in workspaces and tab indices in
/// reusable templates. It owns geometry and identity, never terminal processes.
indirect enum PaneLayout<PaneID: Hashable & Codable & Sendable>: Codable, Equatable, Sendable {
    case leaf(PaneID)
    case split(id: UUID, axis: PaneSplitAxis, fraction: Double, first: Self, second: Self)

    static var maximumPanes: Int { 8 }
    var leaves: [PaneID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, _, let first, let second): return first.leaves + second.leaves
        }
    }
    var isSplit: Bool { if case .split = self { return true }; return false }

    func focusAfterRemoving(_ id: PaneID) -> PaneID? {
        let ordered = leaves
        guard let index = ordered.firstIndex(of: id), ordered.count > 1 else { return nil }
        let remaining = ordered.filter { $0 != id }
        return remaining[min(index, remaining.count - 1)]
    }

    func isValid(allowed: Set<PaneID>) -> Bool {
        var panes = Set<PaneID>(), branches = Set<UUID>()
        func visit(_ node: Self, depth: Int) -> Bool {
            guard depth < Self.maximumPanes else { return false }
            switch node {
            case .leaf(let id): return allowed.contains(id) && panes.insert(id).inserted
            case .split(let id, _, let fraction, let first, let second):
                return fraction.isFinite && (0.2...0.8).contains(fraction) && branches.insert(id).inserted
                    && visit(first, depth: depth + 1) && visit(second, depth: depth + 1)
            }
        }
        return visit(self, depth: 0) && panes.count <= Self.maximumPanes
    }

    func splitting(_ target: PaneID, adding newID: PaneID, axis: PaneSplitAxis) -> Self {
        switch self {
        case .leaf(let id): return id == target ? .split(id: UUID(), axis: axis, fraction: 0.5, first: self, second: .leaf(newID)) : self
        case .split(let id, let direction, let fraction, let first, let second):
            return .split(id: id, axis: direction, fraction: fraction,
                first: first.splitting(target, adding: newID, axis: axis), second: second.splitting(target, adding: newID, axis: axis))
        }
    }

    /// Collapse only removed branches. Other sessions retain their positions.
    func retaining(_ allowed: Set<PaneID>) -> Self? {
        switch self {
        case .leaf(let id): return allowed.contains(id) ? self : nil
        case .split(let id, let axis, let fraction, let first, let second):
            let a = first.retaining(allowed), b = second.retaining(allowed)
            if let a, let b { return .split(id: id, axis: axis, fraction: fraction, first: a, second: b) }
            return a ?? b
        }
    }

    func settingFraction(_ value: Double, for branch: UUID) -> Self {
        guard value.isFinite else { return self }
        switch self {
        case .leaf: return self
        case .split(let id, let axis, let fraction, let first, let second):
            return .split(id: id, axis: axis, fraction: id == branch ? min(0.8, max(0.2, value)) : fraction,
                first: first.settingFraction(value, for: branch), second: second.settingFraction(value, for: branch))
        }
    }

    func mapLeaves<T>(_ transform: (PaneID) -> T) -> PaneLayout<T> {
        switch self {
        case .leaf(let id): return .leaf(transform(id))
        case .split(let id, let axis, let fraction, let first, let second):
            return .split(id: id, axis: axis, fraction: fraction,
                first: first.mapLeaves(transform), second: second.mapLeaves(transform))
        }
    }

    struct Divider {
        let id: UUID
        let axis: PaneSplitAxis
        let frame: CGRect
        let container: CGRect
        let fraction: Double
    }
    struct Geometry {
        var panes: [PaneID: CGRect] = [:]
        var dividers: [Divider] = []
    }
    /// AppKit coordinates: the first child is left or above the second child.
    func geometry(in bounds: CGRect) -> Geometry {
        var result = Geometry()
        func visit(_ node: Self, rect: CGRect) {
            switch node {
            case .leaf(let id): result.panes[id] = rect
            case .split(let id, let axis, let fraction, let first, let second):
                let available = max(0, (axis == .right ? rect.width : rect.height) - 1)
                let length = (available * fraction).rounded(.down)
                let a: CGRect, b: CGRect, divider: CGRect
                if axis == .right {
                    a = CGRect(x: rect.minX, y: rect.minY, width: length, height: rect.height)
                    b = CGRect(x: rect.minX + length + 1, y: rect.minY, width: available - length, height: rect.height)
                    divider = CGRect(x: a.maxX - 3, y: rect.minY, width: 7, height: rect.height)
                } else {
                    a = CGRect(x: rect.minX, y: rect.maxY - length, width: rect.width, height: length)
                    b = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: available - length)
                    divider = CGRect(x: rect.minX, y: a.minY - 4, width: rect.width, height: 7)
                }
                result.dividers.append(Divider(id: id, axis: axis, frame: divider, container: rect, fraction: fraction))
                visit(first, rect: a); visit(second, rect: b)
            }
        }
        visit(self, rect: bounds)
        return result
    }

    func neighbor(of id: PaneID, direction: PaneFocusDirection) -> PaneID? {
        let frames = geometry(in: CGRect(x: 0, y: 0, width: 10_000, height: 10_000)).panes
        guard let source = frames[id] else { return nil }
        var best: (PaneID, CGFloat)?
        // Leaf order gives deterministic tie-breaking at a nested divider.
        for candidate in leaves where candidate != id {
            guard let rect = frames[candidate] else { continue }
            let primary: CGFloat, cross: CGFloat, overlaps: Bool
            switch direction {
            case .left, .right:
                primary = direction == .left ? source.midX - rect.midX : rect.midX - source.midX
                cross = abs(source.midY - rect.midY)
                overlaps = min(source.maxY, rect.maxY) > max(source.minY, rect.minY)
            case .up, .down:
                primary = direction == .up ? rect.midY - source.midY : source.midY - rect.midY
                cross = abs(source.midX - rect.midX)
                overlaps = min(source.maxX, rect.maxX) > max(source.minX, rect.minX)
            }
            guard primary > 0, overlaps else { continue }
            let score = primary + cross
            if best == nil || score < best!.1 { best = (candidate, score) }
        }
        return best?.0
    }
}

extension WorkspaceSnapshot {
    func restoredPaneLayout() -> PaneLayout<UUID>? {
        let allowed = Set(sessionIDs ?? [])
        if let paneLayout, paneLayout.isValid(allowed: allowed) { return paneLayout.isSplit ? paneLayout : nil }
        guard let pair = splitIDs, pair.count == 2, Set(pair).count == 2, pair.allSatisfy(allowed.contains) else { return nil }
        let fraction = splitFraction.flatMap { $0.isFinite ? min(0.8, max(0.2, $0)) : nil } ?? 0.5
        return .split(id: UUID(), axis: .right, fraction: fraction, first: .leaf(pair[0]), second: .leaf(pair[1]))
    }
}
