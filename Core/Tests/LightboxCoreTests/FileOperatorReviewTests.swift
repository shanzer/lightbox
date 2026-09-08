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
        // A copy leaves its sources alone.
        #expect(try bytes(first) == 10)
        #expect(try bytes(second) == 20)
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
        // The sources never moved — this failed before the removal loop — and
        // the RAW's copy is still at the destination, which is what the
        // `in_flight` rows claim.
        #expect(try bytes(raw) == 48)
        #expect(try bytes(tree.root.appendingPathComponent("from/IMG_0001.xmp")) == 6)
        #expect(try bytes(destination.appendingPathComponent("IMG_0001.CR2")) == 48)

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
        // `failed` means the file came back, so the Trash URL must now name
        // nothing: it is a record of where it briefly was, not where it is.
        #expect(!exists(URL(fileURLWithPath: try #require(rawRow.trashURL))))
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

        // Where the bytes actually are: the source moved, the destination holds
        // it, the displaced file is recoverable from the Trash, and no stash is
        // left in the folder.
        #expect(!exists(source))
        #expect(try bytes(occupant) == 20)
        let rows = try store.journalRows(batchID: plan.batchID)
        let asideURL = try #require(rows.first { $0.kind == .trash }?.trashURL)
        #expect(try bytes(URL(fileURLWithPath: asideURL)) == 10)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path)
                .filter { $0.hasPrefix(".lightbox-replaced-") }.isEmpty)
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
        // Both files really moved.
        #expect(try bytes(destination.appendingPathComponent("IMG_0001.CR2")) == 48)
        #expect(try bytes(destination.appendingPathComponent("IMG_0001.xmp")) == 6)
        #expect(!exists(raw))
        #expect(!exists(tree.root.appendingPathComponent("from/IMG_0001.xmp")))
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

        // **The photo must still exist somewhere.** A cross-volume move unlinks
        // its sources before the displaced files are disposed of, so an undo
        // that removes the copies at that point removes the only remaining
        // copy: source gone, destination gone, journal row `in_flight` naming
        // two paths that hold nothing.
        for name in ["IMG_0001.CR2", "IMG_0001.xmp"] {
            let atSource = tree.root.appendingPathComponent("from/\(name)")
            let atDestination = destination.appendingPathComponent(name)
            #expect(exists(atSource) || exists(atDestination),
                    "\(name) exists at neither its source nor its destination")
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
        // Rows stay `in_flight` because something really is at the destination —
        // so assert that it really is, and that the source is untouched. An
        // `in_flight` row over an empty destination would be the opposite bug.
        #expect(exists(source))
        #expect(try bytes(source) == 64)
        #expect(exists(destination.appendingPathComponent("IMG_0001.jpg")))
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

// MARK: - A cross-volume move must never lose its only copy

