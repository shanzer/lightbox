import Testing
@testable import LightboxCore

private let order: [Int64] = [1, 2, 3, 4, 5, 6]

@Test func plainClickReplacesTheSelection() {
    var selection = SelectionModel()
    selection.click(3, in: order, shift: false, command: false)
    #expect(selection.selected == [3])
    selection.click(5, in: order, shift: false, command: false)
    #expect(selection.selected == [5])
    #expect(selection.anchor == 5)
}

@Test func commandClickTogglesWithoutClearing() {
    var selection = SelectionModel()
    selection.click(2, in: order, shift: false, command: false)
    selection.click(4, in: order, shift: false, command: true)
    #expect(selection.selected == [2, 4])
    selection.click(2, in: order, shift: false, command: true)
    #expect(selection.selected == [4])
    #expect(selection.anchor == 2)
}

@Test func shiftClickSelectsTheRangeFromTheAnchor() {
    var selection = SelectionModel()
    selection.click(2, in: order, shift: false, command: false)
    selection.click(5, in: order, shift: true, command: false)
    #expect(selection.selected == [2, 3, 4, 5])
    #expect(selection.anchor == 2, "the anchor stays put so the range can be resized")

    // Shrinking the range replaces it rather than accumulating.
    selection.click(3, in: order, shift: true, command: false)
    #expect(selection.selected == [2, 3])
}

@Test func shiftClickWorksBackwards() {
    var selection = SelectionModel()
    selection.click(5, in: order, shift: false, command: false)
    selection.click(2, in: order, shift: true, command: false)
    #expect(selection.selected == [2, 3, 4, 5])
}

@Test func shiftClickWithNoAnchorBehavesLikeAPlainClick() {
    var selection = SelectionModel()
    selection.click(4, in: order, shift: true, command: false)
    #expect(selection.selected == [4])
    #expect(selection.anchor == 4)
}

/// Shift *and* command together resolves to the range, not to a toggle.
///
/// Stated rather than left to fall out of the branch order, because the two
/// modifiers arrive together whenever a user rolls off ⌘ onto ⇧, and silently
/// swapping to a toggle there loses a range the user has just built.
@Test func shiftWinsWhenBothModifiersAreHeld() {
    var selection = SelectionModel()
    selection.click(2, in: order, shift: false, command: false)
    selection.click(4, in: order, shift: true, command: true)
    #expect(selection.selected == [2, 3, 4])
    #expect(selection.anchor == 2)
}

/// The common case `shiftWinsWhenBothModifiersAreHeld` does not cover: the
/// modifiers pressed one after another rather than together.
///
/// ⌘-click 2, ⌘-click 4, then a plain shift-click 6. AppKit keeps the
/// discontiguous rows built with ⌘ and unions the new range onto them; the
/// version that assigned `Set(order[range])` over the selection gave
/// `[4, 5, 6]` and threw row 2 away without a gesture that asked for it.
@Test func shiftClickAfterCommandClicksKeepsTheCommandBuiltSelection() {
    var selection = SelectionModel()
    selection.click(2, in: order, shift: false, command: true)
    selection.click(4, in: order, shift: false, command: true)
    #expect(selection.selected == [2, 4])

    selection.click(6, in: order, shift: true, command: false)
    #expect(selection.selected == [2, 4, 5, 6],
            "the ⌘-built rows are the base the range extends from, not something it replaces")
    #expect(selection.anchor == 4, "the range still extends from the row ⌘ last touched")
}

/// The other half of the same rule, and the reason the base is a separate
/// field rather than just "do not clear the selection": the base does not move
/// while shift-clicking, so a shorter range still *replaces* a longer one
/// instead of accumulating with it.
@Test func repeatedShiftClicksResizeTheRangeOverACommandBuiltBase() {
    var selection = SelectionModel()
    selection.click(1, in: order, shift: false, command: true)
    selection.click(3, in: order, shift: false, command: true)

    selection.click(6, in: order, shift: true, command: false)
    #expect(selection.selected == [1, 3, 4, 5, 6])

    selection.click(4, in: order, shift: true, command: false)
    #expect(selection.selected == [1, 3, 4], "5 and 6 leave the range; the base stays")
}

