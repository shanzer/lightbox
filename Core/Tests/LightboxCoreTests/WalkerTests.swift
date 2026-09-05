import Testing
import Foundation
@testable import LightboxCore

private struct WalkResult {
    var names = Set<String>()
    var paths: [String] = []
    var skipped: [SkipReason] = []
}

private func collect(_ root: URL, _ options: WalkOptions) -> WalkResult {
    var result = WalkResult()
    Walker().scan(root: root, options: options) { event in
        switch event {
        case .entry(let e):
            result.names.insert(e.url.lastPathComponent)
            result.paths.append(e.url.path)
        case .skipped(_, let reason):
            result.skipped.append(reason)
        }
    }
    return result
}

/// A `struct` suite so swift-testing builds a fresh instance per test and
/// releases it afterwards: teardown of `tree` is then the framework's
/// contract rather than an ARC ordering inferred from where it was last used.
struct WalkerTests {
    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    @Test func findsImagesRecursivelyAndIgnoresOtherFiles() throws {
        try tree.file("a.jpg")
        try tree.file("notes.txt")
        try tree.file("sub/b.PNG")
        try tree.file("sub/deeper/c.heic")
        let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
        #expect(result.names == ["a.jpg", "b.PNG", "c.heic"])
    }

    @Test func honoursIncludeSubdirectoriesFalse() throws {
        try tree.file("a.jpg")
        try tree.file("sub/b.jpg")
        let result = collect(tree.root, WalkOptions(includeSubdirectories: false))
        #expect(result.names == ["a.jpg"])
    }

    @Test func skipsJunkAndHiddenAndAppleDouble() throws {
        try tree.file("a.jpg")
        try tree.file(".DS_Store")
        try tree.file("._a.jpg")
        try tree.file(".hidden/b.jpg")
        let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
        #expect(result.names == ["a.jpg"])
    }

    @Test func doesNotDescendIntoLibraryBundles() throws {
        try tree.file("a.jpg")
        try tree.file("Old.photoslibrary/resources/b.jpg")
        try tree.file("Thing.app/Contents/c.jpg")
        let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
        #expect(result.names == ["a.jpg"])
    }

    @Test func handlesUnusualFilenames() throws {
        try tree.file("emoji \u{1F602}.jpg")
        try tree.file("new\nline.jpg")
        try tree.file("-leading-dash.jpg")
        let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
        #expect(result.names.count == 3)
    }

    @Test func doesNotFollowSymlinkedDirectoriesByDefault() throws {
        try tree.file("real/a.jpg")
        try tree.symlink("link", to: "real")
        let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
        #expect(result.names == ["a.jpg"])
        // Not merely "seen once": seen through the real path, with the link
        // never entered. Asserting only the name set would still pass if the
        // default flipped to following, because the visited-set would suppress
        // the duplicate and the sole difference would be a skip event.
        #expect(result.skipped.isEmpty)
        #expect(result.paths.count == 1)
        #expect(result.paths.first?.contains("/real/") == true)
        #expect(result.paths.first?.contains("/link/") == false)
    }

    @Test func detectsSymlinkLoopWhenFollowing() throws {
        try tree.file("real/a.jpg")
        try tree.symlink("real/loop", to: "real")
        let result = collect(tree.root, WalkOptions(includeSubdirectories: true, followSymlinks: true))
        #expect(result.names == ["a.jpg"])
        #expect(result.skipped.contains(.symlinkLoop))
    }

    // Root ignores mode 0o000, so as root the walk would succeed, find b.jpg,
    // and fail both expectations for a reason unrelated to the walker.
    @Test(.enabled(if: getuid() != 0, "requires a non-root user"))
    func reportsUnreadableDirectoryWithoutAborting() throws {
        try tree.file("a.jpg")
        try tree.directory("locked")
        try tree.file("locked/b.jpg")
        try tree.chmod("locked", 0o000)
        let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
        #expect(result.names == ["a.jpg"])
        #expect(result.skipped.contains(.unreadable))
    }

    @Test func reportsSizeAndModificationTime() throws {
        try tree.file("a.jpg", bytes: 1234)
        var entries: [WalkEntry] = []
        Walker().scan(root: tree.root, options: WalkOptions()) { event in
            if case .entry(let e) = event { entries.append(e) }
        }
        #expect(entries.count == 1)
        #expect(entries[0].size == 1234)
        #expect(entries[0].inode > 0)
        #expect(entries[0].device != 0)
        #expect(abs(entries[0].mtime.timeIntervalSinceNow) < 60)
    }

    @Test func stopsScanningWhenTheCallingTaskIsCancelled() async throws {
        let fileCount = 40
        for i in 0..<fileCount { try tree.file("d\(i)/a.jpg") }
        let root = tree.root

        // Control: the whole tree really is walkable when not cancelled.
        #expect(collect(root, WalkOptions()).paths.count == fileCount)

        // Cancel before the scan begins, so the assertion cannot race the walk.
        let task = Task { () -> Int in
            while !Task.isCancelled { await Task.yield() }
            var seen = 0
            Walker().scan(root: root, options: WalkOptions()) { event in
                if case .entry = event { seen += 1 }
            }
            return seen
        }
        task.cancel()
        let seen = await task.value
        #expect(seen < fileCount)
    }
}
