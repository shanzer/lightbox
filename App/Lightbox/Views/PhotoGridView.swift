import SwiftUI
import LightboxCore

/// The thumbnail grid.
///
/// Deliberately a thin, self-contained view over `records` plus a selection
/// binding: Task 18 measures this at 50,000 items, and if `LazyVGrid` does not
/// hold up, only this file is replaced by an `NSCollectionView` bridge. Nothing
/// about *what* a click means lives here — that is `SelectionModel`, in `Core`,
/// precisely so it survives that swap untouched.
///
/// `order` is passed in rather than derived from `records` because the click
/// handlers and every body evaluation need it, and deriving it here would be a
/// pass over all 50,000 records each time. `BrowserModel` computes it once,
/// where `records` is assigned.
struct PhotoGridView: View {
    let records: [FileRecord]
    let order: [Int64]
    let cache: ThumbnailCache
    @Binding var selection: SelectionModel
    let thumbnailSide: CGFloat

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbnailSide + 16), spacing: 12)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(records, id: \.id) { record in
                    ThumbnailCell(record: record, side: thumbnailSide,
                                  isSelected: record.id.map { selection.selected.contains($0) } ?? false,
                                  cache: cache)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard let id = record.id else { return }
                            // `TapGesture` reports no modifiers, so the flags
                            // are read from the event being dispatched.
                            let flags = NSEvent.modifierFlags
                            selection.click(id, in: order,
                                            shift: flags.contains(.shift),
                                            command: flags.contains(.command))
                        }
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Behind the cells, so a tap that misses every tile — the one place a
        // Finder window deselects — clears rather than doing nothing.
        .onTapGesture { selection.clear() }
        .focusable()
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        // No ⌘A here. A key equivalent is claimed by the menu bar before the
        // focused view is offered the event, so a view-level handler for it is
        // dead code that reads like coverage. Select All is a menu command in
        // `LightboxApp`, which also makes it discoverable.
    }

    /// Moves the selection one cell along the display order.
    ///
    /// Left and right only. Up and down would have to move by a whole row, and
    /// `LazyVGrid(.adaptive)` decides its column count internally and does not
    /// report it — the grid would have to guess from its own width and the
    /// guess would be wrong at every breakpoint. Task 18's `NSCollectionView`
    /// bridge knows its layout and can answer properly; wiring up a wrong
    /// answer here first would be worse than not wiring one up.
    private func move(_ offset: Int) -> KeyPress.Result {
        // `BrowserModel` prunes the selection whenever the records change, so
        // the anchor is either on screen or absent; the fallback is for the
        // first keypress in a window where nothing has been clicked yet.
        guard let from = selection.anchor ?? order.first,
              let next = selection.neighbour(of: from, in: order, offset: offset)
        else { return .ignored }
        selection.click(next, in: order, shift: false, command: false)
        return .handled
    }
}
