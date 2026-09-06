import SwiftUI
import LightboxCore

/// One row of the sidebar tree, with its children cached once they are known.
///
/// A reference type, because `OutlineGroup` walks the tree through a key path
/// and the tree has to be mutated in place as directories are read; rebuilding
/// a value tree by path on every load would be a lot of machinery for the same
/// result.
///
/// **Not `@MainActor`, deliberately.** A key path to a main-actor-isolated
/// property cannot be formed, and `OutlineGroup(_:id:children:)` needs
/// `\.children`. The type is instead non-`Sendable`, so it can never leave the
/// main actor, and every method that mutates it is individually `@MainActor`.
/// The background work is handed only `URL`s and hands back only values.
@Observable
final class FolderItem: Identifiable {
    let url: URL
    var id: String { url.path }
    var name: String { url.lastPathComponent }

    /// `nil` until this directory has been read, and `nil` again afterwards if
    /// it turned out to have no subdirectories — `OutlineGroup` reads exactly
    /// this to decide whether to draw a disclosure triangle, and an empty array
    /// would draw one that expands to nothing.
    private(set) var children: [FolderItem]?

    private var hasLoaded = false

    init(url: URL) { self.url = url }

    /// Reads this directory and each of its children, off the main thread.
    ///
    /// **The one level of lookahead is what keeps layout free of I/O.** A row's
    /// disclosure triangle depends on whether it has subdirectories, so that
    /// answer has to exist before the row is drawn — reading it during layout
    /// is what made the previous version call `contentsOfDirectory` plus an
    /// `lstat` per entry on the main thread every time the window redrew, which
    /// on the external and network volumes this app is built for is a beachball.
    /// Loading one level ahead means each row is drawn from memory.
    ///
    /// Idempotent and cached: `BrowserView` re-renders the sidebar on every
    /// change to `records`, and this must cost nothing when it does.
    @MainActor
    func loadWithLookahead() async {
        if !hasLoaded {
            hasLoaded = true
            let url = self.url
            let found = await Task.detached(priority: .userInitiated) {
                FolderNode.children(of: url)
            }.value
            children = found.isEmpty ? nil : found.map { FolderItem(url: $0.url) }
        }

        guard let children, children.contains(where: { !$0.hasLoaded }) else { return }
        let pending = children.filter { !$0.hasLoaded }
        for item in pending { item.hasLoaded = true }
        let urls = pending.map(\.url)
        // One hop to the background for the whole level rather than one per
        // child: these are all reads of the same volume anyway.
        let found = await Task.detached(priority: .userInitiated) {
            var table: [String: [FolderNode]] = [:]
            for url in urls { table[url.path] = FolderNode.children(of: url) }
            return table
        }.value
        for item in pending {
            let kids = found[item.url.path] ?? []
            item.children = kids.isEmpty ? nil : kids.map { FolderItem(url: $0.url) }
        }
    }
}

struct FolderTreeView: View {
    let model: BrowserModel
    @State private var roots: [FolderItem] = []

    var body: some View {
        List {
            OutlineGroup(roots, id: \.id, children: \.children) { item in
                Text(item.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await model.open(item.url) } }
                    // Runs once per row, when it first appears, and is a no-op
                    // for anything already cached.
                    .task(id: item.id) { await item.loadWithLookahead() }
            }
        }
        .task {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
            // Only offer a root that exists; an empty sidebar is better than a
            // row that expands to nothing.
            var isDirectory: ObjCBool = false
            let hasPictures = FileManager.default.fileExists(atPath: pictures.path,
                                                             isDirectory: &isDirectory)
                && isDirectory.boolValue
            let start = FolderItem(url: hasPictures ? pictures : home)
            roots = [start]
            await start.loadWithLookahead()
        }
    }
}
