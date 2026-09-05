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

    /// An entry that cannot be `stat`ed is a failure to look at a file, not
    /// evidence that the file is gone, and the two must not report the same
    /// way. A symlink into an unreadable directory is the shape that provokes
    /// it deterministically: `EACCES` from the resolving `stat`, where a
    /// dangling link would give `ENOENT`.
    @Test(.enabled(if: getuid() != 0, "requires a non-root user"))
    func reportsAnUnstattableEntrySeparatelyFromAnUnreadableDirectory() throws {
        try tree.file("locked/target.jpg")
        try tree.symlink("link.jpg", to: "locked/target.jpg")
        try tree.chmod("locked", 0o000)
        // Non-recursive, so the locked directory itself is never entered and
        // the only event can be the symlink's.
        let result = collect(tree.root, WalkOptions(includeSubdirectories: false,
                                                    followSymlinks: true))
        #expect(result.names.isEmpty)
        #expect(result.skipped == [.unstatable])
    }

    /// A dangling symlink is `ENOENT`: genuinely dead, and it must stay
    /// silent, or nothing would ever be reconciled away.
    @Test func aDanglingSymlinkProducesNoSkipEvent() throws {
        try tree.symlink("link.jpg", to: "never-existed.jpg")
        let result = collect(tree.root, WalkOptions(includeSubdirectories: false,
                                                    followSymlinks: true))
        #expect(result.names.isEmpty)
        #expect(result.skipped.isEmpty)
    }

    /// The other side of it: a file that is genuinely gone produces no skip,
    /// or every deletion would be protected from reconciliation forever.
    @Test func aDeletedFileProducesNoSkipEvent() throws {
        try tree.file("a.jpg")
        let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
        #expect(result.names == ["a.jpg"])
        #expect(result.skipped.isEmpty)
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
