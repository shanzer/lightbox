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

@Test func selectAllAndClear() {
    var selection = SelectionModel()
    selection.selectAll(order)
    #expect(selection.selected.count == 6)
    selection.clear()
    #expect(selection.selected.isEmpty)
    #expect(selection.anchor == nil)
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

@Test func retainDropsAnAnchorWhoseRowIsGone() {
    var selection = SelectionModel()
    selection.click(2, in: order, shift: false, command: false)
    selection.click(5, in: order, shift: true, command: false)
    #expect(selection.anchor == 2)

    selection.retain([4, 5, 6])
    #expect(selection.selected == [4, 5])
    #expect(selection.anchor == nil, "row 2 is gone; nothing may extend from it")
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

    selection.retain(Set(order).union([7, 8]))
    #expect(selection == before,
            "a record set that only grew must not disturb the selection or the anchor")
}

/// The property that makes `retain` the right primitive: it is a set
/// intersection, so the result cannot depend on the order ids come out of a
/// `Set` in, and it never moves the anchor of a selection that survived.
///
/// Rebuilding the selection by replaying `click(command: true)` over a `Set`
/// has neither property — the replay leaves the anchor on whichever id the set
/// happened to yield last.
@Test func retainIsIndependentOfIterationOrder() {
    var expected = SelectionModel()
    expected.click(2, in: order, shift: false, command: false)
    expected.click(5, in: order, shift: true, command: false)
    expected.retain([2, 3, 4, 5])

    for _ in 0..<50 {
        var selection = SelectionModel()
        selection.click(2, in: order, shift: false, command: false)
        selection.click(5, in: order, shift: true, command: false)
        selection.retain(Set([2, 3, 4, 5].shuffled()))
        #expect(selection == expected)
        #expect(selection.anchor == 2)
    }
}
