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

    /// The price of `replacing: .pasteboard` is that Cut, Copy, Paste and
    /// Delete go with the group; Task 19 pays it back by hand.
    ///
    /// This test used to assert the opposite — that the four were gone —
    /// which was the right call while the app had no text-entry surface for
    /// them to act on. Task 19 adds the search field, so the assertion is
    /// inverted rather than deleted: a text field shipping without ⌘X/⌘C/⌘V
    /// is exactly the regression the original was written to catch.
    @Test func thePasteboardItemsAreRebuiltAlongsideSelectAll() throws {
        let edit = try #require(editMenu(), "the app's main menu was never installed")
        let titles = edit.items.map(\.title)
        for expected in ["Cut", "Copy", "Paste", "Delete"] {
            #expect(titles.contains(expected),
                    "\(expected) is missing; Edit holds \(titles)")
            #expect(titles.filter { $0 == expected }.count == 1,
                    "\(expected) appears more than once, so two items share one shortcut")
        }
    }

    /// Each rebuilt item carries the shortcut its stock counterpart had, and
    /// an action that can actually reach a text field.
    ///
    /// The shortcut and the action are asserted together for the same reason
    /// `selectAllCarriesBothItsActionAndItsShortcut` does: an item with one
    /// and not the other is the broken state, and it looks fine in a
    /// screenshot.
    ///
    /// Delete deliberately has no key equivalent — see `LightboxApp`. A bare
    /// ⌫ in the menu bar is matched before the focused view sees the event,
    /// so it would break backspace in the search field.
    @Test func theRebuiltPasteboardItemsCarryTheirShortcuts() throws {
        let edit = try #require(editMenu(), "the app's main menu was never installed")
        let expected: [String: String] = ["Cut": "x", "Copy": "c", "Paste": "v", "Delete": ""]
        for (title, key) in expected {
            let item = try #require(edit.items.first { $0.title == title },
                                    "\(title) is missing from the Edit menu")
            #expect(item.keyEquivalent == key,
                    "\(title) has key equivalent '\(item.keyEquivalent)', expected '\(key)'")
            #expect(item.keyEquivalentModifierMask == (key.isEmpty ? [] : .command))
            #expect(item.action != nil,
                    "\(title) has no action, so the menu item does nothing when chosen")
        }
    }

    /// The selectors the menu forwards are the ones text editing answers.
    ///
    /// Scoped precisely, because the earlier name for this test claimed more
    /// than it does: it drives the field editor *directly* and so never
    /// touches `LightboxApp.forwardToResponder`. What it does establish is
    /// that `cut:`, `copy:` and `paste:` — built from string literals, so a
    /// typo would compile fine and fail silently — name real text-editing
    /// actions and round-trip through the real pasteboard. Whether
    /// `performKeyEquivalent` delivers ⌘C to a focused field needs a live
    /// event and a key window, which `xcodebuild test` does not provide; that
    /// is on the human checklist in the Task 19 report.
    @Test func theForwardedSelectorsAreTheOnesTextEditingImplements() throws {
        let field = NSTextField(string: "beach")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView,
                                  "the field never became first responder")

        // Round-trips through the real pasteboard, so this fails if the
        // selectors the menu forwards are not the ones text editing answers.
        editor.selectAll(nil)
        NSPasteboard.general.clearContents()
        editor.perform(Selector(("copy:")), with: nil)
        #expect(NSPasteboard.general.string(forType: .string) == "beach")

        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.perform(Selector(("paste:")), with: nil)
        #expect(field.stringValue == "beachbeach")

        editor.selectAll(nil)
        editor.perform(Selector(("cut:")), with: nil)
        #expect(field.stringValue.isEmpty)
        #expect(NSPasteboard.general.string(forType: .string) == "beachbeach")
    }
}

/// Raised by a notification observer. A class, not a captured `var`: the
/// observer block is `@Sendable`, and `queue: nil` delivers it synchronously
/// on the posting thread, so the read after the post is ordered.
private final class Flag: @unchecked Sendable {
    var raised = false
}

extension MenuCommandTests {
    private func observingSelectAllPhotos(_ body: () -> Void) -> Bool {
        let flag = Flag()
        let token = NotificationCenter.default.addObserver(
            forName: .selectAllPhotos, object: nil, queue: nil) { _ in flag.raised = true }
        defer { NotificationCenter.default.removeObserver(token) }
        body()
        return flag.raised
    }

    /// A window whose text field is really the first responder of a really key
    /// window, or nil if this environment will not give the test process one.
    ///
    /// Returned rather than asserted, because whether a window can become key
    /// depends on whether the app is active, and an inactive test host is an
    /// environment fact rather than a defect in the code under test. The
    /// caller decides what to do about it.
    private func keyWindowEditingText() -> (NSWindow, NSTextView)? {
        let field = NSTextField(string: "beach")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(field)
        NSApp?.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, NSApp?.keyWindow !== window {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard NSApp?.keyWindow === window else {
            window.orderOut(nil)
            return nil
        }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else {
            window.orderOut(nil)
            return nil
        }
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        return (window, editor)
    }

    /// The Task 17 guarantee, restated: with nothing editing text, ⌘A still
    /// means "select every photo".
    ///
    /// The half of the new routing that is deterministic here — the test host
    /// has no key window unless one is made — and the half that would break
    /// silently if `forwardToResponder` ever started returning true for
    /// everything.
    @Test func selectAllReachesTheGridWhenNothingIsEditingText() {
        #expect(LightboxApp.forwardToResponder("selectAll:") == false,
                "something in the responder chain answered selectAll: with nothing focused")
        #expect(observingSelectAllPhotos { LightboxApp.selectAll() },
                "⌘A no longer selects the photos")
    }

    /// ⌘A must reach the search field when the search field is focused.
    ///
    /// The mirror image of the regression Task 17 fixed. Task 17 posted
    /// `selectAllPhotos` unconditionally, which was right while nothing else
    /// could want ⌘A; with a text field in the toolbar, measurement showed
    /// `performKeyEquivalent` returning true and the photos being selected
    /// while the user was typing, leaving the field's own Select All
    /// unreachable.
    ///
    /// Needs a genuinely key window, which needs an active app. When the test
    /// host is not active the assertion is unprovable rather than false, so
    /// this records the gap instead of failing on it — a flaky red test would
    /// teach the next reader to ignore it. `selectAllReachesTheGridWhenNothing
    /// IsEditingText` still pins the other direction unconditionally, and the
    /// Task 19 report puts this on the human checklist either way.
    @Test func selectAllPrefersAFocusedTextFieldOverTheGrid() throws {
        guard let (window, editor) = keyWindowEditingText() else {
            Issue.record("""
                could not make a key window in this test host, so ⌘A's routing \
                to a focused text field is unverified here — check it by hand
                """, severity: .warning)
            return
        }
        defer { window.orderOut(nil) }

        let selectedPhotos = observingSelectAllPhotos { LightboxApp.selectAll() }

        #expect(!selectedPhotos,
                "⌘A selected the photos while a text field was being edited")
        #expect(editor.selectedRange().length == editor.string.count,
                "the field's text was not selected, so ⌘A did nothing at all")
    }
}
