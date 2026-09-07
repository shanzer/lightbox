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

        // No Undo item here. #6 owns ⌘Z, and the hook it attaches to —
        // `BrowserModel.lastCompletedBatch` and `undoMenuTitle` — already
        // exists. A disabled stub would have to be a second item titled
        // "Undo", and the Edit menu already carries one from SwiftUI's
        // `.undoRedo` group: two items sharing ⌘Z is precisely the collision
        // that left ⌘A mouse-only, because AppKit resolves it by stripping the
        // key equivalent off the *custom* item. #6 replaces the stock group,
        // gated on the grid having focus the same way Select All is.
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
