import Testing
import AppKit
import SwiftUI
import LightboxCore
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

    /// The replacement has to be scoped to the groups that were replaced and
    /// not a wipe of the Edit menu.
    ///
    /// The input items come from a group nothing here touches; if they vanish,
    /// something replaced more than it meant to. Undo is checked too, but it is
    /// now *this app's* item rather than the stock one — see `UndoMenuTests`.
    ///
    /// **Redo is deliberately absent.** #7 replaces `.undoRedo` whole to place
    /// ⌘Z, and does not put a Redo back: undoing an undo *is* the redo (the
    /// reversal is journalled as an ordinary batch, so `Core` needs no history
    /// state for it), and the one item's title says which of the two the next
    /// ⌘Z will do. A Redo item would need ⌘⇧Z wired to the same call and would
    /// be enabled in exactly the cases the Undo item already covers.
    @Test func replacingTheStockGroupsLeavesTheRestOfTheEditMenuAlone() throws {
        let edit = try #require(editMenu(), "the app's main menu was never installed")
        let titles = Set(edit.items.map(\.title))
        for expected in ["Undo", "Emoji & Symbols"] {
            #expect(titles.contains(expected),
                    "the \(expected) item is gone; Edit now holds \(titles.sorted())")
        }
        #expect(!titles.contains("Redo"),
                "a Redo item is back; undo-of-undo is the redo and the title says so")
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
        // Before the caller's `close()` — see `renderFields`. A window created
        // this way is released when closed, so closing one ARC also owns
        // over-releases it and takes the whole test process down.
        window.isReleasedWhenClosed = false
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
        defer { window.close() }

        let selectedPhotos = observingSelectAllPhotos { LightboxApp.selectAll() }

        #expect(!selectedPhotos,
                "⌘A selected the photos while a text field was being edited")
        #expect(editor.selectedRange().length == editor.string.count,
                "the field's text was not selected, so ⌘A did nothing at all")
    }
}

/// The phase 2 file-operation commands.
///
/// Two halves, and both are needed for the same reason ⌘A needed both: an item
/// that exists but is unreachable, and a rule that is right but wired to
/// nothing, look identical from either side alone.
///
/// - The menu really carries an item per command, with the shortcut the issue
///   asks for and no second item claiming it. `NSApp.mainMenu` here is what
///   SwiftUI built from `LightboxApp.commands`, not a reconstruction.
/// - The enabled-state rule tracks the selection. That half cannot be asserted
///   through `NSMenuItem.isEnabled`: the items are disabled by a
///   `@FocusedValue` that resolves to the key window's `BrowserModel`, and the
///   test host renders the inert scene and builds no model at all — so every
///   one of them is correctly, and uninterestingly, disabled here. The rule is
///   therefore asserted where it lives, on `BrowserModel`, and the menu is
///   asserted to be built from the same `FileCommand` cases the rule is keyed
///   on. `FileOperationBatchTests` covers the selection side end to end.
@MainActor
struct FileOperationMenuTests {
    private func fileMenu() -> NSMenu? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let file = NSApp?.mainMenu?.items
                .compactMap(\.submenu)
                .first(where: { menu in
                    menu.items.contains { $0.title == FileCommand.moveTo.title }
                }) {
                return file
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    @Test func everyFileCommandHasExactlyOneMenuItem() throws {
        let menu = try #require(fileMenu(), "no menu carries the file-operation commands")
        let titles = menu.items.map(\.title)
        for command in FileCommand.allCases {
            let found = titles.filter { $0 == command.title }.count
            #expect(found == 1,
                    "\(command.title) appears \(found) times; the menu holds \(titles)")
        }
    }

