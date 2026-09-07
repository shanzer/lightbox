import Testing
import Foundation
@testable import LightboxCore

/// Inserts a row directly, so a test can state exactly which hashes a file
/// carries without having to find a real file that produces them.
///
/// The `image_hash = nil` cases matter most: they stand for the formats spec
/// §11 says fall back to `content_hash` — the ones with no image-hash rule.
/// Written as a NULL column rather than as a fixture in some particular
/// format *on purpose*: the fallback is a property of the column being NULL,
/// not of any format, and which formats have a rule keeps moving (HEIC had no
/// rule when this was written and gained `heic-item-v1` days later). A test
/// pinned to a format would need rewriting every time that list changes; this
/// one tests the behaviour the list feeds into.
@discardableResult
private func insert(_ store: IndexStore, path: String,
                    content: String?, image: String? = nil, kind: String? = nil,
                    phash: String? = nil, device: Int64 = 1,
                    width: Int? = 100, height: Int? = 80,
                    orientation: Int? = 1, capture: Double? = 1_550_000_000) throws -> FileRecord {
    let record = FileRecord(
        id: nil, path: path,
        parentDir: (path as NSString).deletingLastPathComponent,
        name: (path as NSString).lastPathComponent,
        ext: (path as NSString).pathExtension.lowercased(),
        size: 1234, mtime: 1, device: device, inode: 1,
        width: width, height: height, captureTime: capture, captureOffset: nil,
        cameraMake: nil, cameraModel: nil, orientation: orientation,
        contentHash: nil, imageHash: nil, imageHashKind: nil, phash: nil,
        hashedAt: nil, indexedAt: 1)
    let id = try store.upsert(record)
    var stored = record
    stored.id = id
    // Through the guarded writer, not a raw UPDATE: hashes only ever reach a
    // row this way in production, and a test that bypassed the guard would be
    // exercising a path that does not exist.
    let landed = try store.setHashes(for: stored, content: content, image: image,
                                     imageKind: kind, phash: phash, hashedAt: 2)
    #expect(landed, "setHashes refused the write for \(path)")
    return try #require(try store.record(atPath: path))
}

/// Flips `count` bits of a 64-bit hex hash, lowest bit first, so a test can
/// state a Hamming distance exactly.
private func flippingBits(_ hex: String, _ count: Int) throws -> String {
    let base = try PerceptualHash(hex: hex).value
    var mask: UInt64 = 0
    for bit in 0..<count { mask |= UInt64(1) << UInt64(bit) }
    return PerceptualHash(value: base ^ mask).hex
}

private func paths(_ files: [FileRecord]) -> [String] {
    files.map { ($0.path as NSString).lastPathComponent }
}

/// A `struct` suite so swift-testing builds a fresh instance per test and
/// releases it afterwards.
struct DuplicateFinderTests {
    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    private let everywhere = SearchQuery(scope: .everywhere)

    // MARK: - The acceptance fixture

    /// Three copies of one photograph, made the three ways copies actually
    /// happen: a byte-for-byte duplicate, the same image with its metadata
    /// rewritten, and the same image re-encoded at a lower quality.
    ///
    /// The first two share an `image_hash` and so form one exact group with two
    /// `content_hash` sub-groups; the re-encode has different compressed bytes,
    /// so no exact hash can see it and only the perceptual tier can.
    ///
    /// The metadata rewrite is done with ImageIO rather than exiftool so that
    /// CI, which has no exiftool, runs this test rather than skipping it.
    @Test func threeCopiesGroupExactlyAndTheReEncodeArrivesAsANearMatch() async throws {
        let store = try IndexStore.inMemory()
        let original = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a-original.jpg"),
                                               width: 320, height: 240, seed: 0)
        let copy = tree.root.appendingPathComponent("b-copy.jpg")
        try FileManager.default.copyItem(at: original, to: copy)
        try Fixtures.writeImage(to: tree.root.appendingPathComponent("c-exif.jpg"),
                                width: 320, height: 240, seed: 0,
                                captureTime: "2001:01:01 01:01:01", offset: "+09:00",
                                make: "OtherCam", model: "Z9")
        try Fixtures.writeImage(to: tree.root.appendingPathComponent("d-reencoded.jpg"),
                                width: 320, height: 240, seed: 0, quality: 0.25)

