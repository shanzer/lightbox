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

    /// What a shift-click extends *from*, as opposed to what it extends *to*.
    ///
    /// The selection as it stood when the current range began — the last plain
    /// or ⌘-click. A shift-click is `base ∪ range`, which is the only way to get
    /// both AppKit behaviours at once: rows built up with ⌘ survive a
    /// subsequent shift-extend, and repeated shift-clicks still *replace* the
    /// range rather than accumulating it, because each one unions a fresh range
    /// onto the same unchanging base.
    ///
    /// Without it, ⌘-click 2, ⌘-click 4, shift-click 6 gives `[4, 5, 6]` where
    /// the Finder gives `[2, 4, 5, 6]` — the two ⌘-built rows silently thrown
    /// away. Private because it is a consequence of the click history, never
    /// something a caller sets; it participates in `==` because two selections
    /// that look alike but extend differently are not interchangeable.
    private var base: Set<Int64> = []

    public init() {}

    public mutating func click(_ id: Int64, in order: [Int64], shift: Bool, command: Bool) {
        // A shift-click whose anchor is no longer on screen — the grid reloaded
        // after a rescan and the anchored row was deleted — falls through to a
        // plain click rather than doing nothing. `retain(_:)` normally prevents
        // that, but a caller is not required to have called it.
        if shift, let anchor, let from = order.firstIndex(of: anchor),
           let to = order.firstIndex(of: id) {
            let range = from <= to ? from...to : to...from
            // Unioned onto the base, not assigned over it, so ⌘-built rows
            // outside the range survive — and, because the base does not move
            // while shift-clicking, a shorter range still replaces a longer one.
            selected = base.union(order[range])
            return
        }

        if command {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            // The anchor moves even when the click *removed* the row from the
            // selection: in the Finder a subsequent shift-click extends from
            // the row last touched, not from the row last added.
            anchor = id
            base = selected
            return
        }

        selected = [id]
        anchor = id
        base = selected
    }

    public mutating func selectAll(_ order: [Int64]) {
        selected = Set(order)
        anchor = order.first
        base = selected
    }

    public mutating func clear() {
        selected = []
        anchor = nil
        base = []
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
    /// An anchor whose row is gone is *moved*, not dropped, to the lowest
    /// surviving selected id.
    ///
    /// Dropping it and keeping a dangling one look different but behave
    /// identically, and both are wrong: `click(_:in:shift:command:)` cannot
    /// resolve an anchor that is not in `order`, so it degrades to a plain
    /// click, and the user's next shift-click collapses a multi-row selection
    /// to the single row they clicked. Measured: click 2, shift-click 5,
    /// `retain([3, 4, 5, 6])`, shift-click 6 gives `[6]` — three rows gone
    /// without a gesture that asked for it. Re-anchoring gives `[3, 4, 5, 6]`,
    /// which is the range the user still has on screen.
    ///
    /// Lowest surviving *selected* id, because the anchor's job is to be one
    /// end of the current range and the surviving selection is all that is left
    /// of it. When nothing survives there is no range to extend and the anchor
    /// is genuinely nil.
    public mutating func retain(_ living: Set<Int64>) {
        selected.formIntersection(living)
        // The base is pruned too, or a later shift-click would union dead ids
        // straight back into the selection.
        base.formIntersection(living)
        if let anchor, !living.contains(anchor) { self.anchor = selected.min() }
    }

    /// The id `offset` positions away, clamped to the ends. Returns nil when
    /// `id` is not in `order` at all.
    ///
    /// The overflow case is handled rather than trapped. `index + offset` traps
    /// on `Int.max`, and while the grid only ever passes ±1, this is public
    /// `Core` API whose documented contract is "clamped to the ends" — an
    /// offset large enough to overflow is an offset past the end, so it clamps
    /// to whichever end it ran towards.
    public func neighbour(of id: Int64, in order: [Int64], offset: Int) -> Int64? {
        guard let index = order.firstIndex(of: id) else { return nil }
        let (sum, overflowed) = index.addingReportingOverflow(offset)
        let target = overflowed
            ? (offset > 0 ? order.count - 1 : 0)
            : min(max(0, sum), order.count - 1)
        return order[target]
    }
}