    /// ⌘⌫ on Move to Trash, nothing on the other three.
    ///
    /// Move To…, Copy To… and Delete Permanently… deliberately have no key
    /// equivalent: each one opens a panel or a sheet, none of them is a gesture
    /// worth a chord, and a shortcut on Delete Permanently is a way to lose
    /// photos by mistyping. ⌘⌫ is the one the issue asks for, and it collides
    /// with nothing else in the menu bar — asserted rather than assumed,
    /// because that is precisely how ⌘A came to be dead.
    @Test func moveToTrashCarriesCommandDeleteAndNothingElseClaimsIt() throws {
        let menu = try #require(fileMenu(), "no menu carries the file-operation commands")
        let trash = try #require(menu.items.first { $0.title == FileCommand.trash.title })
        #expect(trash.keyEquivalent == "\u{8}", "⌘⌫ is a backspace key equivalent")
        #expect(trash.keyEquivalentModifierMask == .command)

        for command in [FileCommand.moveTo, .copyTo, .deletePermanently] {
            let item = try #require(menu.items.first { $0.title == command.title })
            #expect(item.keyEquivalent.isEmpty,
                    "\(command.title) claims '\(item.keyEquivalent)'")
        }

        let claimants = (NSApp?.mainMenu?.items.compactMap(\.submenu) ?? [])
            .flatMap(\.items)
            .filter { $0.keyEquivalent == "\u{8}" && $0.keyEquivalentModifierMask == .command }
        #expect(claimants.count == 1,
                "\(claimants.count) items claim ⌘⌫: \(claimants.map(\.title))")
    }

    /// The `.disabled` really reaches AppKit.
    ///
    /// Measured, not assumed: SwiftUI drops the `action` off a disabled
    /// `CommandGroup` item entirely, so `action == nil` here *is* the disabled
    /// state — which is why the first assertion is not redundant. Open Folder…
    /// sits in the same group, is never disabled, and keeps its action; if the
    /// file commands lost theirs for some reason other than being disabled,
    /// that one would have lost its too.
    ///
    /// The test host builds no `BrowserModel` at all (`LaunchEnvironment`, #15),
    /// so `@FocusedValue(\.browserModel)` resolves to nil and every file command
    /// is correctly off. The selection side of the same rule — off with an empty
    /// selection, on with one — is `FileOperationBatchTests`, against a real
    /// model.
    @Test func theFileCommandsAreOffWhenThereIsNoBrowserWindow() throws {
        let menu = try #require(fileMenu(), "no menu carries the file-operation commands")
        let open = try #require(menu.items.first { $0.title == "Open Folder…" },
                                "Open Folder… is not in this menu, so the control is worthless")
        #expect(open.action != nil,
                "even the always-enabled command lost its action; this menu proves nothing")

        for command in FileCommand.allCases {
            let item = try #require(menu.items.first { $0.title == command.title })
            #expect(item.action == nil,
                    "\(command.title) is live with no window to act in")
        }
    }
}

/// ⌘Z.
///
/// Its own suite because it replaces a *different* stock group — `.undoRedo`,
/// not `.pasteboard` — and because the responder-chain half of it has nothing
/// to do with the file commands.
@MainActor
struct UndoMenuTests {
    /// The Edit menu, found the way `MenuCommandTests` finds it: SwiftUI builds
    /// the main menu during launch and the test bundle is injected after that,
    /// so the run loop is spun rather than slept on.
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

    /// ⌘Z, and the lesson from ⌘A applied to it.
    ///
    /// `CommandGroup(replacing: .undoRedo)` rather than an addition, for exactly
    /// the reason `.pasteboard` was replaced: SwiftUI's stock Undo already
    /// carries ⌘Z, and two items sharing one key equivalent is resolved by
    /// AppKit stripping it off the *custom* one — which is how ⌘A shipped
    /// mouse-only. So the assertion that matters is that the shortcut is on
    /// **our** item, the one with an action, and that no second item claims it.
    @Test func theEditMenuHasOneUndoAndItCarriesCommandZ() throws {
        let edit = try #require(editMenu(), "the app's main menu was never installed")
        let undos = edit.items.filter { $0.title.hasPrefix("Undo") || $0.title.hasPrefix("Redo") }
        #expect(undos.count == 1,
                "found \(undos.count) undo items: \(undos.map(\.title))")
        let item = try #require(undos.first)
        #expect(item.keyEquivalent == "z")
        #expect(item.keyEquivalentModifierMask == .command)

