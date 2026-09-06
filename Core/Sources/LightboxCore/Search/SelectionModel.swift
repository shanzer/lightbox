import Foundation

/// Finder-style multiple selection.
///
/// Lives in `Core` rather than in the grid because these are rules, not
/// presentation: getting shift-click wrong is obvious in a test and invisible
/// in a demo, and Task 18 may replace the grid wholesale with an
/// `NSCollectionView` bridge. The selection has to survive that swap unchanged.
///
/// Everything is expressed against an `order` the caller passes in — the ids
/// currently on screen, in display order — so this type never has to be told
/// about sorting, filtering, or which folder is open.
public struct SelectionModel: Sendable, Hashable {
    public private(set) var selected: Set<Int64> = []

    /// The row a range extends from. Deliberately *not* moved by a shift-click:
    /// that is what lets a user widen and then narrow a range by shift-clicking
    /// repeatedly, which is how every macOS list behaves.
    public private(set) var anchor: Int64?

    public init() {}

    public mutating func click(_ id: Int64, in order: [Int64], shift: Bool, command: Bool) {
        // A shift-click whose anchor is no longer on screen — the grid reloaded
        // after a rescan and the anchored row was deleted — falls through to a
        // plain click rather than doing nothing. `retain(_:)` normally prevents
        // that, but a caller is not required to have called it.
        if shift, let anchor, let from = order.firstIndex(of: anchor),
           let to = order.firstIndex(of: id) {
            let range = from <= to ? from...to : to...from
            selected = Set(order[range])
            return
        }

        if command {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            // The anchor moves even when the click *removed* the row from the
            // selection: in the Finder a subsequent shift-click extends from
            // the row last touched, not from the row last added.
            anchor = id
            return
        }

        selected = [id]
        anchor = id
    }

    public mutating func selectAll(_ order: [Int64]) {
        selected = Set(order)
        anchor = order.first
    }

    public mutating func clear() {
        selected = []
        anchor = nil
    }

    /// Drops everything that is no longer on screen.
    ///
    /// Called whenever the record set changes — a rescan deleted rows, the user
    /// flipped the subfolder toggle — so the selection cannot accumulate ids
    /// for files that are gone. Two things make this the right primitive rather
    /// than rebuilding the selection by replaying clicks over the surviving
    /// ids: replaying depends on `Set` iteration order, which is not stable
    /// between runs, and every replayed `click` moves the anchor, so the user's
    /// range would silently re-anchor on whichever id happened to come last.
    ///
    /// The anchor goes too when its row is gone. Keeping it would leave a
    /// shift-click extending from a file that is no longer there, which
    /// `click(_:in:shift:command:)` can only treat as a plain click — a
    /// user-visible surprise for a state that is trivially avoidable here.
    public mutating func retain(_ living: Set<Int64>) {
        selected.formIntersection(living)
        if let anchor, !living.contains(anchor) { self.anchor = nil }
    }

    /// The id `offset` positions away, clamped to the ends. Returns nil when
    /// `id` is not in `order` at all.
    public func neighbour(of id: Int64, in order: [Int64], offset: Int) -> Int64? {
        guard let index = order.firstIndex(of: id) else { return nil }
        let target = min(max(0, index + offset), order.count - 1)
        return order[target]
    }
}
