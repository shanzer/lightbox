import Testing
import Foundation
import LightboxCore
@testable import Lightbox

/// A preference store that lives and dies with the test.
///
/// Not `UserDefaults(suiteName:)`: `removePersistentDomain` clears the values,
/// but `cfprefsd` writes the file out afterwards regardless, so that approach
/// leaves empty plists behind in `~/Library/Preferences` — measured, five of
/// them after one run. The App target is hosted by the real `Lightbox.app`, so
/// anything it writes lands in the user's own domain; see `PreferenceStore`.
///
/// Shared between two models on purpose in `theCompanionToggleIsRemembered
/// AndReachesThePlan`, which is where "remembered" is actually observable.
@MainActor
final class MemoryPreferences: PreferenceStore {
    private var flags: [String: Bool] = [:]

    func flag(forKey key: String) -> Bool? { flags[key] }
    func setFlag(_ value: Bool, forKey key: String) { flags[key] = value }
}

/// Removes whatever a batch put in the Trash.
///
/// Driven off the journal and not off the results, exactly as `Core`'s
/// `emptyTrash` is: every trashed file has a `trash_url` row whatever the batch
/// then does, whereas a result carries one only for an item that completed. A
/// cleanup that depends on the code under test working leaks precisely when it
/// does not.
private func emptyTrash(of store: IndexStore, batchID: String?) {
    guard let batchID else { return }
    for row in (try? store.journalRows(batchID: batchID)) ?? [] {
        guard let path = row.trashURL else { continue }
        try? FileManager.default.removeItem(atPath: path)
    }
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

// MARK: - The batch, end to end

/// What the window does with a finished batch: update the grid, move the
/// selection, and decide whether the user has to be shown anything.
@MainActor
struct FileOperationBatchTests {
    let tree: TempDirectory
    let preferences = MemoryPreferences()

    init() throws {
        tree = try TempDirectory()
    }

    private func model(_ store: IndexStore) -> BrowserModel {
        BrowserModel(store: store, preferences: preferences)
    }

    /// The acceptance bullet: after a move the grid shows the files where they
    /// now are, and it got there from the index rather than from a rescan.
    ///
    /// **`ghost.jpg` is the assertion, not decoration.** It is created on disk
    /// after the folder was indexed, so the index has never heard of it and
    /// only a tier 0 pass could put it in the grid. If `beginBatch` reached for
    /// `refresh()` instead of `reload()`, the moved file would still be right
    /// and this would still be a passing test — with a second row in it. Its
    /// absence is what pins "without a full rescan".
    @Test func aCompletedMoveUpdatesTheGridWithoutRescanningTheFolder() async throws {
        let root = try tree.directory("library")
        let source = try tree.file("library/from/IMG_0001.jpg", bytes: 64)
        let destination = try tree.directory("library/to")
        let store = try IndexStore.inMemory()
        let model = model(store)

        await model.open(root)
        #expect(model.records.count == 1)
        model.selectAll()

        try tree.file("library/ghost.jpg", bytes: 16)
        await model.beginBatch(.move, destination: destination)

        #expect(model.batchProgress == nil, "the progress indicator outlived the batch")
        #expect(model.activeSheet == nil,
                "a batch with no failures must not put a summary sheet on screen")
        #expect(model.records.count == 1,
                "the grid holds \(model.records.map(\.name)); a rescan would have added ghost.jpg")
        #expect(model.records.first?.path
            == destination.appendingPathComponent("IMG_0001.jpg").path)
        #expect(!exists(source))

        // The selection follows the file: same photo, new row, still selected.
        let movedID = try #require(model.records.first?.id)
        #expect(model.selection.selected == [movedID])
    }

    /// A move out of the folder on screen leaves nothing to follow, so the
    /// selection empties rather than clinging to a row that is no longer there.
    @Test func aMoveOutOfScopeLeavesTheSelectionEmpty() async throws {
        let root = try tree.directory("library")
        try tree.file("library/IMG_0001.jpg", bytes: 64)
        let elsewhere = try tree.directory("elsewhere")
        let store = try IndexStore.inMemory()
        let model = model(store)

        await model.open(root)
        model.selectAll()
        await model.beginBatch(.move, destination: elsewhere)

        #expect(model.records.isEmpty)
        #expect(model.selection.selected.isEmpty)
    }

    /// Trash collapses the selection to nothing — there is no row to follow —
    /// and the row leaves the index with the file.
    @Test func trashingClearsTheSelectionAndTheGrid() async throws {
        let root = try tree.directory("library")
        try tree.file("library/IMG_0001.jpg", bytes: 64)
        let store = try IndexStore.inMemory()
        let model = model(store)

        await model.open(root)
        model.selectAll()
        await model.beginBatch(.trash, destination: nil)
        defer { emptyTrash(of: store, batchID: model.lastCompletedBatch?.batchID) }

        #expect(model.records.isEmpty)
        #expect(model.selection.selected.isEmpty)
        #expect(model.activeSheet == nil)
    }

    /// The hook #6's Undo hangs off: the last batch that actually did
    /// something, and the menu title that names it.
    @Test func aCompletedBatchIsRememberedForUndo() async throws {
        let root = try tree.directory("library")
        try tree.file("library/a.jpg", bytes: 16)
        try tree.file("library/b.jpg", bytes: 16)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        let model = model(store)

        #expect(model.lastCompletedBatch == nil)
        #expect(model.undoMenuTitle == "Undo")

        await model.open(root)
        model.selectAll()
        await model.beginBatch(.move, destination: destination)

        let batch = try #require(model.lastCompletedBatch)
        #expect(batch.kind == .move)
        #expect(batch.completedCount == 2)
        #expect(model.undoMenuTitle == "Undo Move 2 Items")
    }

    /// A batch that failed puts the summary sheet up and hands it the reason.
    ///
    /// Staged by making the destination unwritable, which is the one failure a
    /// temporary directory can produce on demand without a `Copying` seam —
    /// `FileOperator`'s injection point is not reachable from here.
    @Test func aFailedItemRaisesTheSummarySheetWithItsReason() async throws {
        let root = try tree.directory("library")
        try tree.file("library/IMG_0001.jpg", bytes: 64)
        let destination = try tree.directory("locked")
        let store = try IndexStore.inMemory()
        let model = model(store)

        await model.open(root)
        model.selectAll()
        try tree.chmod("locked", 0o500)
        await model.beginBatch(.move, destination: destination)

        guard case .summary(let summary)? = model.activeSheet else {
            Issue.record("no summary sheet after a failed batch: \(String(describing: model.activeSheet))")
            return
        }
        #expect(summary.failures.count == 1)
        let failure = try #require(summary.failures.first)
        #expect(failure.source.lastPathComponent == "IMG_0001.jpg")
        #expect(!failure.reason.isEmpty)
        #expect(summary.canRetry)
        // The retry has to know where the batch was going, or "Retry Failed"
        // can only ever retry a trash.
        #expect(summary.destinationDirectory == destination)
    }

    /// Nothing runs while nothing is selected, and nothing runs on top of a
    /// batch already in flight.
    @Test func theCommandsAreOffWithoutASelection() async throws {
        let root = try tree.directory("library")
        try tree.file("library/IMG_0001.jpg", bytes: 16)
        let store = try IndexStore.inMemory()
        let model = model(store)
        await model.open(root)

        for command in FileCommand.allCases {
            #expect(!model.isEnabled(command),
                    "\(command.title) is live with an empty selection")
        }
        model.selectAll()
        for command in FileCommand.allCases {
            #expect(model.isEnabled(command),
                    "\(command.title) is dead with a selection")
        }
    }

    /// The companion toggle is remembered, and it is what the plan is built
    /// with. Off means the `.xmp` stays behind — which is the setting's whole
    /// purpose and the reason it defaults to on.
    @Test func theCompanionToggleIsRememberedAndReachesThePlan() async throws {
        let root = try tree.directory("library")
        try tree.file("library/IMG_0001.CR2", bytes: 64)
        try tree.file("library/IMG_0001.xmp", bytes: 16)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()

        let first = model(store)
        #expect(first.includeCompanions, "the toggle has to default to on")
        first.includeCompanions = false

        // A second window reads the same preference, which is where
        // "remembered in UserDefaults" is actually observable.
        let second = model(store)
        #expect(!second.includeCompanions)

        await second.open(root)
        second.selection.selectAll(second.records.compactMap {
            $0.name == "IMG_0001.CR2" ? $0.id : nil
        })
        await second.beginBatch(.move, destination: destination)

        #expect(exists(destination.appendingPathComponent("IMG_0001.CR2")))
        #expect(!exists(destination.appendingPathComponent("IMG_0001.xmp")),
                "the sidecar travelled with the RAW despite the toggle being off")
    }
}