        let claimants = (NSApp?.mainMenu?.items.compactMap(\.submenu) ?? [])
            .flatMap(\.items)
            .filter { $0.keyEquivalent == "z" && $0.keyEquivalentModifierMask == .command }
        #expect(claimants.count == 1,
                "\(claimants.count) items claim ⌘Z: \(claimants.map(\.title))")
    }

    /// With nothing to undo the item is off, and it says plain "Undo".
    ///
    /// The test host builds no `BrowserModel`, so `@FocusedValue(\.browserModel)`
    /// is nil: nothing to reverse, nothing being edited, and the decision is
    /// `.nowhere`. SwiftUI strips the `action` off a disabled `CommandGroup`
    /// item, which is what makes the off state assertable at all — the same
    /// lever `theFileCommandsAreOffWhenThereIsNoBrowserWindow` uses.
    @Test func undoIsOffAndUntitledWithNothingToUndo() throws {
        let edit = try #require(editMenu(), "the app's main menu was never installed")
        let item = try #require(edit.items.first { $0.title.hasPrefix("Undo") })
        #expect(item.title == "Undo",
                "with no batch the item must read plain Undo, not \(item.title)")
        #expect(item.action == nil, "⌘Z is live with nothing to undo and no text being edited")
    }

    /// **`undo:` cannot be used to detect text editing.**
    ///
    /// `NSWindow` implements it, so asking the responder chain answers
    /// "handled" whenever any window is key, whatever is focused, and the first
    /// version of this command swallowed every ⌘Z. `selectAll:` and `copy:`
    /// have no window-level implementation, which is why the ⌘A pattern works
    /// and this one had to be different. The measurement is in `HANDOFF` §8.
    ///
    /// A later finding moved the decision again, off `NSApp` and onto state the
    /// views publish, so nothing here needs a key window any more — which is
    /// the point. `UndoRoutingTests` drives the decision.
    ///
    /// What is left to assert in this suite is the default the disabled state
    /// depends on: a window that has never reported focus is not editing text.
    @Test func aFreshWindowIsNotEditingText() throws {
        let store = try IndexStore.inMemory()
        let model = BrowserModel(store: store, preferences: MemoryPreferences())
        #expect(!model.isEditingText)
        #expect(model.editingFields.isEmpty)
    }
}

/// Where ⌘Z goes, as a pure decision.
///
/// Split out from the `NSApp` probing so it can be asserted in both directions
/// without a key window — which `xcodebuild test` will not give this host, and
/// which is why the shipping path went untested through a whole review cycle.
@MainActor
struct UndoRoutingTests {
    @Test func withNothingBeingEditedUndoGoesToTheModel() {
        #expect(UndoCommandAction.destination(isEditingText: false, canUndo: true) == .model)
    }