/// A cross-volume move is a copy followed by unlinking the sources. Once those
/// sources are gone the copies at the destination are **the only copies**, and
/// nothing downstream may treat them as undoable work.
///
/// The route is ordinary: the app's whole reason to exist is a library on an
/// external drive, so a move off that drive is cross-volume by default. The
/// disposal that fails needs only a destination volume that cannot make a
/// `.Trashes` — exFAT, an SMB share, a folder the user cannot write — or a
/// `trashItem` that returns no URL, or a `SQLITE_BUSY` on the journal write.
struct FileOperatorCrossVolumeLossTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    @Test func aCrossVolumeMoveKeepsItsOnlyCopyWhenDisposalFails() async throws {
        let source = try tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try tree.directory("to")
        let occupant = try tree.file("to/IMG_0001.jpg", bytes: 11)
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        // Two volumes over one real tree, so the cross-volume branch runs for
        // real; the stash is removed between the copy and the disposal, which is
        // the shape of every way disposal fails.
        let stashBox = LockBox<URL?>(nil)
        let op = FileOperator(store: store, volumeReader: { url in
            VolumeIdentity(device: url.path.hasSuffix("/to") ? 2 : 1,
                           uuid: url.path.hasSuffix("/to") ? "VOL-B" : "VOL-A")
        }, copier: { source, target, _ in
            try FileManager.default.copyItem(at: source, to: target)
            if let doomed = stashBox.withLock({ $0 }) {
                try? FileManager.default.removeItem(at: doomed)
            }
        })
        let plan = try await op.plan(kind: .move, sources: [source], destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        let resolved = plan.resolvingAllCollisions(with: .replace)
        stashBox.withLock { $0 = resolved.items[0].replacements[0].stash }

        let results = try await op.execute(resolved)
        guard case .failed(.rollbackIncomplete(let detail)) = results[0].outcome else {
            Issue.record("expected .rollbackIncomplete, got \(results[0].outcome)")
            return
        }
        // The user's photo is somewhere. That is the whole assertion.
        #expect(exists(destination.appendingPathComponent("IMG_0001.jpg")))
        #expect(try bytes(destination.appendingPathComponent("IMG_0001.jpg")) == 64)
        // What actually saves the photo on *this* path is the `stat` inside
        // `rollbackMoves`: the disposal failure reaches `abandon` directly, so
        // `TransferState.sourcesRemoved` is not consulted here. The flag governs
        // the other path — a source-removal failure part way through the unlink
        // loop — and that has its own test. Both are asserted rather than
        // assumed, because a redundant guard nothing exercises is one that gets
        // deleted as dead.
        #expect(detail.contains("the originals are gone"))
        #expect(detail.contains(destination.path))
        // Rows stay `in_flight` carrying both paths — the copy-landed,
        // source-gone shape #6 already has to handle.
        let rows = try store.journalRows(batchID: plan.batchID)
        let move = try #require(rows.first { $0.kind == .move })
        #expect(move.state == .inFlight)
        #expect(move.src == source.path)
        #expect(move.dst == destination.appendingPathComponent("IMG_0001.jpg").path)
        #expect(occupant.lastPathComponent == "IMG_0001.jpg")
    }

    /// The structural backstop, tested where it lives: a non-rename rollback
    /// removes a destination copy only while the source it came from is still
    /// there. Once the source is gone the copy is the only copy, and removing it
    /// is the loss, not the undo.
    @Test func rollbackRefusesToRemoveACopyWhoseSourceIsGone() throws {
        let destination = try tree.file("to/IMG_0001.jpg", bytes: 64)
        let vanished = tree.root.appendingPathComponent("from/IMG_0001.jpg")

        let problems = FileOperator.rollbackMoves(
            [.init(from: vanished, to: destination, sourceFacts: nil)], byRename: false)
        #expect(problems.count == 1)
        #expect(problems.first?.contains("IMG_0001.jpg") == true)
        #expect(exists(destination))
        #expect(try bytes(destination) == 64)
    }
}

// MARK: - I-A: `replace` never displaces a file this batch itself selected