        let coordinator = IndexCoordinator(store: store, walker: Walker(),
                                           metadata: MetadataReader(), hasher: FileHasher(),
                                           grayscale: GrayscaleRenderer(), concurrency: 2)
        _ = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
        let pass = try await coordinator.runHashingPass(root: tree.root, onProgress: nil)
        try #require(pass.completed == 4)

        let report = try DuplicateFinder(store: store)
            .report(for: SearchQuery(scope: .folder(path: tree.root.path, recursive: true)))

        #expect(report.exact.count == 1)
        let group = try #require(report.exact.first)
        #expect(group.imageHash != nil)
        #expect(group.kind == JPEGImageHash.kind)
        #expect(group.copies.count == 2)
        #expect(paths(group.copies[0].files) == ["a-original.jpg", "b-copy.jpg"])
        #expect(paths(group.copies[1].files) == ["c-exif.jpg"])
        // The sub-groups are what "byte-identical" means, so they must really
        // differ on content_hash and agree on image_hash.
        #expect(group.copies[0].contentHash != group.copies[1].contentHash)
        #expect(Set(group.files.compactMap(\.imageHash)).count == 1)
        // What the view needs, carried on the records themselves.
        #expect(group.files.allSatisfy { $0.width == 320 && $0.height == 240 })
        #expect(group.files.allSatisfy { $0.orientation != nil })
        #expect(group.files.allSatisfy { $0.captureTime != nil })

