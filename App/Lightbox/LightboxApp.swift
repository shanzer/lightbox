import AppKit
import SwiftUI

@main
struct LightboxApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Folder…") {
                    NotificationCenter.default.post(name: .openFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                // The way back out of `.rootUnreadable`: reconnecting a drive
                // changes nothing on its own, because re-picking the folder
                // already open is a no-op.
                Button("Refresh") {
                    NotificationCenter.default.post(name: .refreshFolder, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                FileOperationCommands()
            }

            // ⌘Z. `replacing:` and not `after:`, for exactly the reason the
            // pasteboard group below is replaced: SwiftUI's stock Undo already
            // carries ⌘Z, and AppKit resolves two items sharing one key
            // equivalent by stripping it off the *custom* one. `UndoMenuTests`
            // asserts the shortcut is on our item and that nothing else claims
            // it.
            //
            // No Redo goes back. Undoing an undo *is* the redo — `Core`
            // journals a reversal as an ordinary batch, so it needs no history
            // state — and the single item's title says which of the two the
            // next press will do.
            CommandGroup(replacing: .undoRedo) {
                UndoCommand()
            }

            // ⌘A as a menu command rather than as `.onKeyPress(keys: ["a"])` on
            // the grid. A key equivalent is matched by the menu bar in
            // `performKeyEquivalent`, before the event ever reaches the focused
            // view's key handling, so the view-level version could only ever
            // fire when nothing in the menu claimed the shortcut — which is to
            // say never. Routing it the same way as ⌘O and ⌘R makes it
            // deterministic, and it gives the command somewhere discoverable to
            // live.
            //
            // `replacing:` and not `after:`, because SwiftUI's stock Edit menu
            // already carries a Select All wired to the responder chain. Adding
            // a second would leave two items sharing one shortcut, and AppKit
            // resolves that collision by stripping the key equivalent off the
            // *custom* item — leaving ⌘A routed to the stock `selectAll:`,
            // which nothing in this app implements.
            //
            // The group is `.pasteboard`, not `.textEditing`, because that is
            // where the stock Select All actually lives: Cut/Copy/Paste/Delete/
            // Select All are one group. Measured, by dumping `NSApp.mainMenu`
            // from a test hosted in this app — `replacing: .textEditing` left
            // the stock item standing as `key='a' action=selectAll: target=nil`
            // and handed the custom one `key='' action=menuAction:`, so ⌘A went
            // to a selector nothing here implements and the command was
            // mouse-only. Replacing `.pasteboard` yields a single item carrying
            // both. `MenuCommandTests` pins all of it.
            //
            // SwiftUI replaces a `CommandGroup` whole, so Cut, Copy, Paste and
            // Delete go with it and have to be rebuilt here. That was free
            // while the app had no text-entry surface; Task 19 adds the search
            // field, and a text field with a dead ⌘C is worse than no search
            // field at all.
            //
            // Each is a plain `Button` that forwards to the responder chain
            // with a `nil` target, which is exactly what the stock items do:
            // AppKit walks first responder → window → app looking for
            // something that implements the selector, and `NSTextView` does.
            // The selectors are built with `Selector(("cut:"))` because
            // `#selector(NSText.cut(_:))` and friends resolve against a
            // concrete class this file has no business importing behaviour
            // from, and the double parentheses are Swift's syntax for "yes, a
            // string literal selector, I mean it".
            //
            // Deliberately *not* wired to `BrowserModel`: cutting a selection
            // of photos is a phase 2 feature and needs a pasteboard
            // representation that does not exist yet. Today these serve the
            // search field only.
            //
            // **They are not greyed out when the field is unfocused.** Stock
            // AppKit items validate through `NSMenuItem.isEnabled` and the
            // responder chain, but a SwiftUI `Button` in a `CommandGroup` does
            // not participate in that: measured with no key window, Cut, Copy,
            // Paste and Delete all come out `isEnabled == true`, while the
            // stock Undo and Redo — which SwiftUI did not build — correctly
            // validate to false. So with the grid focused these look live and
            // silently do nothing, because `sendAction` finds no handler.
            // Wrong, but wrong in the safe direction: an item that does
            // nothing beats a search field that cannot copy. Fixing it needs
            // real `NSMenuItem` validation, which means reaching outside
            // SwiftUI's command API; recorded in the Task 19 report rather
            // than papered over here.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { Self.forwardToResponder("cut:") }
                    .keyboardShortcut("x", modifiers: .command)
                Button("Copy") { Self.forwardToResponder("copy:") }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Paste") { Self.forwardToResponder("paste:") }
                    .keyboardShortcut("v", modifiers: .command)
                // No key equivalent, which is what AppKit's canonical Edit
                // menu ships and is not an oversight. A bare ⌫ on a menu item
                // is matched in `performKeyEquivalent`, *before* the focused
                // view sees the event, so it would route every backspace in
                // the search field to `delete:` — which deletes a selection
                // and does nothing without one. Adding the shortcut would
                // therefore break backspace in the field this whole group
                // exists to serve.
                Button("Delete") { Self.forwardToResponder("delete:") }

                Divider()

                // The responder chain gets first refusal, exactly as it does
                // for Cut/Copy/Paste above.
                //
                // Task 17 posted the notification unconditionally, which was
                // right when the only thing ⌘A could plausibly mean was "select
                // every photo". With a search field in the toolbar it is wrong
                // in the mirror image of the bug Task 17 fixed: measured with
                // an `NSTextField` as first responder, `performKeyEquivalent`
                // returns true and `selectAllPhotos` fires, so the field's own
                // Select All became unreachable and ⌘A while typing silently
                // selected the grid instead of the text.
                //
                // `sendAction` returns false when nothing in the chain
                // implements `selectAll:` — which is the case whenever no text
                // is being edited — and only then does this mean the photos.
                Button("Select All") { Self.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
            }
        }
    }
}