/// The plan's `claimedInBatch` rule handles the collisions a batch creates by
/// *landing* a file somewhere. It does not handle the two cases where a batch
/// collides with a file it merely **selected**, and in both of those the naive
/// answer displaces one of the user's own chosen photos while reporting success.
///
/// Both are reachable with ordinary gestures, and the execute-time
/// `batchSources` guard is the only thing that catches either.
struct FileOperatorSelectedSourceReplaceTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// Copy a selection into a folder where one of the selected files already
    /// lives, Replace, apply to all.
    ///
    /// `ownNames` — which excuses a file from colliding with itself — applies to
    /// `move` only, and rightly: copying `to/IMG_0001.jpg` into `to/` *does*
    /// meet an existing file, and Finder's answer is `IMG_0001 2.jpg`. So the
    /// collision is real and `replace` is the wrong resolution for it, because
    /// the "existing file" is the very file being copied. Without the guard the
    /// source is moved into the stash and the copy then reports
    /// `sourceVanished`.
    @Test func copyingAFileIntoItsOwnFolderWithReplaceIsRefusedNotSelfDestroyed() async throws {
        let destination = try tree.directory("to")
        let inPlace = try tree.file("to/IMG_0001.jpg", bytes: 77)
        let other = try tree.file("a/IMG_0002.jpg", bytes: 20)
        let store = try IndexStore.inMemory()
        try index(inPlace, into: store)
        try index(other, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .copy, sources: [inPlace, other],
                                     destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        // A copy meets itself as an ordinary occupant; nothing excuses it.
        #expect(plan.items[0].collisions.map(\.kind) == [.occupied])

        let results = try await op.execute(plan.resolvingAllCollisions(with: .replace))
        #expect(results[0].outcome == .failed(.destinationNotReplaceable))
        #expect(results[1].outcome == .completed)
        // The selected file is still there, at full size, and still indexed —
        // and nothing was left set aside.
        #expect(try bytes(inPlace) == 77)
        #expect(try store.record(atPath: inPlace.path) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path)
                .filter { $0.hasPrefix(".lightbox-replaced-") }.isEmpty)
        #expect(try bytes(destination.appendingPathComponent("IMG_0002.jpg")) == 20)
    }

    /// Item 0 resolved `skip` claims no name, so item 1 meets item 0's *source*
    /// as an ordinary on-disk occupant. Without the guard item 0's selected
    /// photo is trashed, item 1 is written over it, and the batch reports
    /// `completed`.
    @Test func replaceOverASkippedItemsSourceIsRefused() async throws {
        let destination = try tree.directory("to")
        let selectedInPlace = try tree.file("to/IMG_0001.jpg", bytes: 77)
        let incoming = try tree.file("a/IMG_0001.jpg", bytes: 20)
        let store = try IndexStore.inMemory()
        try index(selectedInPlace, into: store)
        try index(incoming, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .copy, sources: [selectedInPlace, incoming],
                                     destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        // Item 0 skips, so it claims nothing; item 1 then sees a real file on
        // disk rather than a claim from the batch.
        let resolved = plan
            .resolvingCollision(at: 0, with: .skip)
            .resolvingCollision(at: 1, with: .replace)
        #expect(resolved.items[1].collisions.map(\.kind) == [.occupied])
        #expect(resolved.items[1].effectiveResolution == .replace)

        let results = try await op.execute(resolved)
        #expect(results[0].outcome == .skipped(.collisionResolved))
        #expect(results[1].outcome == .failed(.destinationNotReplaceable))
        #expect(try bytes(selectedInPlace) == 77)
        #expect(try bytes(incoming) == 20)
        #expect(try store.count() == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path)
                .filter { $0.hasPrefix(".lightbox-replaced-") }.isEmpty)
    }
}

// MARK: - C1: the cleanup may only remove what this attempt created

/// `copyfileCopy` passes `COPYFILE_EXCL`, so a destination that is occupied
/// makes the copy fail with `EEXIST` — and a destination can become occupied
/// between the plan and the batch, which is the same gap the design already
/// documents for sources. The catch then saw a file at the destination and
/// removed it. **It was not a partial copy; it was somebody's photo, arrived a
/// second ago, and it was unlinked rather than trashed** under a row saying
/// `failed`, which means nothing changed.
struct FileOperatorGapArrivalTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    @Test func aFileArrivingAtTheDestinationInTheGapIsNeverDeleted() async throws {
        let source = try tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .copy, sources: [source], destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        #expect(plan.items[0].collisions.isEmpty)
        // Somebody else puts a file there after the plan was made.
        let newcomer = try tree.file("to/IMG_0001.jpg", bytes: 99)

        let results = try await op.execute(plan)
        // Refused, and named as what it is: there is a file there and this batch
        // was never told it could displace it.
        #expect(results[0].outcome == .failed(.destinationNotReplaceable))
        // The newcomer is untouched. This is the whole assertion.
        #expect(exists(newcomer))
        #expect(try bytes(newcomer) == 99)
        #expect(try bytes(source) == 64)
        #expect(try store.journalRows(batchID: plan.batchID).map(\.state) == [.failed])
    }

    /// The same gap on a cross-volume move, where the source is unlinked after
    /// the copy: the newcomer must survive *and* so must the source, since the
    /// copy never landed.
    @Test func aCrossVolumeMoveOntoAGapArrivalKeepsBothFiles() async throws {
        let source = try tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store, volumeReader: { url in
            VolumeIdentity(device: url.path.hasSuffix("/to") ? 2 : 1,
                           uuid: url.path.hasSuffix("/to") ? "VOL-B" : "VOL-A")
        })
        let plan = try await op.plan(kind: .move, sources: [source], destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        let newcomer = try tree.file("to/IMG_0001.jpg", bytes: 99)

        let results = try await op.execute(plan)
        #expect(results[0].outcome == .failed(.destinationNotReplaceable))
        #expect(try bytes(newcomer) == 99)
        #expect(try bytes(source) == 64)
        #expect(try store.record(atPath: source.path) != nil)
    }
}