        #expect(report.nearTierSkipped == nil)
        #expect(report.near.count == 1)
        let near = try #require(report.near.first)
        #expect((near.seed.path as NSString).lastPathComponent == "a-original.jpg")
        #expect(paths(near.matches.map(\.file)) == ["d-reencoded.jpg"])
        // Measured, not assumed: quality 0.25 moves this image 8 bits.
        #expect(near.matches[0].distance == 8)
        #expect(near.matches[0].distance <= DuplicateFinder.nearThreshold)
    }

    // MARK: - The content_hash fallback

    @Test func rowsWithNoImageHashGroupByContentHash() throws {
        let store = try IndexStore.inMemory()
        try insert(store, path: "/lib/a.cr2", content: "same", image: nil)
        try insert(store, path: "/lib/b.cr2", content: "same", image: nil)
        try insert(store, path: "/lib/c.cr2", content: "other", image: nil)

        let report = try DuplicateFinder(store: store).report(for: everywhere)
        #expect(report.exact.count == 1)
        let group = try #require(report.exact.first)
        #expect(group.imageHash == nil)
        #expect(group.kind == nil)
        #expect(group.copies.count == 1)
        #expect(group.copies[0].contentHash == "same")
        #expect(paths(group.copies[0].files) == ["a.cr2", "b.cr2"])
    }

    /// A file with no `image_hash` must not be pulled into an image-hash group
    /// by a content hash it happens to share with a file that has one — the two
    /// keys live in separate namespaces.
    @Test func anImageHashGroupAndAContentHashGroupStaySeparate() throws {
        let store = try IndexStore.inMemory()
        try insert(store, path: "/lib/a.jpg", content: "shared", image: "img", kind: "jpeg-scan-v1")
        try insert(store, path: "/lib/b.jpg", content: "shared", image: "img", kind: "jpeg-scan-v1")
        try insert(store, path: "/lib/c.cr2", content: "shared", image: nil)

        let report = try DuplicateFinder(store: store).report(for: everywhere)
        #expect(report.exact.count == 1)
        #expect(paths(report.exact[0].files) == ["a.jpg", "b.jpg"])
    }

    @Test func aRowAppearsInAtMostOneExactGroup() throws {
        let store = try IndexStore.inMemory()
        for name in ["a", "b"] {
            try insert(store, path: "/lib/\(name).jpg", content: "c1", image: "i1", kind: "k")
        }
        for name in ["c", "d"] {
            try insert(store, path: "/lib/\(name).jpg", content: "c2", image: "i2", kind: "k")
        }
        try insert(store, path: "/lib/e.jpg", content: "c3", image: "i3", kind: "k")

        let report = try DuplicateFinder(store: store).report(for: everywhere)
        let all = report.exact.flatMap { $0.files.compactMap(\.id) }
        #expect(all.count == Set(all).count)
        #expect(report.exact.count == 2)
        // A file with no twin is not a group of one.
        #expect(!all.contains(where: { id in
            (try? store.record(atPath: "/lib/e.jpg"))??.id == id
        }))
    }

    // MARK: - Scope

    @Test func groupingIsScopedByTheSameCompiledWhereTheGridUses() throws {
        let store = try IndexStore.inMemory()
        try insert(store, path: "/lib/in/a.jpg", content: "c1", image: "i1", kind: "k")
        try insert(store, path: "/lib/in/b.jpg", content: "c1", image: "i1", kind: "k")
        try insert(store, path: "/lib/out/c.jpg", content: "c1", image: "i1", kind: "k")

        let finder = DuplicateFinder(store: store)
        #expect(try finder.report(for: everywhere).exact.first?.files.count == 3)
        let scoped = try finder.report(for: SearchQuery(scope: .folder(path: "/lib/in",
                                                                       recursive: true)))
        #expect(paths(scoped.exact.first?.files ?? []) == ["a.jpg", "b.jpg"])
    }

    /// The predicate, not only the folder: "duplicates among the PNGs" has to
    /// be the same code path as "duplicates in this folder".
    @Test func theQueryPredicateNarrowsTheGroupsToo() throws {
        let store = try IndexStore.inMemory()
        try insert(store, path: "/lib/a.jpg", content: "c1", image: "i1", kind: "k")
        try insert(store, path: "/lib/b.jpg", content: "c1", image: "i1", kind: "k")
        try insert(store, path: "/lib/c.png", content: "c1", image: "i1", kind: "k")

        let query = SearchQuery(scope: .everywhere, predicate: .fileExtension(["png"]))
        let report = try DuplicateFinder(store: store).report(for: query)
        // One PNG in scope: no twin, so no group.
        #expect(report.exact.isEmpty)
    }

    /// A backup copy on a second volume is a legitimate member of the group,
    /// and hiding it would hide exactly the copy the user wants to keep.
    @Test func aGroupSpanningTwoVolumesShowsBothCopies() throws {
        let store = try IndexStore.inMemory()
        try insert(store, path: "/Volumes/main/a.jpg", content: "c1", image: "i1",
                   kind: "k", device: 16_777_220)
        try insert(store, path: "/Volumes/backup/a.jpg", content: "c1", image: "i1",
                   kind: "k", device: 16_777_231)

        let report = try DuplicateFinder(store: store).report(for: everywhere)
        #expect(report.exact.count == 1)
        #expect(Set(report.exact[0].files.map(\.device)).count == 2)
        #expect(report.exact[0].files.count == 2)
    }

    // MARK: - The near tier

    /// The threshold is 12 bits, against a measured cross-tool divergence of
    /// 0-4 (HANDOFF §6). Both sides of the boundary, from the golden vector
    /// `PerceptualHashTests` locks against photolib.
    @Test func theNearThresholdIsTwelveBitsInclusive() throws {
        let golden = "9f32a3b705ae1b18"
        let twelve = try flippingBits(golden, 12)
        let thirteen = try flippingBits(golden, 13)
        // The distances the assertions below rest on, stated rather than assumed.
        #expect(try PerceptualHash(hex: golden).distance(to: PerceptualHash(hex: twelve)) == 12)
        #expect(try PerceptualHash(hex: golden).distance(to: PerceptualHash(hex: thirteen)) == 13)
        #expect(DuplicateFinder.nearThreshold == 12)

        let store = try IndexStore.inMemory()
        try insert(store, path: "/lib/a.jpg", content: "c1", image: "i1", kind: "k", phash: golden)
        try insert(store, path: "/lib/b.jpg", content: "c2", image: "i2", kind: "k", phash: twelve)
        try insert(store, path: "/lib/c.jpg", content: "c3", image: "i3", kind: "k", phash: thirteen)

        let report = try DuplicateFinder(store: store).report(for: everywhere)
        #expect(report.exact.isEmpty)
        #expect(report.near.count == 1)
        #expect((report.near[0].seed.path as NSString).lastPathComponent == "a.jpg")
        #expect(paths(report.near[0].matches.map(\.file)) == ["b.jpg"])
        #expect(report.near[0].matches[0].distance == 12)
    }

    /// The exclusion that keeps the two tiers from saying the same thing twice.
    @Test func aNearGroupNeverRepeatsAPairFromTheSameExactGroup() throws {
        let store = try IndexStore.inMemory()
        // Same image_hash, so one exact group; identical phash, so distance 0.
        try insert(store, path: "/lib/a.jpg", content: "c1", image: "i1", kind: "k",
                   phash: "9f32a3b705ae1b18")
        try insert(store, path: "/lib/b.jpg", content: "c2", image: "i1", kind: "k",
                   phash: "9f32a3b705ae1b18")

        let report = try DuplicateFinder(store: store).report(for: everywhere)
        #expect(report.exact.count == 1)
        #expect(report.exact[0].files.count == 2)
        #expect(report.near.isEmpty, "a pair already reported exactly must not be reported again")
    }

    /// A member of an exact group is still eligible to be the seed of a near
    /// group, because the near neighbour is a *different* image to the group.
    @Test func aFileInAnExactGroupCanStillSeedANearGroup() throws {
        let store = try IndexStore.inMemory()
        let golden = "9f32a3b705ae1b18"
        try insert(store, path: "/lib/a.jpg", content: "c1", image: "i1", kind: "k", phash: golden)
        try insert(store, path: "/lib/b.jpg", content: "c2", image: "i1", kind: "k", phash: golden)
        try insert(store, path: "/lib/c.jpg", content: "c3", image: "i2", kind: "k",
                   phash: try flippingBits(golden, 4))

        let report = try DuplicateFinder(store: store).report(for: everywhere)
        #expect(report.exact.count == 1)
        #expect(report.near.count == 1)
        #expect((report.near[0].seed.path as NSString).lastPathComponent == "a.jpg")
        #expect(paths(report.near[0].matches.map(\.file)) == ["c.jpg"])
    }

    /// Star-shaped, one seed per record: three mutually close files produce one
    /// group of two neighbours, not three overlapping pairs.
    @Test func nearGroupsAreStarShapedAndEachRecordBelongsToOne() throws {
        let store = try IndexStore.inMemory()
        let golden = "9f32a3b705ae1b18"
        try insert(store, path: "/lib/a.jpg", content: "c1", image: "i1", kind: "k", phash: golden)
        try insert(store, path: "/lib/b.jpg", content: "c2", image: "i2", kind: "k",
                   phash: try flippingBits(golden, 2))
        try insert(store, path: "/lib/c.jpg", content: "c3", image: "i3", kind: "k",
                   phash: try flippingBits(golden, 3))

        let report = try DuplicateFinder(store: store).report(for: everywhere)
        #expect(report.near.count == 1)
        #expect((report.near[0].seed.path as NSString).lastPathComponent == "a.jpg")
        // Sorted by distance, then by name.
        #expect(paths(report.near[0].matches.map(\.file)) == ["b.jpg", "c.jpg"])
        #expect(report.near[0].matches.map(\.distance) == [2, 3])
    }

    /// Seeds are taken in the grid's order — name, then path — not in row-id
    /// order, so the result does not move when SQLite reuses a rowid.
    @Test func seedsAreChosenInNameOrderNotRowIdOrder() throws {
        let store = try IndexStore.inMemory()
        let golden = "9f32a3b705ae1b18"
        // Inserted z first, so the lowest row id is the *last* name.
        try insert(store, path: "/lib/z.jpg", content: "c1", image: "i1", kind: "k", phash: golden)
        try insert(store, path: "/lib/a.jpg", content: "c2", image: "i2", kind: "k",
                   phash: try flippingBits(golden, 2))

        let report = try DuplicateFinder(store: store).report(for: everywhere)
        #expect(report.near.count == 1)
        #expect((report.near[0].seed.path as NSString).lastPathComponent == "a.jpg")
    }

    @Test func rowsWithNoPerceptualHashAreNotNearAnything() throws {
        let store = try IndexStore.inMemory()
        try insert(store, path: "/lib/a.jpg", content: "c1", image: "i1", kind: "k", phash: nil)
        try insert(store, path: "/lib/b.jpg", content: "c2", image: "i2", kind: "k", phash: nil)

        let report = try DuplicateFinder(store: store).report(for: everywhere)
        #expect(report.near.isEmpty)
        #expect(report.nearTierSkipped == nil)
    }

    /// Above the ceiling the pairwise scan is refused and says so, rather than
    /// running for minutes or silently returning a partial answer. The exact
    /// tier is unaffected.
    @Test func theNearTierIsSkippedAndReportedAboveTheCeiling() throws {
        let store = try IndexStore.inMemory()
        let golden = "9f32a3b705ae1b18"
        try insert(store, path: "/lib/a.jpg", content: "c1", image: "i1", kind: "k", phash: golden)
        try insert(store, path: "/lib/b.jpg", content: "c1", image: "i1", kind: "k",
                   phash: try flippingBits(golden, 2))

        let finder = DuplicateFinder(store: store, nearTierCeiling: 1)
        let report = try finder.report(for: everywhere)
        #expect(report.nearTierSkipped == 2)
        #expect(report.near.isEmpty)
        #expect(report.exact.count == 1, "the exact tier still runs")
    }

    /// A corrupt `phash` must cost that one row its near matches, not the whole
    /// duplicate view.
    @Test func aMalformedStoredPerceptualHashIsSkippedRatherThanThrowing() throws {
        let store = try IndexStore.inMemory()
        let golden = "9f32a3b705ae1b18"
        try insert(store, path: "/lib/a.jpg", content: "c1", image: "i1", kind: "k", phash: golden)
        try insert(store, path: "/lib/b.jpg", content: "c2", image: "i2", kind: "k",
                   phash: try flippingBits(golden, 2))
        try insert(store, path: "/lib/c.jpg", content: "c3", image: "i3", kind: "k",
                   phash: "not-a-hash")

        let report = try DuplicateFinder(store: store).report(for: everywhere)
        #expect(report.near.count == 1)
        #expect(paths(report.near[0].matches.map(\.file)) == ["b.jpg"])
    }

    // MARK: - Ordering

    @Test func groupsSubGroupsAndFilesAreAllInNameOrder() throws {
        let store = try IndexStore.inMemory()
        for (path, content, image) in [("/lib/zeta.jpg", "c2", "i2"), ("/lib/Alpha.jpg", "c1", "i1"),
                                       ("/lib/beta.jpg", "c1", "i1"), ("/lib/yankee.jpg", "c2", "i2")] {
            try insert(store, path: path, content: content, image: image, kind: "k")
        }
        let report = try DuplicateFinder(store: store).report(for: everywhere)
        #expect(report.exact.map { paths($0.files) }
                == [["Alpha.jpg", "beta.jpg"], ["yankee.jpg", "zeta.jpg"]])
    }

    @Test func anEmptyLibraryReportsNoGroups() throws {
        let store = try IndexStore.inMemory()
        let report = try DuplicateFinder(store: store).report(for: everywhere)
        #expect(report.exact.isEmpty)
        #expect(report.near.isEmpty)
        #expect(report.nearTierSkipped == nil)
    }

    @Test func anInvalidScopeThrowsRatherThanReportingNoDuplicates() throws {
        let store = try IndexStore.inMemory()
        #expect(throws: IndexStoreError.invalidScope("Pictures")) {
            _ = try DuplicateFinder(store: store)
                .report(for: SearchQuery(scope: .folder(path: "Pictures", recursive: true)))
        }
    }
}
