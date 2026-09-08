import Testing
import Foundation
@testable import LightboxCore

@discardableResult
private func index(_ url: URL, into store: IndexStore) throws -> Int64 {
    var st = stat()
    guard stat(url.path, &st) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return try store.upsert(FileRecord(
        id: nil, path: url.path,
        parentDir: url.deletingLastPathComponent().path,
        name: url.lastPathComponent, ext: url.pathExtension.lowercased(),
        size: Int64(st.st_size),
        mtime: TimeInterval(st.st_mtimespec.tv_sec)
            + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000,
        device: Int64(st.st_dev), inode: Int64(bitPattern: UInt64(st.st_ino)),
        volumeUUID: nil, width: 100, height: 100,
        captureTime: nil, captureOffset: nil, cameraMake: nil, cameraModel: nil,
        orientation: nil, contentHash: "hash-\(url.lastPathComponent)",
        imageHash: nil, imageHashKind: nil, phash: nil,
        hashedAt: 1_700_000_100, indexedAt: 1_700_000_000))
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
private func bytes(_ url: URL) throws -> Int { try Data(contentsOf: url).count }

// MARK: - Collisions

struct FileOperatorCollisionTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// The acceptance case: **two sources with the same basename headed for one
    /// destination produce a plan with one collision.** Neither is on disk in
    /// the destination yet — they collide with each other — which is exactly
    /// the case a pre-flight that only `stat`s the destination misses, and
    /// missing it means the second file silently destroys the first.
    @Test func twoSourcesWithOneBasenameCollideWithEachOther() async throws {
        let first = try tree.file("a/IMG_0001.jpg", bytes: 10)
        let second = try tree.file("b/IMG_0001.jpg", bytes: 20)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(first, into: store)
        try index(second, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [first, second],
                                     destination: destination)
        #expect(plan.items[0].collisions.isEmpty)
        #expect(plan.items[1].collisions
                == [FileOperationCollision(
                    path: destination.appendingPathComponent("IMG_0001.jpg"),
                    kind: .claimedInBatch)])
        #expect(plan.unresolvedCollisionIndices == [1])
        #expect(plan.hasUnresolvedCollisions)
    }

    /// An unresolved plan is refused rather than run under a default. There is
    /// no safe default: skip loses the operation, replace loses a file.
    @Test func executingAnUnresolvedPlanThrows() async throws {
        let first = try tree.file("a/IMG_0001.jpg", bytes: 10)
        let second = try tree.file("b/IMG_0001.jpg", bytes: 20)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [first, second],
                                     destination: destination)
        await #expect(throws: FileOperatorError.unresolvedCollisions([1])) {
            _ = try await op.execute(plan)
        }
        // Refused before anything is journalled, let alone moved.
        #expect(try store.journalRows(batchID: plan.batchID).isEmpty)
        #expect(exists(second))
    }

    @Test func skipLeavesTheCollidingItemWhereItIsAndJournalsNothingForIt() async throws {
        let first = try tree.file("a/IMG_0001.jpg", bytes: 10)
        let second = try tree.file("b/IMG_0001.jpg", bytes: 20)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(first, into: store)
        try index(second, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [first, second],
                                     destination: destination)
        let results = try await op.execute(plan.resolvingAllCollisions(with: .skip))

        #expect(results[0].outcome == .completed)
        #expect(results[1].outcome == .skipped(.collisionResolved))
        #expect(try bytes(destination.appendingPathComponent("IMG_0001.jpg")) == 10)
        #expect(exists(second))
        #expect(try store.record(atPath: second.path) != nil)
        // The journal records intent. A skipped item had none.
        let rows = try store.journalRows(batchID: plan.batchID)
        #expect(rows.count == 1)
        #expect(rows[0].src == first.path)
        #expect(rows[0].state == .complete)
    }

    @Test func renameGivesTheCollidingItemAFreeNameInBothFilesystemAndIndex() async throws {
        let first = try tree.file("a/IMG_0001.jpg", bytes: 10)
        let second = try tree.file("b/IMG_0001.jpg", bytes: 20)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(first, into: store)
        try index(second, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [first, second],
                                     destination: destination)
        let results = try await op.execute(plan.resolvingAllCollisions(with: .rename))
        #expect(results.allSatisfy { $0.outcome == .completed })

        #expect(try bytes(destination.appendingPathComponent("IMG_0001.jpg")) == 10)
        #expect(try bytes(destination.appendingPathComponent("IMG_0001 2.jpg")) == 20)
        #expect(!exists(first))
        #expect(!exists(second))
        #expect(try store.count() == 2)
        let renamed = try #require(
            try store.record(atPath: destination.appendingPathComponent("IMG_0001 2.jpg").path))
        #expect(renamed.name == "IMG_0001 2.jpg")
        #expect(renamed.parentDir == destination.path)
        #expect(renamed.contentHash == "hash-IMG_0001.jpg")
    }

    /// Replace must leave exactly one file *and* exactly one row. The row of
    /// the file that was overwritten is deleted in the same transaction as the
    /// row taking its place; leaving it behind would be an index entry for
    /// bytes that no longer exist, in the table duplicate detection reads.
    @Test func replaceOverwritesTheFileAndRetiresItsRow() async throws {
        // The batch reaches the real Trash (through `disposeOfStash`), so the
        // fixture name must be unique to this test run.
        let name = tree.uniqueName("IMG_0001", ext: "jpg")
        let source = try tree.file("a/\(name)", bytes: 20)
        let destination = try tree.directory("to")
        let occupant = try tree.file("to/\(name)", bytes: 10)
        let store = try IndexStore.inMemory()
        try index(source, into: store)
        let occupantID = try index(occupant, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [source], destination: destination)
        defer {
            for row in (try? store.journalRows(batchID: plan.batchID)) ?? [] {
                row.trashURL.map { try? FileManager.default.removeItem(atPath: $0) }
            }
        }
        #expect(plan.items[0].collisions
                == [FileOperationCollision(path: occupant, kind: .occupied)])
        let results = try await op.execute(plan.resolvingCollision(at: 0, with: .replace))
        #expect(results[0].outcome == .completed)

        #expect(try bytes(occupant) == 20)
        #expect(!exists(source))
        #expect(try store.count() == 1)
        let row = try #require(try store.record(atPath: occupant.path))
        #expect(row.id != occupantID)
        #expect(row.contentHash == "hash-\(name)")
        // No stash left behind.
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: destination.path)
            .filter { $0.hasPrefix(".lightbox-replaced-") }
        #expect(leftovers.isEmpty)
    }

    /// Resolution is per item as well as applied-to-all, and each item's choice
    /// changes what names the *next* item finds free.
    @Test func resolutionsArePerItemAndCompose() async throws {
        let first = try tree.file("a/IMG_0001.jpg", bytes: 10)
        let second = try tree.file("b/IMG_0001.jpg", bytes: 20)
        let third = try tree.file("c/IMG_0001.jpg", bytes: 30)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        for url in [first, second, third] { try index(url, into: store) }

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .copy, sources: [first, second, third],
                                     destination: destination)
        let resolved = plan
            .resolvingCollision(at: 1, with: .rename)
            .resolvingCollision(at: 2, with: .rename)
        #expect(!resolved.hasUnresolvedCollisions)
        #expect(resolved.items[1].destination?.lastPathComponent == "IMG_0001 2.jpg")
        #expect(resolved.items[2].destination?.lastPathComponent == "IMG_0001 3.jpg")

        let results = try await op.execute(resolved)
        #expect(results.allSatisfy { $0.outcome == .completed })
        #expect(try bytes(destination.appendingPathComponent("IMG_0001 3.jpg")) == 30)
        #expect(try store.count() == 6)
    }

    /// A move into the folder the file is already in is not a collision with
    /// itself, and it is emphatically not a `replace` — that would unlink the
    /// source and then move a file that no longer exists.
    @Test func movingAFileIntoItsOwnFolderIsANoOpRatherThanASelfCollision() async throws {
        let folder = try tree.directory("here")
        let source = try tree.file("here/IMG_0001.jpg", bytes: 10)
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [source], destination: folder)
        #expect(plan.items[0].collisions.isEmpty)

        let results = try await op.execute(plan)
        #expect(results[0].outcome == .skipped(.alreadyAtDestination))
        #expect(try bytes(source) == 10)
        #expect(try store.record(atPath: source.path) != nil)
    }
}

