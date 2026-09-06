import Testing
import Foundation
import LightboxCore
@testable import Lightbox

/// `BrowserModel.init(at:)` is the launch path `BrowserView` runs against
/// `IndexStore.defaultURL`; see `Core`'s `IntegrityTests` for `checkIntegrity()`
/// and `rebuild(at:)` themselves. These tests exercise the same `init(at:)`
/// against a disposable URL instead, so nothing here touches the real
/// Application Support directory.
@MainActor
struct LaunchIntegrityTests {
    let tree: TempDirectory

    init() throws {
        tree = try TempDirectory()
    }

    @Test func aHealthyIndexOpensWithoutRebuilding() throws {
        let url = tree.root.appendingPathComponent("index.sqlite")
        _ = try IndexStore(url: url)   // create and close

        let model = try BrowserModel(at: url)
        #expect(model.didRebuildIndex == false)
    }

    /// The corruption has to survive `IndexStore(url:)` opening the file, or
    /// this would only be testing that a throw is treated as corrupt — see
    /// `Core`'s `aDamagedTablePageIsReportedCorrupt` for why a header smash
    /// does not do that on this SQLite build.
    @Test func aCorruptIndexIsRebuiltRatherThanLeavingTheAppUnableToLaunch() throws {
        let url = tree.root.appendingPathComponent("index.sqlite")
        let store = try IndexStore(url: url)
        for i in 0..<500 {
            _ = try store.upsert(FileRecord(
                id: nil, path: "/a/\(i).jpg", parentDir: "/a", name: "\(i).jpg", ext: "jpg",
                size: 1, mtime: 1, device: 1, inode: Int64(i), width: nil, height: nil,
                captureTime: nil, captureOffset: nil, cameraMake: nil, cameraModel: nil,
                orientation: nil, contentHash: nil, imageHash: nil, imageHashKind: nil,
                phash: nil, hashedAt: nil, indexedAt: 1))
        }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int

        let handle = try FileHandle(forWritingTo: url)
        var offset = 24_576
        while offset + 200 < size {
            try handle.seek(toOffset: UInt64(offset + 50))
            try handle.write(contentsOf: Data(repeating: 0x7F, count: 200))
            offset += 4_096
        }
        try handle.close()

        let model = try BrowserModel(at: url)
        #expect(model.didRebuildIndex)
        // `store` is private to `BrowserModel`; a second connection to the
        // same file is the honest way to observe what the rebuild left
        // behind rather than reaching past the model's own encapsulation.
        #expect(try IndexStore(url: url).count() == 0)
    }

    /// A missing index file — first launch, or the file was deleted out from
    /// under the app — is not corruption and must not trip the rebuild
    /// banner: there is nothing to lose and nothing was damaged.
    @Test func aMissingIndexOpensCleanlyWithoutClaimingARebuild() throws {
        let url = tree.root.appendingPathComponent("nested/index.sqlite")
        let model = try BrowserModel(at: url)
        #expect(model.didRebuildIndex == false)
        #expect(try IndexStore(url: url).count() == 0)
    }
}