    /// A field being edited wins **even when the grid also has a batch to
    /// reverse**. That is the whole point of the decision: ⌘Z belongs to the
    /// thing being typed in.
    @Test func aFieldBeingEditedWinsOverTheGrid() {
        #expect(UndoCommandAction.destination(isEditingText: true, canUndo: true)
            == .textEditing)
    }

    @Test func nothingToUndoAnywhereGoesNowhere() {
        #expect(UndoCommandAction.destination(isEditingText: false, canUndo: false)
            == .nowhere)
    }

    /// **The menu reads the decision off the model, not off `NSApp`.**
    ///
    /// This is the assertion the earlier design could not make. `.disabled` was
    /// computed from an `NSApp.keyWindow?.firstResponder` read, which is not
    /// observable state: SwiftUI never re-evaluated the command body when focus
    /// moved into a text field, so the item stayed disabled from launch and ⌘Z
    /// in the search field did nothing — the exact harm the routing exists to
    /// prevent, moved out of the action and into the enabled state.
    ///
    /// `destination(for:)` reads `BrowserModel.isEditingText`, which is
    /// `@Observable`, so focusing a field invalidates the body. Flipping the
    /// flag here is flipping precisely what the views write.
    @Test func focusingAFieldChangesTheMenuDecisionWithoutAKeyWindow() throws {
        let store = try IndexStore.inMemory()
        let model = BrowserModel(store: store, preferences: MemoryPreferences())

        #expect(UndoCommandAction.destination(for: model) == .nowhere)

        model.setEditing(.search, true)
        #expect(UndoCommandAction.destination(for: model) == .textEditing,
                "focusing the search field did not reach the menu's enabled state")

        model.setEditing(.search, false)
        model.lastCompletedBatch = CompletedBatch(batchID: "b", kind: .move,
                                                  results: [], isReversal: false)
        #expect(UndoCommandAction.destination(for: model) == .model)

        // And text still wins over a batch.
        model.setEditing(.exactWidth, true)
        #expect(UndoCommandAction.destination(for: model) == .textEditing)
    }

    /// **The title has to agree with the routing.**
    ///
    /// `undoMenuTitle` describes the last batch and knows nothing about focus,
    /// so a window with a batch behind it and the search field focused offered
    /// "Undo Move 3 Items" while ⌘Z undid typing. The menu was lying about what
    /// the next press would do — the one claim the whole single-item, no-Redo
    /// design rests on.
    ///
    /// Only the `.model` branch may name a batch.
    @Test func onlyTheModelBranchNamesTheBatch() {
        let batch = "Undo Move 3 Items"
        #expect(UndoCommandAction.title(for: .model, undoTitle: batch) == batch)
        #expect(UndoCommandAction.title(for: .textEditing, undoTitle: batch) == "Undo",
                "the menu names a batch it is not about to reverse")
        #expect(UndoCommandAction.title(for: .nowhere, undoTitle: batch) == "Undo")
        // And a redo still names itself when it really is the next press.
        #expect(UndoCommandAction.title(for: .model, undoTitle: "Redo Copy 2 Items")
            == "Redo Copy 2 Items")
    }

    /// Focus moving from one field to another must never read as "not editing".
    ///
    /// SwiftUI does not promise that the blur arrives before the focus, so a
    /// single `Bool` written by both fields can be cleared by the field that
    /// just lost focus *after* the field that gained it set it — a one-frame
    /// window in which ⌘Z would be routed to the grid while the user is typing.
    /// A set keyed by field cannot express that: each field only ever reports
    /// about itself.
    @Test func focusMovingBetweenFieldsNeverReadsAsNotEditing() throws {
        let store = try IndexStore.inMemory()
        let model = BrowserModel(store: store, preferences: MemoryPreferences())

        model.setEditing(.exactWidth, true)
        #expect(model.isEditingText)

        // The out-of-order pair: the new field gains focus, then the old one
        // reports its blur.
        model.setEditing(.exactHeight, true)
        model.setEditing(.exactWidth, false)
        #expect(model.isEditingText, "the blur of the previous field cleared the new one")

        model.setEditing(.exactHeight, false)
        #expect(!model.isEditingText)
    }

    /// While text is being edited the responder is asked and the model is not
    /// touched — asserted by observing both, because "went to the field" and
    /// "did not start an undo" are two claims and only one of them is about
    /// where the action went.
    @Test func theTextEditingBranchAsksTheResponderAndLeavesTheModelAlone() throws {
        let store = try IndexStore.inMemory()
        let model = BrowserModel(store: store, preferences: MemoryPreferences())
        model.lastCompletedBatch = CompletedBatch(batchID: "b", kind: .move,
                                                  results: [], isReversal: false)
        #expect(model.canUndo)

        let asked = Asked()
        let outcome = UndoCommandAction.run(isEditingText: true, model: model) { selector in
            asked.selectors.append(selector)
            return true
        }

        #expect(outcome.destination == .textEditing)
        #expect(asked.selectors == ["undo:"])
        #expect(outcome.work == nil, "an undo was started while a field was being edited")
        #expect(model.lastCompletedBatch?.batchID == "b", "the model was reversed anyway")
    }

    /// And with nothing being edited the responder is **not** asked — the
    /// mirror assertion, without which the branch could forward every time and
    /// still pass the one above.
    @Test func theModelBranchDoesNotAskTheResponder() async throws {
        let store = try IndexStore.inMemory()
        let model = BrowserModel(store: store, preferences: MemoryPreferences())
        model.lastCompletedBatch = CompletedBatch(batchID: "b", kind: .move,
                                                  results: [], isReversal: false)

        let asked = Asked()
        let outcome = UndoCommandAction.run(isEditingText: false, model: model) { selector in
            asked.selectors.append(selector)
            return true
        }
        #expect(outcome.destination == .model)
        #expect(asked.selectors.isEmpty, "the model branch forwarded to the responder chain")
        await outcome.work?.value
    }
}