// MARK: - Companions

struct FileOperatorCompanionTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// The acceptance case, exactly: `IMG_0001.CR2` + `IMG_0001.JPG` +
    /// `IMG_0001.xmp` move together when only the RAW is selected. The `.xmp`
    /// is a Lightroom crop and the JPEG is the other half of the pair; leaving
    /// either behind silently orphans an edit.
    @Test func aRawTakesItsJPEGAndItsSidecarWithIt() async throws {
        let raw = try tree.file("from/IMG_0001.CR2", bytes: 40)
        let jpeg = try tree.file("from/IMG_0001.JPG", bytes: 30)
        _ = try tree.file("from/IMG_0001.xmp", bytes: 5)
        // A file that merely starts with the same characters is not a companion.
        let unrelated = try tree.file("from/IMG_00012.JPG", bytes: 7)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(raw, into: store)
        try index(jpeg, into: store)
        try index(unrelated, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [raw], destination: destination)
        #expect(plan.items.count == 1)
        #expect(plan.items[0].companions.map(\.lastPathComponent)
                == ["IMG_0001.JPG", "IMG_0001.xmp"])

        let results = try await op.execute(plan)
        #expect(results[0].outcome == .completed)
        #expect(results[0].companions.count == 2)

        for name in ["IMG_0001.CR2", "IMG_0001.JPG", "IMG_0001.xmp"] {
            #expect(exists(destination.appendingPathComponent(name)))
            #expect(!exists(tree.root.appendingPathComponent("from/\(name)")))
        }
        #expect(exists(unrelated))
        // Both indexed companions moved their rows; the sidecar has no row and
        // needed none.
        #expect(try store.record(atPath:
            destination.appendingPathComponent("IMG_0001.JPG").path) != nil)
        #expect(try store.record(atPath: jpeg.path) == nil)
        #expect(try store.record(atPath: unrelated.path) != nil)
        // Three files, three journal rows, all complete: the sidecar is
        // journalled too, because undo has to put it back.
        let rows = try store.journalRows(batchID: plan.batchID)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.state == .complete })
        #expect(Set(rows.map { ($0.src as NSString).lastPathComponent })
                == ["IMG_0001.CR2", "IMG_0001.JPG", "IMG_0001.xmp"])
    }

    @Test func withTheFlagOffOnlyTheSelectedFileMoves() async throws {
        let raw = try tree.file("from/IMG_0001.CR2", bytes: 40)
        let jpeg = try tree.file("from/IMG_0001.JPG", bytes: 30)
        let sidecar = try tree.file("from/IMG_0001.xmp", bytes: 5)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(raw, into: store)
        try index(jpeg, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [raw], destination: destination,
                                     includeCompanions: false)
        #expect(plan.items[0].companions.isEmpty)
        let results = try await op.execute(plan)
        #expect(results[0].outcome == .completed)

        #expect(exists(destination.appendingPathComponent("IMG_0001.CR2")))
        #expect(exists(jpeg))
        #expect(exists(sidecar))
        #expect(try store.journalRows(batchID: plan.batchID).count == 1)
    }

    /// Selecting the JPEG of a pair takes the RAW: the relation is symmetric,
    /// and a user who selects the visible half expects the invisible one to
    /// follow.
    @Test func selectingTheJPEGTakesTheRaw() async throws {
        let raw = try tree.file("from/IMG_0002.NEF", bytes: 40)
        _ = try tree.file("from/IMG_0002.jpg", bytes: 30)
        let jpeg = tree.root.appendingPathComponent("from/IMG_0002.jpg")
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [jpeg], destination: destination)
        #expect(plan.items[0].companions == [raw])
        _ = try await op.execute(plan)
        #expect(exists(destination.appendingPathComponent("IMG_0002.NEF")))
    }

    /// Both halves selected is one item with one companion, not two items that
    /// each claim the other — which would journal every file twice and move the
    /// pair, then try to move it again.
    @Test func selectingBothHalvesOfAPairHandlesEachFileOnce() async throws {
        let raw = try tree.file("from/IMG_0003.CR2", bytes: 40)
        let jpeg = try tree.file("from/IMG_0003.jpg", bytes: 30)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [raw, jpeg],
                                     destination: destination)
        #expect(plan.items.count == 2)
        #expect(plan.items.allSatisfy { $0.companions.isEmpty })
        let results = try await op.execute(plan)
        #expect(results.allSatisfy { $0.outcome == .completed })
        #expect(try store.journalRows(batchID: plan.batchID).count == 2)
        // Handled once each means both landed and neither stayed.
        #expect(try bytes(destination.appendingPathComponent("IMG_0003.CR2")) == 40)
        #expect(try bytes(destination.appendingPathComponent("IMG_0003.jpg")) == 30)
        #expect(!exists(raw))
        #expect(!exists(jpeg))
    }

    /// **A companion whose own destination collides is a collision on the
    /// parent item.** The set travels together, so it is resolved together —
    /// and the rename suffix goes on the basename, keeping the pair matched.
    @Test func aCompanionCollisionIsACollisionOnTheItem() async throws {
        let raw = try tree.file("from/IMG_0001.CR2", bytes: 40)
        _ = try tree.file("from/IMG_0001.xmp", bytes: 5)
        let destination = try tree.directory("to")
        // Only the sidecar's name is taken in the destination.
        _ = try tree.file("to/IMG_0001.xmp", bytes: 99)
        let store = try IndexStore.inMemory()

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [raw], destination: destination)
        #expect(plan.items[0].collisions
                == [FileOperationCollision(
                    path: destination.appendingPathComponent("IMG_0001.xmp"),
                    kind: .occupied)])
        #expect(plan.hasUnresolvedCollisions)

        let results = try await op.execute(plan.resolvingAllCollisions(with: .rename))
        #expect(results[0].outcome == .completed)
        // One shared suffix, so the RAW and its sidecar stay matched even
        // though only the sidecar's name was taken.
        #expect(exists(destination.appendingPathComponent("IMG_0001 2.CR2")))
        #expect(exists(destination.appendingPathComponent("IMG_0001 2.xmp")))
        #expect(try bytes(destination.appendingPathComponent("IMG_0001.xmp")) == 99)
    }

    @Test func trashingTakesTheCompanionsToo() async throws {
        // Reaches the real Trash, so the fixture name must be unique to this
        // test run — see `TempTree.uniqueName`.
        let raw = try tree.file("lib/\(tree.uniqueName("IMG_0001", ext: "CR2"))", bytes: 40)
        let sidecar = try tree.file("lib/\(tree.uniqueName("IMG_0001", ext: "xmp"))", bytes: 5)
        let store = try IndexStore.inMemory()
        try index(raw, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .trash, sources: [raw], destination: nil)
        // Registered before the batch runs: see `emptyTrash` in
        // FileOperatorTests.swift for why cleanup must not depend on it
        // succeeding.
        defer {
            for row in (try? store.journalRows(batchID: plan.batchID)) ?? [] {
                row.trashURL.map { try? FileManager.default.removeItem(atPath: $0) }
            }
        }
        let results = try await op.execute(plan)
        let rows = try store.journalRows(batchID: plan.batchID)

        #expect(results[0].outcome == .completed)
        #expect(!exists(raw))
        #expect(!exists(sidecar))
        #expect(rows.count == 2)
        // Every row carries where its file went; that is what undo restores
        // from — so check each named file is really there.
        #expect(rows.allSatisfy { $0.state == .complete && $0.trashURL != nil })
        for row in rows {
            let url = try #require(row.trashURL)
            #expect(exists(URL(fileURLWithPath: url)))
        }
    }
}
