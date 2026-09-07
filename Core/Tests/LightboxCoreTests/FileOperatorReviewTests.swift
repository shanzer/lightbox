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

/// Removes anything a batch put in the Trash, read from the journal so cleanup
/// does not depend on the code under test succeeding.
private func emptyTrash(of store: IndexStore, batchID: String) {
    for row in (try? store.journalRows(batchID: batchID)) ?? [] {
        guard let path = row.trashURL else { continue }
        try? FileManager.default.removeItem(atPath: path)
    }
}

// MARK: - B1: an intra-batch collision is not something `replace` may replace

/// **The batch's own earlier photo is not "the existing file".**
///
/// Two same-named photos from two folders, moved into one destination with
/// "Replace, apply to all", is an ordinary gesture. The second item's
/// destination is occupied — but it is occupied by the *first item's photo*,
/// which landed a moment ago. Replacing it deletes a file the user just moved
/// and reports `complete` for both.
struct FileOperatorIntraBatchCollisionTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    @Test func replacingAnIntraBatchCollisionKeepsBothPhotos() async throws {
        let first = try tree.file("a/IMG_0001.jpg", bytes: 10)
        let second = try tree.file("b/IMG_0001.jpg", bytes: 20)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(first, into: store)
        try index(second, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [first, second],
                                     destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        let results = try await op.execute(plan.resolvingAllCollisions(with: .replace))
        #expect(results.allSatisfy { $0.outcome == .completed })

        // Neither photo may be destroyed. Nothing on disk was there to replace.
        let landed = try FileManager.default
            .contentsOfDirectory(atPath: destination.path).sorted()
        #expect(landed == ["IMG_0001 2.jpg", "IMG_0001.jpg"])
        #expect(try bytes(destination.appendingPathComponent("IMG_0001.jpg")) == 10)
        #expect(try bytes(destination.appendingPathComponent("IMG_0001 2.jpg")) == 20)
        #expect(try store.count() == 2)
    }

    @Test func copyingWithReplaceOverAnIntraBatchCollisionKeepsBothPhotos() async throws {
        let first = try tree.file("a/IMG_0001.jpg", bytes: 10)
        let second = try tree.file("b/IMG_0001.jpg", bytes: 20)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(first, into: store)
        try index(second, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .copy, sources: [first, second],
                                     destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        let results = try await op.execute(plan.resolvingAllCollisions(with: .replace))
        #expect(results.allSatisfy { $0.outcome == .completed })
        #expect(try bytes(destination.appendingPathComponent("IMG_0001.jpg")) == 10)
        #expect(try bytes(destination.appendingPathComponent("IMG_0001 2.jpg")) == 20)
        #expect(try store.count() == 4)
    }

    /// The sheet must be able to say something true. "Already exists at the
    /// destination" is false for a path nothing occupies yet, and the two cases
    /// offer different choices — there is nothing to replace in one of them.
    @Test func theCollisionSaysWhetherItIsOnDiskOrFromThisBatch() async throws {
        let first = try tree.file("a/IMG_0001.jpg", bytes: 10)
        let second = try tree.file("b/IMG_0001.jpg", bytes: 20)
        let third = try tree.file("c/IMG_0002.jpg", bytes: 30)
        let destination = try tree.directory("to")
        _ = try tree.file("to/IMG_0002.jpg", bytes: 99)
        let store = try IndexStore.inMemory()

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [first, second, third],
                                     destination: destination)
        #expect(plan.items[0].collisions.isEmpty)
        #expect(plan.items[1].collisions.map(\.kind) == [.claimedInBatch])
        #expect(plan.items[2].collisions.map(\.kind) == [.occupied])

        // `replace` is honoured where there is something on disk to replace and
        // degraded where there is not. The item records both, so the sheet can
        // explain itself.
        let resolved = plan.resolvingAllCollisions(with: .replace)
        #expect(resolved.items[1].resolution == .replace)
        #expect(resolved.items[1].effectiveResolution == .rename)
        #expect(resolved.items[2].effectiveResolution == .replace)
    }
}

// MARK: - B3/B4: a trash or delete that fails keeps its row