/// A box for what the injected forwarder was asked. A class because the closure
/// escapes into `run`, which is `@MainActor` like the test.
@MainActor
final class Asked {
    var selectors: [String] = []
}

/// The views really do publish their focus.
///
/// **This is the half that was going to be waved through as untestable.** The
/// decision layer is pure and covered, but a field that never calls
/// `reportingTextFocus` leaves the whole design inert — ⌘Z would reverse the
/// last batch while the user typed — and nothing above would notice. The test
/// host cannot make a window *key*, but that turns out not to matter:
/// `NSHostingView` renders the real view, `makeFirstResponder` engages
/// SwiftUI's `@FocusState`, and the model sees it. Measured while writing this:
/// `isKey=false foundField=true isEditingText=true fields=[.search]`.
///
/// **Serialized.** `RunLoop.current.run` inside a `@MainActor` test services
/// other main-actor jobs, so a second rendering suite interleaves with this
/// one's render passes; `MenuCommandTests.keyWindowEditingText()` also moves
/// `NSApp.keyWindow`, which is process-wide. Measured: a fixed-duration pump
/// here failed about one run in three once a second rendering suite existed.
@Suite(.serialized)
@MainActor
struct TextFocusReportingTests {
    @Test func theSearchFieldReportsItsFocus() throws {
        let store = try IndexStore.inMemory()
        let model = BrowserModel(store: store, preferences: MemoryPreferences())
        let (window, found) = renderFields(PathBarView(model: model), count: 1)
        defer { window.close() }

        let field = try #require(found.first, "PathBarView rendered no editable text field")
        #expect(!model.isEditingText, "focus was reported before anything was focused")

        model.lastCompletedBatch = CompletedBatch(batchID: "b", kind: .move,
                                                  results: [], isReversal: false)
        #expect(UndoCommandAction.title(for: UndoCommandAction.destination(for: model),
                                        undoTitle: model.undoMenuTitle)
            == "Undo Move 0 Items")

        focus(field, in: model)
        // The title follows the routing: with the field focused, ⌘Z is about
        // the typing, so the menu must not offer to reverse the batch.
        #expect(UndoCommandAction.title(for: UndoCommandAction.destination(for: model),
                                        undoTitle: model.undoMenuTitle) == "Undo")
        #expect(model.editingFields == [.search],
                """
                the search field did not publish its focus, so ⌘Z would reverse \
                the last batch while the user types
                """)
        #expect(UndoCommandAction.destination(for: model) == .textEditing)
    }

    /// Both halves of the exact-size pair report, and report *distinctly* —
    /// asserted as a union over the two so nothing depends on which one SwiftUI
    /// lays out first.
    @Test func theExactSizeFieldsBothReportTheirFocus() throws {
        let store = try IndexStore.inMemory()
        let model = BrowserModel(store: store, preferences: MemoryPreferences())
        let (window, found) = renderFields(FilterPanelView(model: model), count: 2)
        defer { window.close() }

        #expect(found.count >= 2,
                "FilterPanelView rendered \(found.count) editable fields, expected the pair")
        var seen: Set<BrowserModel.TextField> = []
        for field in found.prefix(2) {
            focus(field, in: model)
            #expect(model.isEditingText, "a size field did not publish its focus")
            seen.formUnion(model.editingFields)
        }
        #expect(seen == [.exactWidth, .exactHeight],
                "the size fields reported \(seen); both must report, and distinctly")
    }
}

