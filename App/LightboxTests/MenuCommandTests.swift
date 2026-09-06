import Testing
import AppKit
@testable import Lightbox

/// The only automated check on ⌘A's *routing*, as opposed to on what
/// `selectAll()` does once something calls it.
///
/// `PhotoGridTests` calls `BrowserModel.selectAll()` directly and so passes
/// whether or not the menu item is reachable — which is exactly how the shipped
/// ⌘A stayed dead through a review. These tests run in the app's own process
/// (the target is hosted by `Lightbox.app`), so `NSApp.mainMenu` here is the
/// menu SwiftUI actually built from `LightboxApp.commands`, not a reconstruction.
///
/// What they cannot cover: whether pressing ⌘A on a real keyboard reaches the
/// item. `performKeyEquivalent` needs a live event and a key window, and there
/// is no key window under `xcodebuild test`. Asserting on the item's title,
/// action, target and key equivalent covers everything AppKit consults when it
/// matches a key equivalent, which is as close as this gets without a human.
@MainActor
struct MenuCommandTests {
    /// SwiftUI builds the main menu during launch; the test bundle is injected
    /// after that, but not synchronously enough to rely on. Spins the run loop
    /// briefly rather than sleeping, and returns nil if it never appears so the
    /// failure names the real problem instead of trapping on a force unwrap.
    private func editMenu() -> NSMenu? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let edit = NSApp?.mainMenu?.items
                .compactMap(\.submenu)
                .first(where: { menu in
                    menu.items.contains { $0.action == #selector(NSText.copy(_:)) }
                        || menu.title == "Edit"
                }) {
                return edit
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    private func selectAllItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { $0.title == "Select All" }
    }

    /// One item, not two.
    ///
    /// `CommandGroup(replacing: .textEditing)` left the stock Select All in
    /// place — it lives in `.pasteboard` — so the Edit menu carried two
    /// identically titled entries and AppKit resolved the shortcut collision by
    /// stripping the key equivalent off the custom one.
    @Test func theEditMenuHasExactlyOneSelectAll() throws {
        let edit = try #require(editMenu(), "the app's main menu was never installed")
        let items = selectAllItems(in: edit)
        #expect(items.count == 1,
                "found \(items.count) Select All items: \(items.map(\.title))")
    }

    /// The surviving item carries both the action and ⌘A.
    ///
    /// Splitting these would be worse than useless: an item with the shortcut
    /// and no action, or an action and no shortcut, is precisely the broken
    /// state that shipped.
    @Test func selectAllCarriesBothItsActionAndItsShortcut() throws {
        let edit = try #require(editMenu(), "the app's main menu was never installed")
        let item = try #require(selectAllItems(in: edit).first, "no Select All in the Edit menu")

        #expect(item.keyEquivalent == "a")
        #expect(item.keyEquivalentModifierMask == .command)
        #expect(item.action != nil, "an item with no action cannot do anything when ⌘A fires")
        #expect(item.action != #selector(NSResponder.selectAll(_:)),
                "the stock responder-chain action: nothing in this app implements it")
        #expect(item.target != nil,
                "SwiftUI's callback target; a nil target sends the action down the responder chain")
    }

    /// The failure mode itself, asserted directly: nothing in the Edit menu may
    /// be wired to the stock responder-chain `selectAll:`.
    ///
    /// Measured under `replacing: .textEditing` — the stock item survived with
    /// `key='a' action=selectAll: target=nil` while the custom one came out
    /// `key='' action=menuAction:`, so ⌘A went down the responder chain to a
    /// selector this app does not implement and the custom item was reachable
    /// by mouse only. That is one assertion away from `theEditMenuHasExactlyOne
    /// SelectAll`, and worth having separately: a future group change could
    /// reintroduce the stock item under a different title and only this catches
    /// it.
    @Test func nothingInTheEditMenuRoutesToTheStockSelectAll() throws {
        let edit = try #require(editMenu(), "the app's main menu was never installed")
        let stock = edit.items.filter { $0.action == #selector(NSResponder.selectAll(_:)) }
        #expect(stock.isEmpty,
                "\(stock.count) item(s) still send selectAll: down the responder chain")
    }

    /// The replacement has to be scoped to the pasteboard group and not a wipe
    /// of the Edit menu.
    ///
    /// Undo, Redo and the input items come from other groups; if they vanish,
    /// something replaced more than it meant to.
    @Test func replacingThePasteboardGroupLeavesTheRestOfTheEditMenuAlone() throws {
        let edit = try #require(editMenu(), "the app's main menu was never installed")
        let titles = Set(edit.items.map(\.title))
        for expected in ["Undo", "Redo", "Emoji & Symbols"] {
            #expect(titles.contains(expected),
                    "the stock \(expected) item is gone; Edit now holds \(titles.sorted())")
        }
    }

    /// The cost of `replacing: .pasteboard`, pinned so it is a decision and not
    /// a surprise: Cut, Copy, Paste and Delete go with it.
    ///
    /// Acceptable today because the app has no text-entry surface for them to
    /// act on. The moment one is added — a rename field, a search box — this
    /// test fails and forces the question to be re-answered rather than letting
    /// a text field ship without ⌘X/⌘C/⌘V.
    @Test func replacingThePasteboardGroupAlsoDropsCutCopyAndPaste() throws {
        let edit = try #require(editMenu(), "the app's main menu was never installed")
        let titles = Set(edit.items.map(\.title))
        #expect(titles.isDisjoint(with: ["Cut", "Copy", "Paste", "Delete"]),
                "the pasteboard items are back, so the group is no longer being replaced")
    }
}
