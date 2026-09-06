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
            // The price is Cut, Copy, Paste and Delete, which go with the group
            // and cannot be kept — SwiftUI replaces a `CommandGroup` whole.
            // Free today because there is no text-entry surface for them to act
            // on; `replacingThePasteboardGroupAlsoDropsCutCopyAndPaste` fails
            // the moment that stops being true.
            CommandGroup(replacing: .pasteboard) {
                Button("Select All") {
                    NotificationCenter.default.post(name: .selectAllPhotos, object: nil)
                }
                .keyboardShortcut("a", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let openFolder = Notification.Name("LightboxOpenFolder")
    static let refreshFolder = Notification.Name("LightboxRefreshFolder")
    static let selectAllPhotos = Notification.Name("LightboxSelectAllPhotos")
}
