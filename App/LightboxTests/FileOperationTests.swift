import Testing
import Foundation
@testable import LightboxCore
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

/// Names the sheet on screen, for a failure message. `Comment` is not `String`,
/// so a concatenated message will not compile — one interpolation, built here.
@MainActor
private func sheetDescription(_ model: BrowserModel) -> String {
    model.activeSheet.map(\.id) ?? "no sheet"
}

/// Drives a cancel from the operator side rather than the wall clock (#45).
///
/// `FileOperator.itemBoundaryHook` is awaited once per finished item, on the
/// operator's own queue, before the next item's cancellation check. Installed
/// as this gate's `hook(_:)`, it reports the item count to a test that is
/// waiting on `awaitFirstItem()` and then parks until `release()` — so a test
/// can call `cancelBatch()` between exactly one item finishing and the next
/// one starting, with no dependency on `batchProgress` or on how long any
/// other suite in this process happens to hold the main actor.
///
/// An actor, not a class with a lock: the hook runs on `FileOperator`'s queue
/// and `awaitFirstItem`/`release` run on the main actor, and the two rendez­vous
/// through actor isolation rather than through `os_unfair_lock` or a
/// `DispatchSemaphore` — the latter would park a *thread*, which is exactly
/// what `FileOperator`'s own executor exists to avoid (`CLAUDE.md`, "blocking
/// work never runs on the cooperative pool").
private actor ItemGate {
    private(set) var reachedCount = 0
    private var reachedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releasePending = false

    /// Installed as `FileOperator.itemBoundaryHook`. Reports `completed`, then
    /// parks until `release()` — synchronously, so by the time
    /// `awaitFirstItem()` returns to its caller, this call is already parked
    /// and `release()` cannot arrive early. Actor exclusivity is what makes
    /// that true: nothing else runs on this actor between the report below
    /// and the suspension that follows it.
    func hook(_ completed: Int) async {
        reachedCount = completed
        if let reachedContinuation {
            self.reachedContinuation = nil
            reachedContinuation.resume()
        }
        if releasePending {
            releasePending = false
            return
        }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    /// Suspends until the hook has reported its first item.
    func awaitFirstItem() async {
        guard reachedCount == 0 else { return }
        await withCheckedContinuation { reachedContinuation = $0 }
    }

    /// Lets a parked `hook(_:)` call continue. Safe to call before the hook
    /// has parked — the release is then remembered rather than lost — though
    /// `awaitFirstItem()` returning already rules that ordering out.
    func release() {
        if let releaseContinuation {
            self.releaseContinuation = nil
            releaseContinuation.resume()
        } else {
            releasePending = true
        }
    }
}

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

    /// A batch that failed puts the summary sheet up, hands it the reason, and
    /// retries **only** the items that failed.
    ///
    /// Two items, one of which cannot move: `library/locked` is `r-x`, and
    /// removing a directory entry needs write permission on the *directory*, so
    /// the `rename(2)` out of it fails while its sibling's succeeds. One file
    /// would not do — a retry that re-ran the whole batch would look identical.
    @Test func aFailedItemRaisesTheSummarySheetAndRetryTakesOnlyIt() async throws {
        let root = try tree.directory("library")
        try tree.file("library/locked/IMG_LOCKED.jpg", bytes: 64)
        try tree.file("library/free/IMG_FREE.jpg", bytes: 64)
        let destination = try tree.directory("library/to")
        let store = try IndexStore.inMemory()
        let model = model(store)

        await model.open(root)
        #expect(model.records.count == 2)
        model.selectAll()
        try tree.chmod("library/locked", 0o500)
        await model.beginBatch(.move, destination: destination)

        guard case .summary(let summary)? = model.activeSheet else {
            Issue.record("no summary sheet after a failed batch: \(sheetDescription(model))")
            return
        }
        #expect(summary.results.count == 2, "the summary describes the whole batch")
        #expect(summary.completedCount == 1)
        #expect(summary.failures.count == 1)
        let failure = try #require(summary.failures.first)
        #expect(failure.source.lastPathComponent == "IMG_LOCKED.jpg")
        #expect(!failure.reason.isEmpty)
        #expect(summary.canRetry)
        // The retry has to know where the batch was going, or "Retry Failed"
        // can only ever retry a trash.
        #expect(summary.destinationDirectory == destination)

        // Retry Failed, with the directory still locked so it fails the same
        // way. **`results.count == 1` is the assertion**: a retry that rebuilt
        // the plan from the selection rather than from the failures would carry
        // IMG_FREE along too — and IMG_FREE has already moved, so it would come
        // back as a second, invented failure.
        await model.retryFailedItems()
        guard case .summary(let retried)? = model.activeSheet else {
            Issue.record("no summary sheet after the retry: \(sheetDescription(model))")
            return
        }
        #expect(retried.results.count == 1)
        #expect(retried.failures.map(\.source.lastPathComponent) == ["IMG_LOCKED.jpg"])
    }

    /// Nothing runs while nothing is selected, while a batch is in flight, or
    /// while a sheet is up.
    ///
    /// The last of those is not theoretical: a SwiftUI sheet is **not**
    /// run-loop modal, so ⌘⌫ pressed over the collision sheet reaches the menu
    /// and would start a trash batch, whose `run` overwrites `activeSheet` with
    /// `.progress` — discarding the half-answered plan the user was part way
    /// through, with no way back to it.
    @Test func theCommandsAreOffWithoutASelectionDuringABatchAndUnderASheet() async throws {
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

        // Assigned rather than raced into: what is under test is the rule, and
        // a test that had to catch a real batch mid-flight to state it would be
        // asserting on the scheduler. `cancellingABatchLeavesTheFinishedItems
        // Done` drives the real thing.
        model.batchProgress = BatchProgress(kind: .move, completed: 1, total: 9, current: nil)
        for command in FileCommand.allCases {
            #expect(!model.isEnabled(command),
                    "\(command.title) is live while a batch is running")
        }
        model.batchProgress = nil

        model.activeSheet = .confirmPermanentDelete(count: 1)
        for command in FileCommand.allCases {
            #expect(!model.isEnabled(command),
                    "\(command.title) is live under a sheet; ⌘⌫ would discard it")
        }
        model.dismissSheet()
        #expect(model.isEnabled(.trash), "dismissing the sheet did not re-arm the commands")
    }

    /// Delete Permanently asks first, and the question names the count.
    @Test func permanentDeleteAsksFirstAndNamesTheCount() async throws {
        let root = try tree.directory("library")
        for index in 0..<3 { try tree.file("library/IMG_000\(index).jpg", bytes: 16) }
        let store = try IndexStore.inMemory()
        let model = model(store)
        await model.open(root)
        model.selectAll()

        model.confirmPermanentDelete()
        guard case .confirmPermanentDelete(let count)? = model.activeSheet else {
            Issue.record("Delete Permanently ran without asking: \(sheetDescription(model))")
            return
        }
        #expect(count == model.selection.selected.count)
        #expect(count == 3)
        // Nothing has happened yet — the plan is only built once the user says
        // yes, so the files are all still there.
        #expect(model.records.count == 3)
    }

    /// A second click while the first batch is still planning must not start a
    /// second batch over the same files.
    ///
    /// **The window is real and is not covered by `batchProgress`**: that is set
    /// in `run`, which is on the far side of `await FileOperator.plan(...)`. Two
    /// batches planned over the same sources both see them present; the first
    /// moves them and the second reports every one as vanished.
    @Test func aSecondClickWhileTheFirstIsStillPlanningStartsNothing() async throws {
        let root = try tree.directory("library")
        try tree.file("library/IMG_0001.jpg", bytes: 64)
        let destination = try tree.directory("library/to")
        let store = try IndexStore.inMemory()
        let model = model(store)

        await model.open(root)
        model.selectAll()

        // Both are enqueued on the main actor before either runs; the second
        // gets its turn while the first is suspended inside `plan`.
        let first = Task { await model.beginBatch(.move, destination: destination) }
        let second = Task { await model.beginBatch(.move, destination: destination) }
        await first.value
        await second.value

        #expect(model.activeSheet == nil,
                "a second batch ran and reported the first batch's files as vanished")
        #expect(model.lastCompletedBatch?.completedCount == 1)
        #expect(exists(destination.appendingPathComponent("IMG_0001.jpg")))
    }

    /// Cancel stops the batch after the item it is on, and everything already
    /// finished stays finished — on disk and in the journal.
    ///
    /// **Driven from the operator, not the wall clock (#45).** Polling
    /// `batchProgress` on the main actor raced the other `@MainActor` suites
    /// in this process, which block it synchronously for seconds
    /// (`MenuCommandTests`'s `RunLoop.current.run`): by the time the poll
    /// observed progress, all 300 items were already done and there was
    /// nothing left to cancel. `ItemGate` instead parks `FileOperator` itself
    /// after the first item, which a `Task.checkCancellation()` cannot be
    /// scheduled around.
    @Test func cancellingABatchLeavesTheFinishedItemsDone() async throws {
        let total = 300
        let root = try tree.directory("library")
        for index in 0..<total {
            try tree.file(String(format: "library/from/IMG_%04d.jpg", index), bytes: 16)
        }
        let destination = try tree.directory("library/to")
        let store = try IndexStore.inMemory()
        let model = model(store)

        await model.open(root)
        #expect(model.records.count == total)
        model.selectAll()

        let gate = ItemGate()
        await model.fileOperator.setItemBoundaryHookForTesting { completed in
            await gate.hook(completed)
        }

        let batch = Task { await model.beginBatch(.move, destination: destination) }
        await gate.awaitFirstItem()
        model.cancelBatch()
        await gate.release()
        await batch.value

        let batchID = try #require(model.lastCompletedBatch?.batchID,
                                   "the cancelled batch completed nothing at all")
        let done = try #require(model.lastCompletedBatch?.completedCount)
        // A monotonic count, not `batchProgress` — which `endBatch()` clears
        // by the time this line runs. The gate parked after exactly one item,
        // so cancellation cannot have let a second one start.
        #expect(done == 1,
                "the gate released after item 1; cancel must land before item 2 starts")

        // The journal is the record, and it has to agree with the disk. Every
        // item the batch finished is `complete`; the ones it never reached stay
        // `in_flight`, which is exactly what #6's reconcile is built to settle.
        let rows = try store.journalRows(batchID: batchID)
        let complete = rows.filter { $0.state == .complete }
        #expect(complete.count == done)
        #expect(rows.contains { $0.state == .inFlight },
                "a cancelled batch left no unreached rows, so nothing was cancelled")
        for row in complete {
            #expect(exists(URL(fileURLWithPath: row.dst ?? "")),
                    "a row says complete but nothing is at \(row.dst ?? "nil")")
        }
    }

    /// **Nothing runs until the collisions are answered**, and answering them
    /// is what makes it run — spec §8's "no batch discovers a collision at file
    /// 300", end to end through the model rather than over a synthetic plan.
    ///
    /// Three states, and the middle one is the point. `CollisionSheetTests`
    /// proves the sheet turns a choice into the right plan; nothing proved the
    /// window refuses to act on an unanswered one, so dropping either guard —
    /// the `hasUnresolvedCollisions` branch in `planAndRun`, or
    /// `isFullyResolved` in `continueWithResolvedPlan` — left the whole suite
    /// green while the app moved a file the user had not agreed to move.
    @Test func aCollisionStopsTheBatchUntilItIsAnswered() async throws {
        let root = try tree.directory("library")
        let source = try tree.file("library/from/a.jpg", bytes: 64)
        let destination = try tree.directory("library/to")
        try tree.file("library/to/a.jpg", bytes: 32)
        let store = try IndexStore.inMemory()
        let model = model(store)

        await model.open(root)
        model.selection.selectAll(model.records.compactMap {
            $0.path == source.path ? $0.id : nil
        })
        #expect(model.selection.selected.count == 1)

        // 1. The sheet comes up and nothing has moved.
        await model.beginBatch(.move, destination: destination)
        guard case .collisions(let sheet)? = model.activeSheet else {
            Issue.record("no collision sheet: \(sheetDescription(model))")
            return
        }
        #expect(exists(source), "the file moved before anyone answered")
        #expect(model.lastCompletedBatch == nil)
        #expect(!sheet.isFullyResolved)

        // 2. Continue with the question still open is a no-op. Not "runs and
        //    fails": `FileOperator.execute` would throw `unresolvedCollisions`
        //    and this window would put a summary sheet over the user's
        //    half-answered one.
        await model.continueWithResolvedPlan()
        #expect(exists(source), "an unanswered plan was executed")
        #expect(model.lastCompletedBatch == nil)
        guard case .collisions? = model.activeSheet else {
            Issue.record("the collision sheet was replaced by \(sheetDescription(model))")
            return
        }

        // 3. Answered, it runs — and rename is what the answer said.
        sheet.resolveAll(with: .rename)
        #expect(sheet.isFullyResolved)
        await model.continueWithResolvedPlan()

        #expect(!exists(source))
        #expect(exists(destination.appendingPathComponent("a 2.jpg")))
        #expect(exists(destination.appendingPathComponent("a.jpg")),
                "rename displaced the file it was supposed to leave alone")
        #expect(model.lastCompletedBatch?.completedCount == 1)
        #expect(model.activeSheet == nil)
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