/// Whether a torn-down field leaves its focus behind.
///
/// The one stale-`true` route the design could not argue away: collapsing the
/// sidebar takes `FilterPanelView` with it, and a field that had focus may never
/// get to report the blur. A leftover entry makes `isEditingText` permanently
/// true, so ⌘Z forwards to a field that is no longer on screen — nothing
/// happens, and the window quietly stops undoing.
///
/// Driven the way SwiftUI would: an observable flag removes the view from the
/// hierarchy, exactly as the sidebar toggle does.
///
/// Serialized for the reason `TextFocusReportingTests` is.
@Suite(.serialized)
@MainActor
struct TextFocusTeardownTests {
    @Observable
    final class Visibility {
        var isVisible = true
    }

    private struct Host: View {
        let model: BrowserModel
        let visibility: Visibility

        var body: some View {
            if visibility.isVisible {
                FilterPanelView(model: model)
            } else {
                Color.clear
            }
        }
    }

    @Test func aFieldTornDownWhileFocusedStopsClaimingFocus() throws {
        let store = try IndexStore.inMemory()
        let model = BrowserModel(store: store, preferences: MemoryPreferences())
        let visibility = Visibility()

        let (window, found) = renderFields(Host(model: model, visibility: visibility),
                                              count: 1)
        defer { window.close() }
        let field = try #require(found.first, "the panel rendered no editable field")

        focus(field, in: model)
        #expect(model.isEditingText, "the field never reported focus, so this proves nothing")

        // The sidebar collapses out from under the focused field.
        visibility.isVisible = false
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, model.isEditingText {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        #expect(model.editingFields.isEmpty,
                "a torn-down field is still claiming focus, so ⌘Z now goes nowhere")
        #expect(UndoCommandAction.destination(for: model) == .nowhere)
    }
}

/// Renders `view` in an off-screen window and waits for `count` editable text
/// fields to exist.
///
/// **Polls rather than pumping once.** A fixed 0.1 s pump was measured flaky —
/// roughly one full-suite run in three once a second rendering suite was running
/// alongside — and it fails as `found → []`, which reads like a view that
/// renders no fields rather than one that had not laid out yet. Everything else
/// in this file spins the run loop against a deadline for the same reason.
@MainActor
func renderFields(_ view: some View, count: Int)
    -> (window: NSWindow, fields: [NSTextField]) {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                          backing: .buffered, defer: true)
    // **Before any `close()`.** A programmatically created `NSWindow` is
    // released when closed, so closing one ARC also owns over-releases it —
    // which crashed the whole test *process*, and swift-testing reported the
    // wreckage as "1 test in 2 suites passed" plus `** TEST FAILED **` rather
    // than as a failure in the test that did it.
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)

    func editableFields() -> [NSTextField] {
        var found: [NSTextField] = []
        func walk(_ v: NSView) {
            if let field = v as? NSTextField, field.isEditable { found.append(field) }
            v.subviews.forEach(walk)
        }
        walk(host)
        return found
    }

    let deadline = Date().addingTimeInterval(5)
    var fields = editableFields()
    while Date() < deadline, fields.count < count {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        fields = editableFields()
    }
    return (window, fields)
}

/// Focuses `field` and pumps the run loop until the model's report *changes*.
///
/// Waiting for "not empty" is not enough and cost a red run: moving focus from
/// the first size field to the second leaves the set non-empty throughout, so
/// the wait fell straight through and the assertion read the state before
/// SwiftUI had delivered anything.
@MainActor
func focus(_ field: NSTextField, in model: BrowserModel) {
    let before = model.editingFields
    field.window?.makeFirstResponder(field)
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline, model.editingFields == before {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}