extension LightboxApp {
    /// Sends `name` down the responder chain from the key window.
    ///
    /// `to: nil` is the load-bearing part: a targeted send would need this
    /// file to know which view is focused, which is the responder chain's job
    /// and not an app-definition's.
    /// Returns whether anything in the chain handled it.
    @discardableResult
    static func forwardToResponder(_ name: String) -> Bool {
        NSApp.sendAction(Selector((name)), to: nil, from: nil)
    }

    /// ⌘A: the text being edited if there is any, the photos otherwise.
    ///
    /// A named method rather than a closure inside the `Button` so the rule
    /// itself is reachable from a test. Asserting it by re-writing the same
    /// two lines in the test would only prove the test can copy code.
    static func selectAll() {
        guard !forwardToResponder("selectAll:") else { return }
        NotificationCenter.default.post(name: .selectAllPhotos, object: nil)
    }
}

extension Notification.Name {
    static let openFolder = Notification.Name("LightboxOpenFolder")
    static let refreshFolder = Notification.Name("LightboxRefreshFolder")
    static let selectAllPhotos = Notification.Name("LightboxSelectAllPhotos")
}

/// The window the commands act on.
///
/// A focused value, not a notification, and this is the one place in the app
/// where that distinction matters. ⌘O, ⌘R and ⌘A post: every window observes,
/// and every window responds — harmless when the answer is "reload yourself",
/// and wrong when it is "move these 300 files", because a broadcast would start
/// one batch per open window. Spec §8's job runs in the window that started it,
/// so the command needs the key window's model rather than all of them.
///
/// It is also what gives the items their enabled state: a `CommandGroup`
/// `Button` does not participate in `NSMenuItem` validation (see the note on
/// Cut/Copy/Paste above), so `.disabled` on a value that resolves to the focused
/// scene is the only thing standing between an empty selection and a batch of
/// nothing.
extension FocusedValues {
    @Entry var browserModel: BrowserModel?
}

/// The four batch commands, built from `FileCommand.allCases`' cases one by one.
///
/// Written out rather than looped, so the menu's *order* and its dividers are
/// visible here and a reordering is a diff rather than an emergent property of
/// an enumeration's declaration order.
struct FileOperationCommands: View {
    @FocusedValue(\.browserModel) private var model

    var body: some View {
        item(.moveTo)
        item(.copyTo)

        Divider()

        item(.trash)
        item(.deletePermanently)
    }