// MARK: - Undo

/// ⌘Z, through the model. `Core`'s `FileOperatorUndoTests` prove the reversal
/// itself; what is asserted here is that the window asks for it, survives it,
/// and comes back describing the right thing.
@MainActor
struct UndoTests {
    let tree: TempDirectory
    let preferences = MemoryPreferences()

    init() throws { tree = try TempDirectory() }

    private func model(_ store: IndexStore) -> BrowserModel {
        BrowserModel(store: store, preferences: preferences)
    }

    /// The wiring test: move three files, undo, and everything is back —
    /// on disk, in the index, and in what the next ⌘Z offers to do.
    ///
    /// Verified by mutation: making `undoLastBatch` return without calling
    /// `FileOperator.undo` turns this red on the first assertion.
    @Test func undoingAMovePutsTheFilesBackOnDiskAndInTheIndex() async throws {
        let root = try tree.directory("library")
        let names = ["IMG_0001.jpg", "IMG_0002.jpg", "IMG_0003.jpg"]
        let sources = try names.map { try tree.file("library/from/\($0)", bytes: 64) }
        let destination = try tree.directory("library/to")
        let store = try IndexStore.inMemory()
        let model = model(store)

        await model.open(root)
        #expect(model.records.count == 3)
        model.selectAll()
        await model.beginBatch(.move, destination: destination)

        let forward = try #require(model.lastCompletedBatch)
        #expect(forward.completedCount == 3)
        #expect(model.undoMenuTitle == "Undo Move 3 Items")
        #expect(sources.allSatisfy { !exists($0) }, "the move did not happen")
        #expect(model.canUndo)

        // **Through the menu action, not `undoLastBatch()` directly.**
        // `UndoCommandAction.run` is the only code a user's ⌘Z executes, and
        // the first version of it swallowed every press without any test
        // noticing — because every test called the model straight.
        let outcome = UndoCommandAction.run(isEditingText: false, model: model)
        #expect(outcome.destination == .model)
        await outcome.work?.value

        // On disk.
        for source in sources {
            #expect(exists(source), "\(source.lastPathComponent) did not come back")
        }
        let leftBehind = try FileManager.default
            .contentsOfDirectory(atPath: destination.path)
            .filter { !$0.hasPrefix(".") }
        #expect(leftBehind.isEmpty, "the destination still holds \(leftBehind)")

        // In the index. The grid is reloaded from it, so these are the same
        // claim twice — deliberately, because a row that survived at the old
        // path is invisible in `records` and lethal to duplicate detection.
        for source in sources {
            #expect(try store.record(atPath: source.path) != nil,
                    "no row for \(source.lastPathComponent) at its restored path")
            #expect(try store.record(
                atPath: destination.appendingPathComponent(source.lastPathComponent).path) == nil,
                    "a row survived at the destination \(source.lastPathComponent) left")
        }
        #expect(model.records.count == 3)
        #expect(Set(model.records.map(\.path)) == Set(sources.map(\.path)))

        // And the next ⌘Z is the redo, named as one.
        let reversal = try #require(model.lastCompletedBatch)
        #expect(reversal.batchID != forward.batchID,
                "the reversal was journalled under the batch it reversed")
        #expect(reversal.isReversal)
        #expect(reversal.completedCount == 3)
        #expect(model.undoMenuTitle == "Redo Move 3 Items")
        #expect(model.activeSheet == nil, "a clean undo put a sheet on screen")
        #expect(model.selection.selected.isEmpty, "the selection survived an undo")
    }

    /// Undoing a **copy** still calls itself a copy — on the second press too.
    ///
    /// `Core` reverses a copy by trashing it, so the reversal's journal rows say
    /// `.trash`. The first press cannot show the drift: the kind is read off the
    /// *forward* batch, which really was a copy. It is the **second** press that
    /// reads `undoability` for the reversal and gets `.trash` back, titling the
    /// item "Undo Trash 3 Items" — naming the machinery instead of the thing the
    /// user did. `CompletedBatch.kind` exists to carry the user's word through,
    /// and pressing twice is the only way to assert that it does. (The
    /// single-press version of this test passed with the bug in place.)
    ///
    /// The round trip is worth having for itself: copy → undo → redo, with the
    /// copies trashed and then restored, is the redo path end to end.
    @Test func undoingACopyIsStillNamedACopyAcrossARedo() async throws {
        let root = try tree.directory("library")
        let names = ["a.jpg", "b.jpg", "c.jpg"]
        for name in names { try tree.file("library/from/\(name)", bytes: 32) }
        let destination = try tree.directory("library/to")
        let store = try IndexStore.inMemory()
        let model = model(store)
        var batchIDs: [String] = []
        defer { for id in batchIDs { emptyTrash(of: store, batchID: id) } }

        await model.open(root)
        model.selection.selectAll(model.records.compactMap {
            $0.path.contains("/from/") ? $0.id : nil
        })
        #expect(model.selection.selected.count == 3)
        await model.beginBatch(.copy, destination: destination)
        #expect(model.undoMenuTitle == "Undo Copy 3 Items")
        #expect(names.allSatisfy { exists(destination.appendingPathComponent($0)) })

        // Press one: the copies go to the Trash, the originals stay.
        let undo = UndoCommandAction.run(isEditingText: false, model: model)
        #expect(undo.destination == .model)
        await undo.work?.value
        batchIDs.append(try #require(model.lastCompletedBatch?.batchID))

        for name in names {
            #expect(!exists(destination.appendingPathComponent(name)),
                    "\(name) is still at the destination")
            #expect(exists(root.appendingPathComponent("from/\(name)")),
                    "undoing the copy took the original \(name)")
        }
        #expect(model.undoMenuTitle == "Redo Copy 3 Items")

        // Press two: the redo. This is where the kind would drift to `.trash`.
        let redo = UndoCommandAction.run(isEditingText: false, model: model)
        #expect(redo.destination == .model)
        await redo.work?.value
        batchIDs.append(try #require(model.lastCompletedBatch?.batchID))

        for name in names {
            #expect(exists(destination.appendingPathComponent(name)),
                    "the redo did not put the copy of \(name) back")
        }
        #expect(model.undoMenuTitle == "Undo Copy 3 Items",
                "the title names the machinery rather than the operation")
    }

    /// What a **second** ⌘Z does after the first one was cancelled.
    ///
    /// The claim the comment on `runUndo`'s cancellation branch makes, asserted
    /// rather than reasoned. A cancelled undo journals under a reversal id this
    /// side never learns, so `lastCompletedBatch` still names the original —
    /// whose rows `FileOperator.undo` never touched, so it is still `complete`
    /// and still undoable. Pressing again therefore re-runs the *whole*
    /// reversal: the items the first attempt already restored have no source
    /// left to move, and come back as per-item failures while the rest are
    /// restored.
    ///
    /// Noisy, and deliberately not refused — the second press finishes the job.
    /// The point of the test is that "noisy" is the worst of it: nothing is
    /// lost, and every file ends up back where it started.
    ///
    /// **Driven from the operator, not the wall clock (#45).** This used to
    /// poll `model.batchProgress` on the main actor, which raced the other
    /// `@MainActor` suites in the same process: `MenuCommandTests` blocks the
    /// main actor synchronously for seconds (`RunLoop.current.run`), so the
    /// poll could observe progress only after all 120 items were already
    /// restored, and the assertion that the first undo was partial failed —
    /// seen 2 of 10 full App runs. `ItemGate` instead parks `FileOperator`
    /// itself, on its own queue, immediately after the first item's journal
    /// write — a boundary `Task.checkCancellation()` cannot be scheduled
    /// around, whatever else the process is doing.
    @Test func aSecondUndoAfterACancelledOneFinishesTheJobNoisily() async throws {
        let total = 120
        let root = try tree.directory("library")
        var sources: [URL] = []
        for index in 0..<total {
            sources.append(try tree.file(String(format: "library/from/IMG_%04d.jpg", index),
                                         bytes: 16))
        }
        let destination = try tree.directory("library/to")
        let store = try IndexStore.inMemory()
        let model = model(store)

        await model.open(root)
        model.selectAll()
        await model.beginBatch(.move, destination: destination)
        #expect(model.lastCompletedBatch?.completedCount == total)

        // First press, cancelled the instant the gate reports the first
        // restored item — before a second one can start.
        let gate = ItemGate()
        await model.fileOperator.setItemBoundaryHookForTesting { completed in
            await gate.hook(completed)
        }
        let first = UndoCommandAction.run(isEditingText: false, model: model)
        await gate.awaitFirstItem()
        model.cancelBatch()
        await gate.release()
        await first.work?.value
        // Cleared before the second press: that undo must run to completion,
        // with nothing left to park it.
        await model.fileOperator.setItemBoundaryHookForTesting(nil)

        let restoredByFirst = sources.count(where: exists)
        // A monotonic count the gate produced directly, not `batchProgress` —
        // which `endBatch()` clears by the time this line runs, and which a
        // state load can overtake regardless. The gate released after exactly
        // one item, so the cancel cannot have let a second one start.
        #expect(restoredByFirst == 1,
                "the gate released after item 1; cancel must land before item 2 starts")
        #expect(model.lastCompletedBatch?.kind == .move,
                "a cancelled undo must leave the original batch as the thing to reverse")

        // Second press: the same reversal, over everything.
        #expect(model.canUndo)
        let second = UndoCommandAction.run(isEditingText: false, model: model)
        #expect(second.destination == .model)
        await second.work?.value

        // Every file is home.
        #expect(sources.allSatisfy(exists), "the second undo did not finish the job")
        let left = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            .filter { !$0.hasPrefix(".") }
        #expect(left.isEmpty, "the destination still holds \(left.count) files")

        // And the noise is exactly the already-restored items, reported as
        // gone rather than silently skipped.
        guard case .summary(let summary)? = model.activeSheet else {
            Issue.record("the second undo reported nothing: \(sheetDescription(model))")
            return
        }
        #expect(summary.failures.count == restoredByFirst,
                "\(summary.failures.count) failures for \(restoredByFirst) already-restored items")
        #expect(summary.failures.allSatisfy {
            $0.failure == .sourceVanished
        }, "a move's already-restored items should report as vanished sources")
    }

    /// A refusal is shown, never swallowed. A permanent delete is the case that
    /// matters and the one `Core` reports first, whatever else a batch holds.
    ///
    /// Nothing is remembered for ⌘Z after a permanent delete — `finish` refuses
    /// to record one — so the refusal is reached by handing the model a batch
    /// id directly, which is also the shape a stale `lastCompletedBatch` takes
    /// after retention ages a batch out.
    @Test func aRefusalIsExplainedRatherThanSilentlyIgnored() async throws {
        let root = try tree.directory("library")
        try tree.file("library/IMG_0001.jpg", bytes: 16)
        let store = try IndexStore.inMemory()
        let model = model(store)
        await model.open(root)

        model.lastCompletedBatch = CompletedBatch(batchID: "a-batch-that-never-was",
                                                  kind: .move, results: [], isReversal: false)
        #expect(model.canUndo)
        await model.undoLastBatch()

        guard case .summary(let summary)? = model.activeSheet else {
            Issue.record("a refused undo said nothing: \(sheetDescription(model))")
            return
        }
        let explanation = try #require(summary.planningFailure)
        #expect(!explanation.isEmpty)
        #expect(explanation.localizedCaseInsensitiveContains("no record"),
                "the refusal does not say why: \(explanation)")
        #expect(!summary.canRetry, "a refused undo must not offer Retry Failed")
    }

    /// Every refusal has a sentence, and the two that carry counts show them.
    /// A `switch` with a `default` would let a case added by a later Core
    /// change reach the user as an empty sheet.
    @Test func everyUndoRefusalHasASentence() throws {
        let refusals: [UndoRefusal] = [
            .noSuchBatch, .permanentDelete, .unsettled(rows: 3),
            .reconciledAfterACrash(rows: 2), .someItemsFailed(rows: 1), .nothingToUndo,
        ]
        for refusal in refusals {
            let sentence = BrowserModel.describe(refusal: refusal)
            #expect(!sentence.isEmpty, "\(refusal) has no explanation")
            // A digit is a legitimate opener — "3 steps of that operation…" —
            // so this checks for a sentence rather than for a capital.
            let opener = try #require(sentence.first)
            #expect(opener.isUppercase || opener.isNumber,
                    "\(refusal) does not start a sentence: \(sentence)")
            #expect(sentence.hasSuffix("."), "\(refusal) is not a sentence: \(sentence)")
        }
        #expect(BrowserModel.describe(refusal: .unsettled(rows: 3)).contains("3"))
        #expect(BrowserModel.describe(refusal: .someItemsFailed(rows: 1)).contains("1"))
        #expect(BrowserModel.describe(refusal: .permanentDelete)
            .localizedCaseInsensitiveContains("permanently"))
    }

    /// ⌘Z is off with nothing to reverse, and off while the window is busy —
    /// the same "may work start" gate the four batch commands share.
    @Test func undoIsOffWithNothingToReverseAndWhileTheWindowIsBusy() async throws {
        let root = try tree.directory("library")
        try tree.file("library/IMG_0001.jpg", bytes: 16)
        let store = try IndexStore.inMemory()
        let model = model(store)
        await model.open(root)

        #expect(!model.canUndo, "⌘Z is live before anything has been done")
        #expect(model.undoMenuTitle == "Undo")

        model.lastCompletedBatch = CompletedBatch(batchID: "b", kind: .move,
                                                  results: [], isReversal: false)
        #expect(model.canUndo)

        model.batchProgress = BatchProgress(kind: .move, completed: 1, total: 9, current: nil)
        #expect(!model.canUndo, "⌘Z is live while a batch is running")
        model.batchProgress = nil

        model.activeSheet = .confirmPermanentDelete(count: 1)
        #expect(!model.canUndo, "⌘Z is live under a sheet")
        model.dismissSheet()
        #expect(model.canUndo)
    }
}