// MARK: - I1/I3: a partially unlinked cross-volume move keeps its copies

/// Makes a file un-removable without touching its directory, so a batch can be
/// stopped between one source removal and the next. `chflags(2)` rather than
/// `chmod`, because the permission that governs unlinking lives on the *parent*
/// and sealing that would stop the first removal too.
private func setImmutable(_ url: URL, _ immutable: Bool) {
    _ = url.withUnsafeFileSystemRepresentation { path in
        chflags(path, immutable ? UInt32(UF_IMMUTABLE) : 0)
    }
}

struct FileOperatorPartialSourceRemovalTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// The branch where `sourcesRemoved` is true: the RAW's source is already
    /// gone when the sidecar's removal is refused. **The copies at the
    /// destination are now the only copy of the RAW**, so nothing may roll them
    /// back — and the displaced occupant, never disposed of, stays findable at
    /// the stash its journal row names.
    @Test func aHalfUnlinkedCrossVolumeMoveKeepsItsCopiesAndItsStash() async throws {
        let raw = try tree.file("from/IMG_0001.CR2", bytes: 48)
        let sidecar = try tree.file("from/IMG_0001.xmp", bytes: 6)
        let destination = try tree.directory("to")
        let occupant = try tree.file("to/IMG_0001.CR2", bytes: 11)
        let store = try IndexStore.inMemory()
        try index(raw, into: store)
        try index(occupant, into: store)
        // The sidecar cannot be unlinked; the RAW can. So the removal loop gets
        // exactly one file in before it is stopped.
        setImmutable(sidecar, true)
        // `copyfile(3)` with `COPYFILE_ALL` carries the flag onto the copy, so
        // both have to be cleared or the tree cannot be removed.
        defer {
            setImmutable(sidecar, false)
            setImmutable(destination.appendingPathComponent("IMG_0001.xmp"), false)
        }

        let op = FileOperator(store: store, volumeReader: { url in
            VolumeIdentity(device: url.path.hasSuffix("/to") ? 2 : 1,
                           uuid: url.path.hasSuffix("/to") ? "VOL-B" : "VOL-A")
        })
        let plan = try await op.plan(kind: .move, sources: [raw], destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        let resolved = plan.resolvingAllCollisions(with: .replace)
        let stash = resolved.items[0].replacements[0].stash

        let results = try await op.execute(resolved)
        #expect(results[0].outcome == .failed(.sourceRemovalFailed))

        // The RAW exists only at the destination now. Removing it would have
        // been the loss.
        #expect(!exists(raw))
        #expect(try bytes(destination.appendingPathComponent("IMG_0001.CR2")) == 48)
        #expect(try bytes(sidecar) == 6)
        #expect(try bytes(destination.appendingPathComponent("IMG_0001.xmp")) == 6)

        // The displaced occupant was never disposed of, and its row still points
        // at where it is.
        #expect(try bytes(stash) == 11)
        let rows = try store.journalRows(batchID: plan.batchID)
        let aside = try #require(rows.first { $0.src == occupant.path })
        #expect(aside.state == .inFlight)
        #expect(aside.dst == stash.path)
        #expect(aside.trashURL == nil)
        // Every row of the item stays `in_flight`: both paths hold something.
        #expect(rows.filter { $0.kind == .move }.allSatisfy { $0.state == .inFlight })
    }
}

// MARK: - I2: `abandon` describes where the files really are

struct FileOperatorAbandonWordingTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// A **copy** whose disposal fails has not touched its originals, and the
    /// message must not claim otherwise — "the originals are gone" sent a user
    /// looking for files that were never moved.
    @Test func aCopyWhoseDisposalFailsSaysTheOriginalsAreUntouched() async throws {
        let source = try tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try tree.directory("to")
        _ = try tree.file("to/IMG_0001.jpg", bytes: 11)
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let stashBox = LockBox<URL?>(nil)
        let op = FileOperator(store: store, copier: { source, target, _ in
            try FileManager.default.copyItem(at: source, to: target)
            if let doomed = stashBox.withLock({ $0 }) {
                try? FileManager.default.removeItem(at: doomed)
            }
        })
        let plan = try await op.plan(kind: .copy, sources: [source], destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        let resolved = plan.resolvingAllCollisions(with: .replace)
        stashBox.withLock { $0 = resolved.items[0].replacements[0].stash }

        let results = try await op.execute(resolved)
        guard case .failed(.rollbackIncomplete(let detail)) = results[0].outcome else {
            Issue.record("expected .rollbackIncomplete, got \(results[0].outcome)")
            return
        }
        #expect(detail.contains("the originals are untouched"))
        #expect(!detail.contains("the originals are gone"))
        #expect(try bytes(source) == 64)
        #expect(try bytes(destination.appendingPathComponent("IMG_0001.jpg")) == 64)
    }

    /// The three wordings, directly. A same-volume move offers no seam between
    /// the `rename(2)` and the disposal, so its branch cannot be reached end to
    /// end — and an unchecked description is one that drifts back to claiming
    /// the originals are gone.
    @Test func abandonDescribesWhereTheFilesActuallyAre() async throws {
        let store = try IndexStore.inMemory()
        let op = FileOperator(store: store)
        let from = tree.root.appendingPathComponent("from/IMG_0001.jpg")
        let to = tree.root.appendingPathComponent("to/IMG_0001.jpg")

        func detail(_ state: TransferState) async -> String {
            let execution = await op.abandon(state, marks: [], reason: .diskFull)
            guard case .failed(.rollbackIncomplete(let text)) = execution.outcome else {
                return "unexpected: \(execution.outcome)"
            }
            return text
        }

        var unlinked = TransferState(byRename: false)
        unlinked.moved = [.init(from: from, to: to, sourceFacts: nil)]
        unlinked.sourcesRemoved = true
        let gone = await detail(unlinked)
        #expect(gone.contains("the originals are gone"))
        #expect(gone.contains(to.deletingLastPathComponent().path))

        var renamed = TransferState(byRename: true)
        renamed.moved = [.init(from: from, to: to, sourceFacts: nil)]
        let moved = await detail(renamed)
        #expect(moved.contains("no longer at their"))
        #expect(!moved.contains("the originals are gone"))

        var copied = TransferState(byRename: false)
        copied.moved = [.init(from: from, to: to, sourceFacts: nil)]
        let untouched = await detail(copied)
        #expect(untouched.contains("the originals are untouched"))
        #expect(!untouched.contains("the originals are gone"))

        // `sourceRemovalFailed` already names this exact state, so it is
        // reported as itself rather than wrapped in a second description.
        let passthrough = await op.abandon(unlinked, marks: [], reason: .sourceRemovalFailed)
        #expect(passthrough.outcome == .failed(.sourceRemovalFailed))
    }

    /// **A partial unlink is not "the originals are gone."** The #33 guard can
    /// stop the removal loop at its second file, with the first source already
    /// unlinked and the rest still where they were. Told "the originals are
    /// gone", a user goes looking at the destination for files that never left
    /// their folder — and, worse, stops looking at the source for the one that
    /// is still there.
    @Test func abandonNamesWhichOriginalsWentAndWhichDidNot() async throws {
        let raw = try tree.file("from/IMG_0001.CR2", bytes: 48)
        let adjustments = try tree.file("from/IMG_0001.aae", bytes: 7)
        let sidecar = try tree.file("from/IMG_0001.xmp", bytes: 6)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(raw, into: store)

        // Three files, so the last copy is a seam *after* the middle file's
        // `stat` was taken and *before* the removal loop reaches it. The RAW is
        // unlinked; the `.aae` is refused.
        let op = FileOperator(store: store, volumeReader: { url in
            VolumeIdentity(device: url.path.hasSuffix("/to") ? 2 : 1,
                           uuid: url.path.hasSuffix("/to") ? "VOL-B" : "VOL-A")
        }, copier: { source, target, _ in
            try FileManager.default.copyItem(at: source, to: target)
            if source.pathExtension == "xmp" {
                let doomed = source.deletingPathExtension().appendingPathExtension("aae")
                try FileManager.default.removeItem(at: doomed)
                try Data(repeating: 0x42, count: 99).write(to: doomed)
            }
        })
        let plan = try await op.plan(kind: .move, sources: [raw], destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        #expect(plan.items[0].companions == [adjustments, sidecar])

        let results = try await op.execute(plan)

        // The RAW really did go; the other two really did not.
        #expect(!exists(raw))
        #expect(try bytes(adjustments) == 99)
        #expect(try bytes(sidecar) == 6)

        guard case .failed(.rollbackIncomplete(let detail)) = results[0].outcome else {
            Issue.record("expected .rollbackIncomplete, got \(results[0].outcome)")
            return
        }
        // **The partition, not the vocabulary.** Asserting that each name
        // appears somewhere passes just as well when the two halves are swapped
        // — and a message that puts the surviving originals under "gone" is
        // worse than the one it replaced.
        #expect(detail.contains("gone from their original paths and now only at"))
        #expect(detail.contains(": IMG_0001.CR2; still at their original paths: "
                                + "IMG_0001.aae, IMG_0001.xmp;"))
        // The sentence that would send the user to the wrong folder.
        #expect(!detail.contains("the originals are gone"))
        #expect(!detail.contains("the originals are untouched"))
    }
}