/// A ⌘-click that *deselects* re-bases too, or the row would reappear on the
/// next shift-click having never been reselected.
///
/// Row 1 is deselected and then left outside both the anchor and the range, so
/// the only way it could come back is out of a stale base.
@Test func aCommandClickThatDeselectsDoesNotLeaveTheRowInTheBase() {
    var selection = SelectionModel()
    selection.click(1, in: order, shift: false, command: true)
    selection.click(3, in: order, shift: false, command: true)
    selection.click(1, in: order, shift: false, command: true)
    selection.click(5, in: order, shift: false, command: true)
    #expect(selection.selected == [3, 5])

    selection.click(6, in: order, shift: true, command: false)
    #expect(selection.selected == [3, 5, 6], "row 1 was removed and must not come back")
}

@Test func selectAllAndClear() {
    var selection = SelectionModel()
    selection.selectAll(order)
    #expect(selection.selected.count == 6)
    #expect(selection.selected == Set(order))
    #expect(selection.anchor == order.first, "the range extends from the topmost row")
    selection.clear()
    #expect(selection.selected.isEmpty)
    #expect(selection.anchor == nil)
}

/// Select All then shift-click has to *narrow*.
///
/// The regression this pins: `selectAll` used to set the shift base to the
/// whole selection, and a shift-click is `base ∪ range`, so the union could
/// never shrink and the gesture became a permanent no-op — `[1...6]` in, all
/// of `[1...6]` back out, where the Finder gives `[1, 2, 3]`. It survived a
/// `retain` too, because `retain` prunes the base but never empties it.
@Test func shiftClickAfterSelectAllNarrowsTheSelection() {
    var selection = SelectionModel()
    selection.selectAll(order)
    selection.click(3, in: order, shift: true, command: false)
    #expect(selection.selected == [1, 2, 3],
            "a shift-click after Select All must narrow to the range, not keep everything")
    #expect(selection.anchor == 1, "a shift-click never moves the anchor")

    // Still repeatable in both directions: the base stayed empty, so widening
    // and re-narrowing both land on exactly the range.
    selection.click(5, in: order, shift: true, command: false)
    #expect(selection.selected == [1, 2, 3, 4, 5])
    selection.click(2, in: order, shift: true, command: false)
    #expect(selection.selected == [1, 2])
}

/// The same narrowing, but after the record set changed underneath it —
/// `retain` prunes the base rather than clearing it, so an unshrinkable base
/// would survive the prune and keep the gesture dead.
@Test func shiftClickAfterSelectAllAndRetainStillNarrows() {
    var selection = SelectionModel()
    selection.selectAll(order)
    let living: [Int64] = [2, 3, 4, 5, 6]
    selection.retain(living)
    #expect(selection.selected == Set(living))

    selection.click(4, in: living, shift: true, command: false)
    #expect(selection.selected == [2, 3, 4])
}

@Test func selectAllOfNothingLeavesNoAnchor() {
    var selection = SelectionModel()
    selection.click(3, in: order, shift: false, command: false)
    selection.selectAll([])
    #expect(selection.selected.isEmpty)
    #expect(selection.anchor == nil, "an empty grid cannot have an anchored row")
}

@Test func selectionSurvivesAnIdThatIsNoLongerInTheOrder() {
    // The grid reloads after a rescan; an id that vanished must not crash a
    // subsequent shift-click.
    var selection = SelectionModel()
    selection.click(99, in: order, shift: false, command: false)
    selection.click(3, in: order, shift: true, command: false)
    #expect(selection.selected == [3])
}

@Test func neighbourWalksTheOrderAndStopsAtTheEnds() {
    let selection = SelectionModel()
    #expect(selection.neighbour(of: 3, in: order, offset: 1) == 4)
    #expect(selection.neighbour(of: 3, in: order, offset: -1) == 2)
    #expect(selection.neighbour(of: 1, in: order, offset: -1) == 1)
    #expect(selection.neighbour(of: 6, in: order, offset: 1) == 6)
    #expect(selection.neighbour(of: 3, in: order, offset: 4) == 6)
    #expect(selection.neighbour(of: 99, in: order, offset: 1) == nil)
}

