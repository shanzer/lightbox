import Testing
import Foundation
@testable import LightboxCore

private func collect(_ root: URL, _ options: WalkOptions) -> (names: Set<String>, skipped: [SkipReason]) {
    var names = Set<String>()
    var skipped: [SkipReason] = []
    Walker().scan(root: root, options: options) { event in
        switch event {
        case .entry(let e): names.insert(e.url.lastPathComponent)
        case .skipped(_, let reason): skipped.append(reason)
        }
    }
    return (names, skipped)
}

@Test func findsImagesRecursivelyAndIgnoresOtherFiles() throws {
    let tree = try TempTree()
    try tree.file("a.jpg")
    try tree.file("notes.txt")
    try tree.file("sub/b.PNG")
    try tree.file("sub/deeper/c.heic")
    let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
    #expect(result.names == ["a.jpg", "b.PNG", "c.heic"])
}

@Test func honoursIncludeSubdirectoriesFalse() throws {
    let tree = try TempTree()
    try tree.file("a.jpg")
    try tree.file("sub/b.jpg")
    let result = collect(tree.root, WalkOptions(includeSubdirectories: false))
    #expect(result.names == ["a.jpg"])
}

@Test func skipsJunkAndHiddenAndAppleDouble() throws {
    let tree = try TempTree()
    try tree.file("a.jpg")
    try tree.file(".DS_Store")
    try tree.file("._a.jpg")
    try tree.file(".hidden/b.jpg")
    let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
    #expect(result.names == ["a.jpg"])
}

@Test func doesNotDescendIntoLibraryBundles() throws {
    let tree = try TempTree()
    try tree.file("a.jpg")
    try tree.file("Old.photoslibrary/resources/b.jpg")
    try tree.file("Thing.app/Contents/c.jpg")
    let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
    #expect(result.names == ["a.jpg"])
}

@Test func handlesUnusualFilenames() throws {
    let tree = try TempTree()
    try tree.file("emoji \u{1F602}.jpg")
    try tree.file("new\nline.jpg")
    try tree.file("-leading-dash.jpg")
    let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
    #expect(result.names.count == 3)
}

@Test func doesNotFollowSymlinkedDirectoriesByDefault() throws {
    let tree = try TempTree()
    try tree.file("real/a.jpg")
    try tree.symlink("link", to: "real")
    let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
    #expect(result.names == ["a.jpg"])   // seen once, through the real path only
}

@Test func detectsSymlinkLoopWhenFollowing() throws {
    let tree = try TempTree()
    try tree.file("real/a.jpg")
    try tree.symlink("real/loop", to: "real")
    let result = collect(tree.root, WalkOptions(includeSubdirectories: true, followSymlinks: true))
    #expect(result.names == ["a.jpg"])
    #expect(result.skipped.contains(.symlinkLoop))
}

@Test func reportsUnreadableDirectoryWithoutAborting() throws {
    let tree = try TempTree()
    try tree.file("a.jpg")
    let locked = try tree.directory("locked")
    try tree.file("locked/b.jpg")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
    #expect(result.names == ["a.jpg"])
    #expect(result.skipped.contains(.unreadable))
}

@Test func reportsSizeAndModificationTime() throws {
    let tree = try TempTree()
    try tree.file("a.jpg", bytes: 1234)
    var entries: [WalkEntry] = []
    Walker().scan(root: tree.root, options: WalkOptions()) { event in
        if case .entry(let e) = event { entries.append(e) }
    }
    #expect(entries.count == 1)
    #expect(entries[0].size == 1234)
    #expect(entries[0].inode > 0)
    #expect(abs(entries[0].mtime.timeIntervalSinceNow) < 60)
}