// MARK: - #33: the unlink is guarded on identity, not on the path

/// **"There is a file here now" is not "this is the file we were asked to act
/// on."** Every index *write* in this type is guarded on identity — id, path,
/// size, mtime — because a row that no longer describes its file is a row that
/// belongs to a different photo. The two unlinks were not: they removed whatever
/// answered at the planned path, across the plan/execute gap for `delete` and
/// across the copy/unlink window for a cross-volume `move`. Those are the only
/// two places in the type where a file that arrived in the gap is *destroyed*
/// rather than displaced.
struct FileOperatorUnlinkIdentityTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// The irreversible path. A photo is planned for deletion, and in the gap
    /// before the batch runs — a confirmation sheet is a human-length pause —
    /// the file at that path is replaced by a different one. The row still says
    /// 64 bytes; the disk says 99. Unlinking on the strength of the path alone
    /// destroys a file nobody selected, permanently.
    @Test func aDeleteRefusesToUnlinkAFileThatArrivedInTheGap() async throws {
        let source = try tree.file("lib/IMG_0001.jpg", bytes: 64)
        let store = try IndexStore.inMemory()
        let planned = try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .delete, sources: [source], destination: nil)

        // The gap. Same path, different file.
        try FileManager.default.removeItem(at: source)
        _ = try tree.file("lib/IMG_0001.jpg", bytes: 99)

        let results = try await op.execute(plan)

        // The newcomer survives, and the outcome says why nothing happened.
        #expect(results[0].outcome == .failed(.modifiedSinceOperation))
        #expect(exists(source))
        #expect(try bytes(source) == 99)
        // Nothing changed, so the row is untouched and the journal says `failed`.
        let row = try #require(try store.record(atPath: source.path))
        #expect(row.id == planned)
        #expect(row.size == 64)
        #expect(try store.journalRows(batchID: plan.batchID).map(\.state) == [.failed])
    }

    /// The narrower window: a cross-volume move copies, then unlinks its
    /// sources. The RAW's `stat` is taken when its copy is verified; the sidecar
    /// is copied next, and that is the only seam between the two. Swapping the
    /// RAW there is the same event as above, and the unlink must decline.
    ///
    /// **The rows stay `in_flight`, not `failed`.** The copy is already at the
    /// destination, so "nothing changed" is not a promise this path can make —
    /// exactly the rule `FileOperationFailure` states for the four outcomes the
    /// operator cannot describe.
    @Test func aCrossVolumeMoveRefusesToUnlinkASourceSwappedAfterItsCopy() async throws {
        let raw = try tree.file("from/IMG_0001.CR2", bytes: 48)
        let sidecar = try tree.file("from/IMG_0001.xmp", bytes: 6)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(raw, into: store)

        let op = FileOperator(store: store, volumeReader: { url in
            VolumeIdentity(device: url.path.hasSuffix("/to") ? 2 : 1,
                           uuid: url.path.hasSuffix("/to") ? "VOL-B" : "VOL-A")
        }, copier: { source, target, _ in
            try FileManager.default.copyItem(at: source, to: target)
            // The RAW's copy is done and verified; its source removal has not
            // been reached. Something else replaces it.
            if source.pathExtension == "xmp" {
                let doomed = source.deletingPathExtension().appendingPathExtension("CR2")
                try FileManager.default.removeItem(at: doomed)
                try Data(repeating: 0x42, count: 99).write(to: doomed)
            }
        })
        let plan = try await op.plan(kind: .move, sources: [raw], destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }

        let results = try await op.execute(plan)

        // The newcomer is still at the source path, with its own bytes. This is
        // the whole assertion: without the guard it is unlinked.
        #expect(exists(raw))
        #expect(try bytes(raw) == 99)
        // The copy this batch made is at the destination, and the sidecar was
        // never unlinked either — the item stopped at the first refusal.
        #expect(try bytes(destination.appendingPathComponent("IMG_0001.CR2")) == 48)
        #expect(try bytes(sidecar) == 6)
        #expect(try bytes(destination.appendingPathComponent("IMG_0001.xmp")) == 6)

        guard case .failed(.rollbackIncomplete(let detail)) = results[0].outcome else {
            Issue.record("expected .rollbackIncomplete, got \(results[0].outcome)")
            return
        }
        #expect(detail.contains("modifiedSinceOperation"))

        // Both paths hold something, so every row of the item stays `in_flight`
        // carrying both, which is what the reconcile is built to re-`stat`.
        let rows = try store.journalRows(batchID: plan.batchID)
        #expect(rows.allSatisfy { $0.state == .inFlight })
        let rawRow = try #require(rows.first { $0.src == raw.path })
        #expect(rawRow.dst == destination.appendingPathComponent("IMG_0001.CR2").path)
    }

    /// The half of the guard `size`/`mtime` cannot cover on its own. A tier 0
    /// pass ran in the gap and re-indexed the path, so the row sitting on it now
    /// describes the *newcomer* and agrees with the disk field for field. What
    /// does not agree is the id the plan read: `files.id` is a reused rowid, and
    /// a row that was dropped and written again is not the row this delete was
    /// planned against — the same reason `setHashes(for:)` matches on the id as
    /// well as on the facts.
    @Test func aDeleteRefusesWhenTheRowAtThePathIsNoLongerThePlannedOne() async throws {
        let source = try tree.file("lib/IMG_0001.jpg", bytes: 64)
        let store = try IndexStore.inMemory()
        let planned = try index(source, into: store)
        // A second row, so re-inserting cannot be handed the dropped row's id
        // straight back: SQLite's next rowid is one past the highest in use.
        try index(try tree.file("lib/IMG_0002.jpg", bytes: 8), into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .delete, sources: [source], destination: nil)

        // The gap: a different file at the path, and an index that has caught up
        // with it. Nothing about the row's facts betrays the swap.
        try store.applyAndMark([.remove(id: planned, path: source.path)], marks: [])
        try FileManager.default.removeItem(at: source)
        _ = try tree.file("lib/IMG_0001.jpg", bytes: 99)
        let reindexed = try index(source, into: store)
        #expect(reindexed != planned)

        let results = try await op.execute(plan)

        #expect(exists(source))
        #expect(try bytes(source) == 99)
        #expect(results[0].outcome == .failed(.modifiedSinceOperation))
        #expect(try store.record(atPath: source.path)?.id == reindexed)
        #expect(try store.journalRows(batchID: plan.batchID).map(\.state) == [.failed])
    }

    /// **The refusal is per item, not per file.** A companion is a companion
    /// only because it shares the selected photo's basename — so once the file
    /// at the source path is not the one that was planned for, the `.xmp` beside
    /// it belongs to *that* file, not to the photo the user selected. Unlinking
    /// it destroys a stranger's sidecar under a batch that refused to touch the
    /// stranger's photo, which is the opposite of what the refusal claims.
    @Test func aRefusedDeleteLeavesTheCompanionsOfTheFileItRefused() async throws {
        let source = try tree.file("lib/IMG_0001.CR2", bytes: 64)
        let sidecar = try tree.file("lib/IMG_0001.xmp", bytes: 6)
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .delete, sources: [source], destination: nil)
        #expect(plan.items[0].companions == [sidecar])

        try FileManager.default.removeItem(at: source)
        _ = try tree.file("lib/IMG_0001.CR2", bytes: 99)

        let results = try await op.execute(plan)

        // Both halves of the stranger's set survive. The sidecar is the
        // assertion: it has no row of its own, so nothing but the item-level
        // refusal stands between it and `removeItem`.
        #expect(exists(sidecar))
        #expect(try bytes(sidecar) == 6)
        #expect(try bytes(source) == 99)
        #expect(results[0].outcome == .failed(.modifiedSinceOperation))
        // Every row of the item says `failed`, which is the truth: nothing was
        // touched, so the reconcile has nothing to re-examine.
        #expect(try store.journalRows(batchID: plan.batchID).map(\.state) == [.failed, .failed])
    }

    /// A row that is **gone** is not a row that agrees. The plan read an id for
    /// this file; by the time the batch runs a reconcile has pruned the row and
    /// something else is at the path. Skipping the guard because there is
    /// nothing to compare against is the pre-#33 behaviour — an unlink decided
    /// by the path alone — on the one operation that cannot be taken back.
    @Test func aDeleteRefusesWhenThePlannedRowIsGone() async throws {
        let source = try tree.file("lib/IMG_0001.jpg", bytes: 64)
        let store = try IndexStore.inMemory()
        let planned = try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .delete, sources: [source], destination: nil)
        #expect(plan.items[0].recordID == planned)

        // The gap: the row is pruned and a stranger takes the path, so nothing
        // in the index describes what is there.
        try store.applyAndMark([.remove(id: planned, path: source.path)], marks: [])
        try FileManager.default.removeItem(at: source)
        _ = try tree.file("lib/IMG_0001.jpg", bytes: 99)

        let results = try await op.execute(plan)

        #expect(exists(source))
        #expect(try bytes(source) == 99)
        #expect(results[0].outcome == .failed(.modifiedSinceOperation))
        #expect(try store.journalRows(batchID: plan.batchID).map(\.state) == [.failed])
    }

    /// **A source that is already gone is not a mismatch.** Something else
    /// removed it between the copy and the unlink — and "gone from the source,
    /// present at the destination" is the finished shape of a move, not a reason
    /// to abandon one. The guard exists to stop this loop unlinking a file it
    /// did not copy; there is nothing here to unlink, so it has nothing to
    /// refuse. `rowStillDescribes` states the same rule for the delete: a `stat`
    /// that fails is not a mismatch.
    @Test func aCrossVolumeMoveTreatsAVanishedSourceAsAlreadyUnlinked() async throws {
        let raw = try tree.file("from/IMG_0001.CR2", bytes: 48)
        let sidecar = try tree.file("from/IMG_0001.xmp", bytes: 6)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(raw, into: store)

        // The sidecar's copy is the seam: the RAW's copy has landed and its
        // `stat` is taken, and the removal loop has not started.
        let op = FileOperator(store: store, volumeReader: { url in
            VolumeIdentity(device: url.path.hasSuffix("/to") ? 2 : 1,
                           uuid: url.path.hasSuffix("/to") ? "VOL-B" : "VOL-A")
        }, copier: { source, target, _ in
            try FileManager.default.copyItem(at: source, to: target)
            if source.pathExtension == "xmp" {
                try FileManager.default.removeItem(
                    at: source.deletingPathExtension().appendingPathExtension("CR2"))
            }
        })
        let plan = try await op.plan(kind: .move, sources: [raw], destination: destination)
        defer { emptyTrash(of: store, batchID: plan.batchID) }

        let results = try await op.execute(plan)

        let landedRaw = destination.appendingPathComponent("IMG_0001.CR2")
        #expect(!exists(raw))
        #expect(!exists(sidecar))
        #expect(try bytes(landedRaw) == 48)
        #expect(try bytes(destination.appendingPathComponent("IMG_0001.xmp")) == 6)
        #expect(results[0].outcome == .completed)
        let rows = try store.journalRows(batchID: plan.batchID)
        #expect(rows.map(\.state) == [.complete, .complete])
        #expect(rows[0].dst == landedRaw.path)
        // The index followed the file rather than being left behind.
        #expect(try store.record(atPath: raw.path) == nil)
        #expect(try store.record(atPath: landedRaw.path) != nil)
    }
}
