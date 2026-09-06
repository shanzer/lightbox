import Testing
import Foundation
@testable import LightboxCore

/// A `struct` suite so swift-testing builds a fresh instance per test and
/// releases it afterwards: teardown of `tree` is then the framework's
/// contract rather than an ARC ordering inferred from where it was last used.
struct FolderNodeTests {
    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    @Test func listsOnlyDirectories() throws {
        try tree.directory("photos")
        try tree.directory("archive")
        try tree.file("loose.jpg")
        #expect(FolderNode.children(of: tree.root).map(\.name) == ["archive", "photos"])
    }

    @Test func hidesDotDirectoriesAndOpaqueBundles() throws {
        try tree.directory("visible")
        try tree.directory(".hidden")
        try tree.directory("Old.photoslibrary")
        try tree.directory("Thing.app")
        #expect(FolderNode.children(of: tree.root).map(\.name) == ["visible"])
    }

    /// The sidebar must agree with `Walker`, which does not follow symlinks by
    /// default: a link that happens to point at a directory is not a folder the
    /// grid would ever populate.
    @Test func excludesSymlinksEvenWhenTheyPointAtDirectories() throws {
        try tree.directory("real")
        try tree.symlink("alias", to: "real")
        #expect(FolderNode.children(of: tree.root).map(\.name) == ["real"])
    }

    @Test func returnsEmptyForAMissingDirectory() throws {
        #expect(FolderNode.children(of: tree.root.appendingPathComponent("nope")).isEmpty)
    }

    @Test func returnsEmptyForAnUnreadableDirectory() throws {
        try tree.directory("locked/inside")
        try tree.chmod("locked", 0o000)
        #expect(FolderNode.children(of: tree.root.appendingPathComponent("locked")).isEmpty)
    }

    @Test func returnsEmptyWhenHandedAFileRatherThanADirectory() throws {
        let file = try tree.file("photo.jpg")
        #expect(FolderNode.children(of: file).isEmpty)
    }

    @Test func sortsCaseInsensitivelyAndNaturally() throws {
        for name in ["Zebra", "apple", "Banana", "2019", "10-october"] {
            try tree.directory(name)
        }
        #expect(FolderNode.children(of: tree.root).map(\.name)
                == ["10-october", "2019", "apple", "Banana", "Zebra"])
    }

    @Test func identityIsTheAbsolutePath() throws {
        let child = try tree.directory("photos")
        let nodes = FolderNode.children(of: tree.root)
        #expect(nodes.count == 1)
        #expect(nodes.first?.id == child.path)
        #expect(nodes.first?.url.path == child.path)
    }
}