/// The doc comment promises clamping, so an offset too large to add must clamp
/// rather than trap. `index + offset` crashed with SIGILL on `Int.max`; the
/// grid only ever passes ±1, but this is public `Core` API and a trap is not a
/// contract anyone can code against.
@Test func neighbourClampsInsteadOfTrappingOnOverflow() {
    let selection = SelectionModel()
    #expect(selection.neighbour(of: 3, in: order, offset: .max) == 6)
    #expect(selection.neighbour(of: 3, in: order, offset: .min) == 1)
    #expect(selection.neighbour(of: 1, in: order, offset: .max) == 6)
    #expect(selection.neighbour(of: 6, in: order, offset: .min) == 1)
    #expect(selection.neighbour(of: 99, in: order, offset: .max) == nil,
            "an id that is not on screen has no neighbour, overflow or not")
}

@Test func neighbourOfAnEmptyOrderIsNil() {
    let selection = SelectionModel()
    #expect(selection.neighbour(of: 1, in: [], offset: 1) == nil,
            "clamping to `count - 1` must not index an empty array")
}

// MARK: - retain

@Test func retainDropsIdsThatAreNoLongerOnScreen() {
    var selection = SelectionModel()
    selection.selectAll(order)
    selection.retain([2, 4, 6])
    #expect(selection.selected == [2, 4, 6])
}

@Test func retainKeepsAnAnchorThatSurvived() {
    var selection = SelectionModel()
    selection.click(3, in: order, shift: false, command: false)
    selection.click(5, in: order, shift: true, command: false)
    selection.retain([3, 4, 5])
    #expect(selection.selected == [3, 4, 5])
    #expect(selection.anchor == 3)

    // The surviving anchor still resizes the range, which is the whole point of
    // keeping it.
    selection.click(4, in: [3, 4, 5], shift: true, command: false)
    #expect(selection.selected == [3, 4])
}

/// A dropped anchor is not neutral: it silently collapses the next shift-click.
///
/// Measured on the version that set it to nil — click 2, shift-click 5,
/// `retain([3, 4, 5, 6])`, shift-click 6 left `[6]`, three rows gone without a
/// gesture that asked for them to go. `click` cannot resolve an anchor that is
/// not in `order`, so a nil anchor and a dangling one behave identically and
/// both degrade to a plain click. Re-anchoring to the topmost surviving
/// selected row keeps the surviving range extendable, which is what the user
/// still sees.
@Test func retainReAnchorsToTheTopmostSurvivorWhenTheAnchorRowIsGone() {
    var selection = SelectionModel()
    selection.click(2, in: order, shift: false, command: false)
    selection.click(5, in: order, shift: true, command: false)
    #expect(selection.anchor == 2)

    selection.retain([4, 5, 6])
    #expect(selection.selected == [4, 5])
    #expect(selection.anchor == 4, "row 2 is gone; the range now starts at its topmost survivor")
}

@Test func retainKeepsTheSurvivingRangeExtendable() {
    var selection = SelectionModel()
    selection.click(2, in: order, shift: false, command: false)
    selection.click(5, in: order, shift: true, command: false)
    #expect(selection.selected == [2, 3, 4, 5])

    let living: [Int64] = [3, 4, 5, 6]
    selection.retain(living)
    #expect(selection.selected == [3, 4, 5])

    // The regression: this used to leave `[6]`.
    selection.click(6, in: living, shift: true, command: false)
    #expect(selection.selected == [3, 4, 5, 6],
            "a shift-click after retain must extend the surviving range, not replace it")
}

@Test func retainOfANonEmptySelectionWhoseAnchorSurvivesNothingLeavesNoAnchor() {
    var selection = SelectionModel()
    selection.click(2, in: order, shift: false, command: false)
    selection.click(4, in: order, shift: true, command: false)
    selection.retain([5, 6])
    #expect(selection.selected.isEmpty)
    #expect(selection.anchor == nil, "nothing survived, so there is no range to extend")
}

@Test func retainingNothingClearsEverything() {
    var selection = SelectionModel()
    selection.selectAll(order)
    selection.retain([])
    #expect(selection.selected.isEmpty)
    #expect(selection.anchor == nil)
}