    @ViewBuilder
    private func item(_ command: FileCommand) -> some View {
        Button(command.title) { perform(command) }
            .keyboardShortcut(Self.shortcut(for: command))
            .disabled(!(model?.isEnabled(command) ?? false))
    }

    /// ⌘⌫ on Move to Trash and nothing else.
    ///
    /// Checked against the existing groups before it was added: ⌘O and ⌘R are
    /// this file's, ⌘X/⌘C/⌘V/⌘A are the rebuilt pasteboard group's, and nothing
    /// claims ⌫ with a command modifier — the stock Delete item deliberately
    /// carries no key equivalent at all, because a bare ⌫ in the menu bar is
    /// matched before the search field sees the keystroke. `MenuCommandTests`
    /// asserts the count of claimants rather than trusting this comment.
    ///
    /// Move To…, Copy To… and Delete Permanently… get none: each opens a panel
    /// or a sheet, and a shortcut on a permanent delete is a way to lose photos
    /// by mistyping.
    ///
    /// **⌘⌫ needs no focus gate, unlike ⌘A.** ⌘A has to offer the responder
    /// chain first refusal because the search field wants it too — `selectAll:`
    /// means one thing to a text field and another to the grid. Nothing in this
    /// window answers ⌘⌫: `NSTextView` binds a plain ⌫, not the
    /// command-modified form, so there is no second meaning to arbitrate. What
    /// this command is gated on is state rather than focus — an empty
    /// selection, a batch already running, or a sheet still waiting for an
    /// answer — which is `BrowserModel.isEnabled(_:)`.
    private static func shortcut(for command: FileCommand) -> KeyboardShortcut? {
        command == .trash ? KeyboardShortcut(.delete, modifiers: .command) : nil
    }

    private func perform(_ command: FileCommand) {
        guard let model, model.isEnabled(command) else { return }
        switch command {
        case .moveTo, .copyTo:
            let count = model.selection.selected.count
            let noun = count == 1 ? "item" : "items"
            guard let choice = DestinationChooser.chooseDirectory(
                prompt: command == .moveTo ? "Move" : "Copy",
                message: "Choose where to \(command == .moveTo ? "move" : "copy") "
                    + "\(count) \(noun).",
                includeCompanions: model.includeCompanions) else { return }
            model.includeCompanions = choice.includeCompanions
            Task { await model.beginBatch(command.kind, destination: choice.destination) }
        case .trash:
            Task { await model.beginBatch(.trash, destination: nil) }
        case .deletePermanently:
            model.confirmPermanentDelete()
        }
    }
}

/// Where a ⌘Z goes, and the act of sending it there.
///
/// A named type rather than a closure inside the `Button`, because the routing
/// decision is the part that was wrong and the part no test could reach: the
/// menu item's action needs a key window to exercise, and `xcodebuild test`
/// does not provide one. `destination(isEditingText:canUndo:)` is a pure
/// function of two booleans and `run` takes the decision as an argument, so
/// both branches are testable with no window at all — and, since the focus flag
/// moved onto `BrowserModel`, so is the decision the menu actually makes.
/// `UndoRoutingTests` drives all of it without a key window.
enum UndoCommandAction {
    enum Destination: Equatable {
        /// The field editor's own undo. It wins whenever text is being edited,
        /// even if the grid also has a batch to reverse — ⌘Z belongs to the
        /// thing being typed in.
        case textEditing
        /// The focused window's last batch.
        case model
        /// Nothing to undo anywhere; the item is greyed out.
        case nowhere
    }

    /// The item's title, which **must agree with where the press will go**.
    ///
    /// `BrowserModel.undoMenuTitle` describes the last batch and knows nothing
    /// about focus, so naming it unconditionally meant a window with a batch
    /// behind it and the search field focused read "Undo Move 3 Items" while
    /// ⌘Z undid typing. That is the single claim the one-item, no-Redo design
    /// rests on — the title says which of the two the next press does — and it
    /// was false in exactly the state four rounds of review were about.
    ///
    /// A free function of the destination and the string, so the rule is
    /// assertable without a window.
    static func title(for destination: Destination, undoTitle: String?) -> String {
        guard destination == .model, let undoTitle else { return "Undo" }
        return undoTitle
    }