/// Nothing may remove an index row before the filesystem operation that
/// removes the file has been confirmed. Until these tests existed the whole
/// suite stayed green with the `.remove` mutations built *before* `trashItem`
/// and returned even on failure — a row deleted for a photo still on disk.
struct FileOperatorRemovalFailureTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    @Test func trashingASourceThatVanishedKeepsTheRowAndNamesTheReason() async throws {
        let source = try tree.file("lib/IMG_0001.jpg", bytes: 32)
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .trash, sources: [source], destination: nil)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        try FileManager.default.removeItem(at: source)

        let results = try await op.execute(plan)
        // `trashItem` reports through `NSOSStatusErrorDomain`, never POSIX, so
        // this is `.other` unless the Cocoa and OSStatus codes are mapped.
        #expect(results[0].outcome == .failed(.sourceVanished))
        #expect(try store.record(atPath: source.path) != nil)
        #expect(try store.journalRows(batchID: plan.batchID).map(\.state) == [.failed])
    }

    @Test func trashingFromALockedFolderKeepsTheRowAndTheFile() async throws {
        let source = try tree.file("locked/IMG_0001.jpg", bytes: 32)
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .trash, sources: [source], destination: nil)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        try tree.chmod("locked", 0o500)

        let results = try await op.execute(plan)
        #expect(results[0].outcome == .failed(.permissionDenied))
        #expect(exists(source))
        #expect(try store.record(atPath: source.path) != nil)
        #expect(try store.journalRows(batchID: plan.batchID).map(\.state) == [.failed])
    }

    @Test func deletingFromALockedFolderKeepsTheRowAndTheFile() async throws {
        let source = try tree.file("locked/IMG_0001.jpg", bytes: 32)
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .delete, sources: [source], destination: nil)
        try tree.chmod("locked", 0o500)

        let results = try await op.execute(plan)
        #expect(results[0].outcome == .failed(.permissionDenied))
        #expect(exists(source))
        #expect(try store.record(atPath: source.path) != nil)
        #expect(try store.journalRows(batchID: plan.batchID).map(\.state) == [.failed])
    }

    @Test func deletingASourceThatVanishedKeepsTheRow() async throws {
        let source = try tree.file("lib/IMG_0001.jpg", bytes: 32)
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .delete, sources: [source], destination: nil)
        try FileManager.default.removeItem(at: source)

        let results = try await op.execute(plan)
        #expect(results[0].outcome == .failed(.sourceVanished))
        #expect(try store.record(atPath: source.path) != nil)
        #expect(try store.journalRows(batchID: plan.batchID).map(\.state) == [.failed])
    }
}

// MARK: - B2/B5/B6: the aside is journalled, and a rollback that fails says so