// MARK: - The collision sheet

/// The sheet's job is to turn a user's choice into the plan `FileOperator`
/// expects, and to describe the two kinds of claim differently — a file on disk
/// and a file this batch is about to write are not the same problem and do not
/// offer the same answers.
@MainActor
struct CollisionSheetTests {
    let tree: TempDirectory

    init() throws { tree = try TempDirectory() }

    /// A plan with two on-disk collisions, built the way `Core`'s tests build
    /// one: over a real temporary tree, because `FileOperationPlan` has no
    /// public initialiser and a synthetic one would be asserting against a
    /// shape the operator never produces.
    private func twoCollisions() async throws -> (FileOperationPlan, URL) {
        let a = try tree.file("from/a.jpg", bytes: 16)
        let b = try tree.file("from/b.jpg", bytes: 16)
        let destination = try tree.directory("to")
        try tree.file("to/a.jpg", bytes: 32)
        try tree.file("to/b.jpg", bytes: 32)
        let op = FileOperator(store: try IndexStore.inMemory())
        let plan = try await op.plan(kind: .move, sources: [a, b], destination: destination)
        return (plan, destination)
    }

    @Test func bothCollisionsAreOfferedAndNothingRunsUntilBothAreAnswered() async throws {
        let (plan, _) = try await twoCollisions()
        let sheet = CollisionSheetModel(plan: plan)

        #expect(sheet.pendingIndices == [0, 1])
        #expect(!sheet.isFullyResolved, "a plan with two open collisions is not runnable")
        #expect(sheet.offersReplace(forItemAt: 0))
        #expect(sheet.describeCollision(forItemAt: 0)
            .localizedCaseInsensitiveContains("already exists at the destination"))