    static func destination(isEditingText: Bool, canUndo: Bool) -> Destination {
        if isEditingText { return .textEditing }
        return canUndo ? .model : .nowhere
    }

    /// The decision for a window, read off observable state.
    ///
    /// **`BrowserModel.isEditingText`, not `NSApp`.** The first version asked
    /// `NSApp.keyWindow?.firstResponder` here, which is not observable: SwiftUI
    /// never re-evaluated the command body when focus moved into a text field,
    /// so `.disabled` was decided at launch and stayed decided. The item was
    /// therefore greyed out while the user typed, and a disabled menu item
    /// still consumes its key equivalent — so ⌘Z in the search field did
    /// nothing at all, which is the harm the routing exists to prevent, moved
    /// from the action into the enabled state. The views publish their focus
    /// into the model instead; see `BrowserModel.setEditing(_:_:)`.
    @MainActor
    static func destination(for model: BrowserModel?) -> Destination {
        destination(isEditingText: model?.isEditingText ?? false,
                    canUndo: model?.canUndo ?? false)
    }

    /// Sends the ⌘Z, and says where it went.
    ///
    /// The `Task` for the model branch is handed back rather than dropped so a
    /// test can await the undo it started. The menu ignores it: the UI must not
    /// block on a batch.
    /// Sends a ⌘Z for `model`, deciding from its own state. **What the menu
    /// calls.** The overload below takes the decision instead, which is what
    /// tests drive.
    @MainActor
    @discardableResult
    static func run(model: BrowserModel?,
                    forward: @MainActor (String) -> Bool = LightboxApp.forwardToResponder)
        -> (destination: Destination, work: Task<Void, Never>?) {
        run(isEditingText: model?.isEditingText ?? false, model: model, forward: forward)
    }

    /// Sends a ⌘Z with the routing decision handed in, and says where it went.
    ///
    /// The decision is a parameter so both branches are reachable without a key
    /// window — the shipping path went untested through a whole review cycle for
    /// want of exactly this. The `Task` for the model branch is handed back
    /// rather than dropped so a test can await the undo it started; the menu
    /// ignores it, because the UI must not block on a batch.
    @MainActor
    @discardableResult
    static func run(isEditingText: Bool, model: BrowserModel?,
                    forward: @MainActor (String) -> Bool = LightboxApp.forwardToResponder)
        -> (destination: Destination, work: Task<Void, Never>?) {
        switch destination(isEditingText: isEditingText, canUndo: model?.canUndo ?? false) {
        case .textEditing:
            _ = forward("undo:")
            return (.textEditing, nil)
        case .model:
            // `model` is non-nil by construction — a nil one makes `canUndo`
            // false and the destination `.nowhere` — but an enum case cannot
            // carry that, and trapping in a menu action to prove a point is not
            // a trade worth making. Reported as `.nowhere`, which is what a
            // press with no window does.
            guard let model else { return (.nowhere, nil) }
            return (.model, Task { await model.undoLastBatch() })
        case .nowhere:
            return (.nowhere, nil)
        }
    }
}

/// ⌘Z, for the grid or for whatever is editing text.
///
/// The item replaces SwiftUI's stock Undo, so it is the *only* ⌘Z in the app:
/// AppKit binds none of its own, and a text field's undo is reachable through
/// an Edit-menu item and nothing else. That is why the item may not simply be
/// disabled when the grid has nothing to reverse, and why the action routes
/// rather than assuming — see `BrowserModel.isEditingText` for the two
/// measurements that settled how.
struct UndoCommand: View {
    @FocusedValue(\.browserModel) private var model

    var body: some View {
        // Computed once and used for all three, so the title, the enabled state
        // and the action cannot disagree about where the press is going.
        let destination = UndoCommandAction.destination(for: model)
        Button(UndoCommandAction.title(for: destination, undoTitle: model?.undoMenuTitle)) {
            UndoCommandAction.run(model: model)
        }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(destination == .nowhere)
    }
}