/// `replace` moves a photo the user did not select. That is a filesystem
/// mutation like any other and it gets a journal row like any other — written
/// before the file is touched, naming the stash the photo waits in, so that a
/// crash in the window between the aside and the disposal leaves a record
/// rather than an unreferenced dot-file whose index row the next tier 0 pass
/// prunes.
struct FileOperatorReplacementJournalTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    @Test func aSuccessfulReplaceJournalsTheDisplacedFileIntoTheTrash() async throws {
        let source = try tree.file("a/IMG_0001.jpg", bytes: 20)
        let destination = try tree.directory("to")
        let occupant = try tree.file("to/IMG_0001.jpg", bytes: 10)
        let store = try IndexStore.inMemory()
        try index(source, into: store)
        try index(occupant, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [source], destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        let resolved = plan.resolvingAllCollisions(with: .replace)
        #expect(resolved.items[0].replacements.map(\.occupant) == [occupant])

        let results = try await op.execute(resolved)
        #expect(results[0].outcome == .completed)
        #expect(try bytes(occupant) == 20)

        let rows = try store.journalRows(batchID: plan.batchID)
        let aside = try #require(rows.first { $0.kind == .trash })
        #expect(aside.src == occupant.path)
        #expect(aside.dst == resolved.items[0].replacements[0].stash.path)
        #expect(aside.state == .complete)
        // The displaced photo is recoverable: `replace` is as undoable as any
        // other removal, which it is not if the occupant is simply unlinked.
        let trashed = try #require(aside.trashURL)
        #expect(exists(URL(fileURLWithPath: trashed)))
        #expect(try bytes(URL(fileURLWithPath: trashed)) == 10)
        // No stash left in the folder, and the displaced row retired.
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path)
                == ["IMG_0001.jpg"])
        #expect(try store.count() == 1)
    }

    /// The crash shape, staged: the item fails, and then the rollback that
    /// should have undone it fails too. Nothing may claim `failed` — which is
    /// defined as "nothing changed" and which the reconcile is built never to
    /// re-examine — so the rows stay `in_flight` and the aside row's `dst` is
    /// what leads a reader to the displaced photo.
    @Test func aRollbackThatCannotUndoLeavesTheRowsInFlightAndNamesTheStash() async throws {
        let raw = try tree.file("from/IMG_0001.CR2", bytes: 48)
        _ = try tree.file("from/IMG_0001.xmp", bytes: 6)
        let destination = try tree.directory("to")
        let occupant = try tree.file("to/IMG_0001.CR2", bytes: 11)
        let store = try IndexStore.inMemory()
        try index(raw, into: store)
        try index(occupant, into: store)
        // Registered so TempTree restores the mode and can remove the tree.
        try tree.chmod("to", 0o755)

        let destinationPath = destination.path
        let op = FileOperator(store: store, volumeReader: { url in
            VolumeIdentity(device: url.path.hasSuffix("/to") ? 2 : 1,
                           uuid: url.path.hasSuffix("/to") ? "VOL-B" : "VOL-A")
        }, copier: { source, target, _ in
            guard source.pathExtension != "xmp" else {
                // Slam the destination shut on the way out, so the rollback of
                // the RAW that already landed cannot remove it.
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o500)], ofItemAtPath: destinationPath)
                throw POSIXError(.ENOSPC)
            }
            try FileManager.default.copyItem(at: source, to: target)
        })
        let plan = try await op.plan(kind: .move, sources: [raw], destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        let resolved = plan.resolvingAllCollisions(with: .replace)
        let stash = resolved.items[0].replacements[0].stash

        let results = try await op.execute(resolved)
        guard case .failed(.rollbackIncomplete(let detail)) = results[0].outcome else {
            Issue.record("expected .rollbackIncomplete, got \(results[0].outcome)")
            return
        }
        #expect(detail.contains("IMG_0001.CR2"))

        // Every row of the item, and the aside, stays `in_flight`: the operator
        // does not know what is where, and `in_flight` is how it says so.
        let rows = try store.journalRows(batchID: plan.batchID)
        #expect(rows.allSatisfy { $0.state == .inFlight })
        let aside = try #require(rows.first { $0.src == occupant.path })
        #expect(aside.dst == stash.path)
        // And the displaced photo really is at the path that row names. Without
        // the aside row it would be an unreferenced dot-file.
        #expect(exists(stash))
        #expect(try bytes(stash) == 11)
        #expect(try store.record(atPath: occupant.path) != nil)

        try tree.chmod("to", 0o755)
    }
}

// MARK: - B7: the source volume's identity, not merely its presence

struct FileOperatorSourceVolumeTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// Presence is not identity. The source directory still exists and still
    /// answers; it is a *different filesystem*, which is what a replug or a
    /// remount of something else at the same path looks like. Everything after
    /// the swap is skipped rather than attempted — and for `trash` and `delete`
    /// especially, since attempting there destroys whatever has arrived.
    @Test func aSourceVolumeThatChangesIdentityMidBatchSkipsTheRest() async throws {
        let sources = try (0..<4).map { try tree.file("from/IMG_000\($0).jpg", bytes: 16) }
        let store = try IndexStore.inMemory()
        for source in sources { try index(source, into: store) }

        let swapped = LockBox(false)
        let op = FileOperator(store: store, volumeReader: { _ in
            VolumeIdentity(device: 1, uuid: swapped.withLock { $0 } ? "VOL-Z" : "VOL-A")
        })
        let plan = try await op.plan(kind: .delete, sources: sources, destination: nil)
        let results = try await op.execute(plan) { completed, _, _ in
            if completed == 1 { swapped.withLock { $0 = true } }
        }

        #expect(results[0].outcome == .completed)
        #expect(results.dropFirst().allSatisfy { $0.outcome == .skipped(.volumeUnmounted) })
        for source in sources.dropFirst() { #expect(exists(source)) }
        #expect(try store.count() == 3)
        let rows = try store.journalRows(batchID: plan.batchID)
        #expect(rows.filter { $0.state == .skipped }.count == 3)
    }
}

