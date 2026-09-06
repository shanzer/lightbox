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
            // a second would leave two items sharing one shortcut, with AppKit
            // choosing between them. This app has no text editing surface for
            // the stock group to serve.
            CommandGroup(replacing: .textEditing) {
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