        sheet.resolve(itemAt: 0, with: .rename)
        #expect(!sheet.isFullyResolved, "one answer resolved the whole sheet")
        #expect(sheet.pendingIndices == [1])

        sheet.resolve(itemAt: 1, with: .skip)
        #expect(sheet.isFullyResolved)
        #expect(!sheet.plan.hasUnresolvedCollisions)
    }

    /// Each resolution has to produce the plan the operator would act on —
    /// the destinations, not just the label the user picked.
    @Test func eachResolutionProducesThePlanTheOperatorExpects() async throws {
        let (plan, destination) = try await twoCollisions()

        let renamed = CollisionSheetModel(plan: plan)
        renamed.resolveAll(with: .rename)
        #expect(renamed.plan.items.map { $0.destination?.lastPathComponent }
            == ["a 2.jpg", "b 2.jpg"])
        #expect(renamed.plan.items.allSatisfy { $0.replacements.isEmpty })

        let skipped = CollisionSheetModel(plan: plan)
        skipped.resolveAll(with: .skip)
        #expect(skipped.plan.items.allSatisfy { $0.destination == nil })
        #expect(skipped.plan.items.allSatisfy { $0.effectiveResolution == .skip })

        let replaced = CollisionSheetModel(plan: plan)
        replaced.resolveAll(with: .replace)
        #expect(replaced.plan.items.map { $0.destination?.lastPathComponent }
            == ["a.jpg", "b.jpg"])
        #expect(replaced.plan.items.map(\.replacements.count) == [1, 1])
        #expect(replaced.plan.items[0].replacements.first?.occupant
            == destination.appendingPathComponent("a.jpg"))

        // Mixed, per item, which is the other half of what the sheet offers.
        let mixed = CollisionSheetModel(plan: plan)
        mixed.resolve(itemAt: 0, with: .replace)
        mixed.resolve(itemAt: 1, with: .rename)
        #expect(mixed.plan.items.map { $0.destination?.lastPathComponent }
            == ["a.jpg", "b 2.jpg"])
        #expect(mixed.plan.items.map(\.replacements.count) == [1, 0])
    }

    /// A collision the batch created itself is described differently and does
    /// not offer Replace — `Core` degrades `replace` to `rename` for these, and
    /// a sheet that offered the button anyway would be lying about the outcome.
    @Test func anIntraBatchCollisionSaysSoAndDoesNotOfferReplace() async throws {
        let a = try tree.file("one/IMG_0001.jpg", bytes: 16)
        let b = try tree.file("two/IMG_0001.jpg", bytes: 16)
        let destination = try tree.directory("to")
        let op = FileOperator(store: try IndexStore.inMemory())
        let plan = try await op.plan(kind: .copy, sources: [a, b], destination: destination)

        let sheet = CollisionSheetModel(plan: plan)
        #expect(sheet.pendingIndices == [1], "only the second item is in anyone's way")
        #expect(!sheet.offersReplace(forItemAt: 1))
        #expect(sheet.describeCollision(forItemAt: 1)
            .localizedCaseInsensitiveContains("another file in this batch"))
        #expect(!sheet.describeCollision(forItemAt: 1)
            .localizedCaseInsensitiveContains("already exists"))

        // And if Replace were somehow chosen, the plan degrades it rather than
        // putting one of the user's own photos on top of the other.
        sheet.resolveAll(with: .replace)
        #expect(sheet.plan.items[1].effectiveResolution == .rename)
        #expect(sheet.plan.items[1].destination?.lastPathComponent == "IMG_0001 2.jpg")
    }
}