// MARK: - B8: where a photo went is recorded the moment it goes

struct FileOperatorTrashURLTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// The Trash renames on collision, so the resulting path is not derivable
    /// from the original. Between `trashItem` returning and the item's index
    /// transaction committing it is the only record there is — and an item that
    /// then fails discards its in-memory results entirely. Writing it in its own
    /// transaction the moment it is known is what keeps a photo findable.
    @Test func trashURLIsRecordedEvenForAnItemThatThenFails() async throws {
        let raw = try tree.file("lib/IMG_0001.CR2", bytes: 40)
        let sidecar = try tree.file("lib/IMG_0001.xmp", bytes: 6)
        let store = try IndexStore.inMemory()
        try index(raw, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .trash, sources: [raw], destination: nil)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        #expect(plan.items[0].companions == [sidecar])
        // The sidecar vanishes, so the item fails after the RAW has already
        // gone to the Trash and is then restored.
        try FileManager.default.removeItem(at: sidecar)

        let results = try await op.execute(plan)
        #expect(results[0].outcome == .failed(.sourceVanished))
        #expect(exists(raw))
        #expect(try store.record(atPath: raw.path) != nil)

        let rows = try store.journalRows(batchID: plan.batchID)
        let rawRow = try #require(rows.first { $0.src == raw.path })
        #expect(rawRow.state == .failed)
        // `failed` means nothing changed, and it does not: the file is back.
        // The URL is the forensic record of where it briefly went, written at
        // the one moment it could have been lost.
        #expect(rawRow.trashURL != nil)
    }
}

// MARK: - B9: the displaced file is named exactly, case included

struct FileOperatorReplaceCaseTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// Occupancy is decided case-insensitively because the volume is, but the
    /// row lookup is exact. A `replace` over a destination whose name differs
    /// only in case must still retire the displaced file's row, or the index
    /// keeps an entry carrying a dead photo's `content_hash` in the table
    /// duplicate detection reads.
    @Test func replacingAFileWhoseNameDiffersOnlyInCaseRetiresItsRow() async throws {
        let source = try tree.file("a/IMG_0001.jpg", bytes: 20)
        let destination = try tree.directory("to")
        let occupant = try tree.file("to/img_0001.JPG", bytes: 10)
        let store = try IndexStore.inMemory()
        try index(source, into: store)
        let occupantID = try index(occupant, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [source], destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        // The collision names the file as it really is, not as the source is.
        #expect(plan.items[0].collisions.map(\.path.lastPathComponent) == ["img_0001.JPG"])

        let results = try await op.execute(plan.resolvingAllCollisions(with: .replace))
        #expect(results[0].outcome == .completed)
        #expect(try store.count() == 1)
        let survivor = try #require(try store.search(SearchQuery(
            scope: .folder(path: destination.path, recursive: false))).first)
        #expect(survivor.id != occupantID)
        #expect(survivor.contentHash == "hash-IMG_0001.jpg")
    }
}

// MARK: - B6: putting a displaced file back never deletes what is in its place

struct FileOperatorRestoreGuardTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// The loss this guard prevents: a same-volume move displaces the occupant,
    /// the item then fails, and the rollback that should have moved the photo
    /// back out of the destination fails too. Whatever is at the occupant's path
    /// now is the user's photo — its source is gone, it *was* the rename — and
    /// deleting it to make room for the stash destroys the only copy.
    @Test func restoreRefusesRatherThanDeletingWhatIsAtTheOriginalPath() throws {
        let occupied = try tree.file("to/IMG_0001.jpg", bytes: 77)
        let stash = try tree.file("to/.lightbox-replaced-abc-0-0", bytes: 10)
        let staged = StagedReplacement(
            replacement: PlannedReplacement(occupant: occupied, stash: stash),
            opID: 1, staged: true)

        let problems = FileOperator.restore([staged], rollbackSucceeded: false)
        #expect(problems.count == 1)
        // `first`, not `[0]`: a subscript here traps rather than fails, and a
        // test that crashes the process takes the rest of the suite's output
        // with it — which is exactly how a surviving mutation looks like a
        // passing one.
        #expect(problems.first?.contains("IMG_0001.jpg") == true)
        // The user's photo is untouched and the displaced one is still where the
        // journal says it is.
        #expect(try bytes(occupied) == 77)
        #expect(try bytes(stash) == 10)
    }

    /// The ordinary path still works: with the original path clear, the
    /// displaced file goes back to it.
    @Test func restorePutsTheDisplacedFileBackWhenThePathIsClear() throws {
        let destination = try tree.directory("to")
        let occupant = destination.appendingPathComponent("IMG_0001.jpg")
        let stash = try tree.file("to/.lightbox-replaced-abc-0-0", bytes: 10)
        let staged = StagedReplacement(
            replacement: PlannedReplacement(occupant: occupant, stash: stash),
            opID: 1, staged: true)

        let problems = FileOperator.restore([staged], rollbackSucceeded: true)
        #expect(problems.isEmpty)
        #expect(try bytes(occupant) == 10)
        #expect(!exists(stash))
    }
}