@Test func retainingASupersetChangesNothing() {
    var selection = SelectionModel()
    selection.click(2, in: order, shift: false, command: false)
    selection.click(4, in: order, shift: false, command: true)
    let before = selection

    selection.retain(order + [7, 8])
    #expect(selection == before,
            "a record set that only grew must not disturb the selection or the anchor")
}

/// Re-anchoring picks the topmost surviving *row*, which is not the lowest
/// surviving *id*.
///
/// `SearchQuery.Sort` defaults to name-ascending, so display order is
/// essentially never id order, and every other test in this file uses
/// `[1, 2, 3, 4, 5, 6]` where the two coincide and the bug is invisible. Under
/// a descending order the old `selected.min()` anchored on the *bottom* of the
/// surviving range, and the next shift-click threw away everything above it —
/// the identical two-rows-lost-without-a-gesture failure the re-anchoring was
/// written to eliminate, just relocated behind a non-identity sort.
@Test func retainReAnchorsInDisplayOrderAndNotIdOrder() {
    let descending: [Int64] = [50, 40, 30, 20, 10]
    var selection = SelectionModel()
    selection.click(50, in: descending, shift: false, command: false)
    selection.click(20, in: descending, shift: true, command: false)
    #expect(selection.selected == [50, 40, 30, 20])
    #expect(selection.anchor == 50)

    let living: [Int64] = [40, 30, 20, 10]
    selection.retain(living)
    #expect(selection.selected == [40, 30, 20])
    #expect(selection.anchor == 40,
            "row 50 is gone; the range restarts at 40, the topmost survivor, not 20, the lowest id")

    // The point of re-anchoring: the surviving range still extends rather than
    // collapsing. `selected.min()` gave `[20, 10]` here.
    selection.click(10, in: living, shift: true, command: false)
    #expect(selection.selected == [40, 30, 20, 10])
}

/// A survivor that is neither the lowest id nor the first row of `living`:
/// re-anchoring skips living rows that were never selected.
@Test func retainReAnchorsToTheFirstLivingRowThatIsActuallySelected() {
    let mixed: [Int64] = [7, 3, 9, 1, 5]
    var selection = SelectionModel()
    selection.click(3, in: mixed, shift: false, command: false)
    selection.click(1, in: mixed, shift: true, command: false)
    #expect(selection.selected == [3, 9, 1])

    // 7 survives on screen but was never selected, so it must not become the
    // anchor; 1 is the lowest surviving id and is the *bottom* of the range.
    let living: [Int64] = [7, 9, 1, 5]
    selection.retain(living)
    #expect(selection.selected == [9, 1])
    #expect(selection.anchor == 9)
}

/// The property that makes `retain` the right primitive: it is a set
/// intersection, so the result cannot depend on the order ids come out of a
/// `Set` in, and it never moves the anchor of a selection that survived.
///
/// Rebuilding the selection by replaying `click(command: true)` over a `Set`
/// has neither property — the replay leaves the anchor on whichever id the set
/// happened to yield last.
///
/// `living` is deliberately *not* shuffled: it is display order now, and its
/// order is meaningful. What varies instead is the click history that builds
/// `selected`, so the `Set` being intersected is assembled by a different
/// sequence of insertions on every iteration.
@Test func retainIsIndependentOfIterationOrder() {
    var expected = SelectionModel()
    expected.click(2, in: order, shift: false, command: false)
    expected.click(5, in: order, shift: true, command: false)
    expected.retain([2, 3, 4, 5])
    #expect(expected.selected == [2, 3, 4, 5])

    for _ in 0..<50 {
        var selection = SelectionModel()
        selection.click(2, in: order, shift: false, command: false)
        selection.click(5, in: order, shift: true, command: false)
        selection.retain([2, 3, 4, 5])
        #expect(selection == expected)
        #expect(selection.anchor == 2)

        // The same `selected` reached by a different insertion history must
        // prune to the same thing.
        var built = SelectionModel()
        built.click(1, in: order, shift: false, command: false)
        for id in ([2, 3, 4, 5, 6] as [Int64]).shuffled() {
            built.click(id, in: order, shift: false, command: true)
        }
        built.retain([2, 3, 4, 5])
        #expect(built.selected == [2, 3, 4, 5])
    }
}