// MARK: - B1: a file the batch itself selected is never displaced

struct FileOperatorReplaceBackstopTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// Select a photo that is already in the target folder, plus a same-named
    /// one elsewhere, and move both there with Replace.
    ///
    /// The naive reading is that the second item collides with a real file on
    /// disk and may displace it. It may not: that file is the *first item's
    /// source*, which the user also selected, and the first item claims its own
    /// name the moment it is planned. So the collision is `claimedInBatch`,
    /// `replace` degrades, and both photos survive — which is the whole point of
    /// tracking where a claim came from rather than only that there is one.
    @Test func replaceOverAFileThisBatchSelectedKeepsBothPhotos() async throws {
        let destination = try tree.directory("to")
        let alreadyThere = try tree.file("to/IMG_0001.jpg", bytes: 77)
        let incoming = try tree.file("a/IMG_0001.jpg", bytes: 20)
        let store = try IndexStore.inMemory()
        try index(alreadyThere, into: store)
        try index(incoming, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [alreadyThere, incoming],
                                     destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        #expect(plan.items[0].collisions.isEmpty)
        #expect(plan.items[1].collisions.map(\.kind) == [.claimedInBatch])

        let results = try await op.execute(plan.resolvingAllCollisions(with: .replace))
        #expect(results[0].outcome == .skipped(.alreadyAtDestination))
        #expect(results[1].outcome == .completed)
        #expect(try bytes(alreadyThere) == 77)
        #expect(try bytes(destination.appendingPathComponent("IMG_0001 2.jpg")) == 20)
        #expect(try store.count() == 2)
    }
}

// MARK: - C1/I1: a vanished occupant settles its own row and retires its own row

/// The occupant of a `replace` can go away in the same plan/execute gap the
/// design already documents for sources. Staging then skips it, so the staged
/// list is a *subset* of the replacements — and anything that pairs the two by
/// position afterwards attributes every row past the gap to the wrong file.
struct FileOperatorVanishedOccupantTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// Two occupants, the **first** of which vanishes. Observed before the fix:
    /// the row for the file that was never trashed carried a Trash URL holding
    /// the *other* file's bytes, and the file that really was trashed kept no
    /// record at all. #6 reading that would have written the sidecar's bytes
    /// over the RAW's path.
    @Test func asideRowsAreNeverAttributedToAnotherFile() async throws {
        let raw = try tree.file("from/IMG_0001.CR2", bytes: 48)
        _ = try tree.file("from/IMG_0001.xmp", bytes: 6)
        let destination = try tree.directory("to")
        let occupantRaw = try tree.file("to/IMG_0001.CR2", bytes: 11)
        let occupantXmp = try tree.file("to/IMG_0001.xmp", bytes: 12)
        let store = try IndexStore.inMemory()
        try index(raw, into: store)
        try index(occupantRaw, into: store)
        try index(occupantXmp, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [raw], destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        let resolved = plan.resolvingAllCollisions(with: .replace)
        #expect(resolved.items[0].replacements.count == 2)
        try FileManager.default.removeItem(at: occupantRaw)

        let results = try await op.execute(resolved)
        #expect(results[0].outcome == .completed)

        let rows = try store.journalRows(batchID: plan.batchID)
        let rawAside = try #require(rows.first { $0.kind == .trash && $0.src == occupantRaw.path })
        let xmpAside = try #require(rows.first { $0.kind == .trash && $0.src == occupantXmp.path })
        // The file that was never trashed names no Trash URL and is terminal:
        // it was not displaced, and nothing about it changed.
        #expect(rawAside.trashURL == nil)
        #expect(rawAside.state == .failed)
        // The file that *was* trashed says so, and says where.
        #expect(xmpAside.state == .complete)
        let trashed = try #require(xmpAside.trashURL)
        // The bytes at that URL are the ones that row is about, which is the
        // whole failure: 12 was the xmp's, 11 the RAW's.
        #expect(try bytes(URL(fileURLWithPath: trashed)) == 12)
    }

    /// The index twin. A vanished occupant's row still names the exact path the
    /// move is about to write, so leaving it turns a move that fully succeeded
    /// on disk into `indexWriteFailed(UNIQUE files.path)` with two stale rows —
    /// one carrying a dead photo's `content_hash` at a path now holding
    /// different bytes.
    @Test func aVanishedOccupantsStaleRowIsRetiredSoTheMoveLands() async throws {
        let source = try tree.file("a/IMG_0001.jpg", bytes: 20)
        let destination = try tree.directory("to")
        let occupant = try tree.file("to/IMG_0001.jpg", bytes: 10)
        let store = try IndexStore.inMemory()
        try index(source, into: store)
        try index(occupant, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [source], destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        let resolved = plan.resolvingAllCollisions(with: .replace)
        try FileManager.default.removeItem(at: occupant)

        let results = try await op.execute(resolved)
        #expect(results[0].outcome == .completed)
        #expect(try bytes(occupant) == 20)
        #expect(!exists(source))

        #expect(try store.count() == 1)
        let row = try #require(try store.record(atPath: occupant.path))
        #expect(row.contentHash == "hash-IMG_0001.jpg")
        let rows = try store.journalRows(batchID: plan.batchID)
        #expect(rows.first { $0.kind == .move }?.state == .complete)
        #expect(rows.first { $0.kind == .trash }?.state == .failed)
    }
}

// MARK: - I2: marks already earned are never discarded

struct FileOperatorDisposalMarkTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// A displaced file that has already reached the Trash must keep its row,
    /// even when a *later* replacement's disposal fails and the item is
    /// abandoned. Dropping the mark leaves that photo in the Trash under a row
    /// naming nothing, and the Trash renames on collision, so nothing derives
    /// the path.
    @Test func aFailedDisposalStillWritesTheMarksItAlreadyEarned() async throws {
        let raw = try tree.file("from/IMG_0001.CR2", bytes: 48)
        _ = try tree.file("from/IMG_0001.xmp", bytes: 6)
        let destination = try tree.directory("to")
        let occupantRaw = try tree.file("to/IMG_0001.CR2", bytes: 11)
        let occupantXmp = try tree.file("to/IMG_0001.xmp", bytes: 12)
        let store = try IndexStore.inMemory()
        try index(raw, into: store)

        // The stash paths are deterministic, so the second one can be removed
        // between the transfer and the disposal — the shape of a crash in that
        // window, and the only seam that reaches it.
        let stashBox = LockBox<URL?>(nil)
        let op = FileOperator(store: store, volumeReader: { url in
            VolumeIdentity(device: url.path.hasSuffix("/to") ? 2 : 1,
                           uuid: url.path.hasSuffix("/to") ? "VOL-B" : "VOL-A")
        }, copier: { source, target, _ in
            try FileManager.default.copyItem(at: source, to: target)
            if source.pathExtension == "xmp", let doomed = stashBox.withLock({ $0 }) {
                try? FileManager.default.removeItem(at: doomed)
            }
        })
        let plan = try await op.plan(kind: .move, sources: [raw], destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        let resolved = plan.resolvingAllCollisions(with: .replace)
        #expect(resolved.items[0].replacements.count == 2)
        stashBox.withLock { $0 = resolved.items[0].replacements[1].stash }

        let results = try await op.execute(resolved)
        guard case .failed(.rollbackIncomplete) = results[0].outcome else {
            Issue.record("expected .rollbackIncomplete, got \(results[0].outcome)")
            return
        }

        let rows = try store.journalRows(batchID: plan.batchID)
        // The first occupant really did reach the Trash. Its row says so and
        // names where, despite the item as a whole being abandoned.
        let rawAside = try #require(rows.first { $0.src == occupantRaw.path })
        #expect(rawAside.state == .complete)
        let trashed = try #require(rawAside.trashURL)
        #expect(try bytes(URL(fileURLWithPath: trashed)) == 11)
        // The second's fate is genuinely unknown, and the item's own rows with
        // it: `in_flight` is how that is said.
        #expect(rows.first { $0.src == occupantXmp.path }?.state == .inFlight)
        #expect(rows.filter { $0.kind == .move }.allSatisfy { $0.state == .inFlight })
    }
}

// MARK: - I3: the last swallowed failures

struct FileOperatorSwallowedFailureTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// A partial copy that cannot be cleared is not "nothing changed". Before
    /// this, the `try?` left a half-written file at the destination under a row
    /// saying `failed` — the state the reconcile is defined never to re-examine.
    @Test func aPartialCopyThatCannotBeClearedIsReportedNotSwallowed() async throws {
        let source = try tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try tree.directory("to")
        try tree.chmod("to", 0o755)
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let destinationPath = destination.path
        let op = FileOperator(store: store, copier: { source, target, _ in
            // Write half the bytes, seal the directory, then fail: the partial
            // file is now unremovable.
            let data = try Data(contentsOf: source)
            try data.prefix(data.count / 2).write(to: target)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o500)], ofItemAtPath: destinationPath)
            throw POSIXError(.ENOSPC)
        })
        let plan = try await op.plan(kind: .copy, sources: [source], destination: destination)
        let results = try await op.execute(plan)

        guard case .failed(.rollbackIncomplete(let detail)) = results[0].outcome else {
            Issue.record("expected .rollbackIncomplete, got \(results[0].outcome)")
            return
        }
        #expect(detail.contains("IMG_0001.jpg"))
        // Rows stay `in_flight`, because something really is at the destination.
        #expect(try store.journalRows(batchID: plan.batchID).map(\.state) == [.inFlight])
        try tree.chmod("to", 0o755)
    }

    /// Staging that cannot complete puts back what it staged and reports.
    /// Occupying the second replacement's stash path with a directory makes its
    /// aside fail after the first has already been moved aside.
    @Test func stagingThatFailsPartWayPutsBackWhatItAlreadyMoved() async throws {
        let raw = try tree.file("from/IMG_0001.CR2", bytes: 48)
        _ = try tree.file("from/IMG_0001.xmp", bytes: 6)
        let destination = try tree.directory("to")
        let occupantRaw = try tree.file("to/IMG_0001.CR2", bytes: 11)
        let occupantXmp = try tree.file("to/IMG_0001.xmp", bytes: 12)
        let store = try IndexStore.inMemory()
        try index(raw, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [raw], destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        let resolved = plan.resolvingAllCollisions(with: .replace)
        // A directory where the second stash wants to go.
        try FileManager.default.createDirectory(
            at: resolved.items[0].replacements[1].stash, withIntermediateDirectories: true)

        let results = try await op.execute(resolved)
        guard case .failed = results[0].outcome else {
            Issue.record("expected a failure, got \(results[0].outcome)")
            return
        }
        // Both occupants are back where they were, and the sources never moved.
        #expect(try bytes(occupantRaw) == 11)
        #expect(try bytes(occupantXmp) == 12)
        #expect(try bytes(raw) == 48)
        #expect(try store.journalRows(batchID: plan.batchID)
                .allSatisfy { $0.state == .failed })
    }

    /// A source directory that cannot be listed is not an empty one. Treating it
    /// as empty moves the RAW and orphans the `.xmp` — silently.
    @Test func aSourceDirectoryThatCannotBeListedFailsThePlan() async throws {
        let source = try tree.file("from/IMG_0001.CR2", bytes: 48)
        _ = try tree.file("from/IMG_0001.xmp", bytes: 6)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        let directory = try tree.chmod("from", 0o300)

        let op = FileOperator(store: store)
        await #expect(throws: FileOperatorError.sourceDirectoryUnreadable(directory.path)) {
            _ = try await op.plan(kind: .move, sources: [source], destination: destination)
        }
        // With companions off there is nothing to list, so the plan stands.
        let plan = try await op.plan(kind: .move, sources: [source],
                                     destination: destination, includeCompanions: false)
        #expect(plan.items.count == 1)
        try tree.chmod("from", 0o755)
    }
}
