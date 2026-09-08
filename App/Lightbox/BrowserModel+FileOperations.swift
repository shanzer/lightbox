import Foundation
import LightboxCore

/// The window's side of spec §8: turn a selection and a command into a plan,
/// get the collisions answered, run the batch off the main thread with a
/// cancellable progress indicator, and then put the window back together.
///
/// **`FileOperator` is an actor with its own executor** — every filesystem call
/// in it is blocking, and a batch of 300 files is the largest lump of blocking
/// work in `Core` (#28). Nothing here awaits it on the main actor's behalf
/// beyond the hop the `await` already implies; the batch itself runs on the
/// operator's queue and reports back through a handler that hops to
/// `@MainActor`, which is the same shape as the indexing and hashing calls
/// above.
///
/// **The grid is refreshed from the index, never by rescanning.** `FileOperator`
/// rewrites the rows in the same transaction that marks the journal complete, so
/// by the time a batch returns the index already describes the new state of the
/// world. A `refresh()` here would re-walk the whole folder — minutes on an
/// external drive — to learn something the index was told half a millisecond
/// ago.
extension BrowserModel {
    // MARK: - Command availability

    /// Whether a batch is in flight in this window.
    ///
    /// **Two flags, not one.** `batchProgress` is set in `run`, which is on the
    /// far side of `await FileOperator.plan(...)`, so between the click and the
    /// plan coming back there is a real window in which a second click sees
    /// nothing running. Both batches then plan over the same sources — both see
    /// them present — the first moves them, and the second reports every one of
    /// the user's photos as vanished. `isBatchStarting` is set synchronously,
    /// before the first suspension, and closes it.
    var isBatchRunning: Bool { isBatchStarting || batchProgress != nil }

    /// Whether `command` can act right now.
    ///
    /// The single rule behind all four menu items. Keyed on `FileCommand` so
    /// the menu and this cannot drift: `MenuCommandTests` walks `allCases`
    /// against the real `NSMenu`, and `FileOperationBatchTests` walks them
    /// against a real selection.
    func isEnabled(_ command: FileCommand) -> Bool {
        guard !selection.selected.isEmpty else { return false }
        return canStartWork
    }

    /// Whether the window is free to start work at all.
    ///
    /// Shared by the four batch commands and by ⌘Z, which differ only in what
    /// else they need — a selection for the first, something to reverse for the
    /// second.
    ///
    /// Two conditions. Not "queue it up" for the first: two batches
    /// interleaving index writes over the same rows is the one thing the
    /// journal ordering cannot describe. And **a SwiftUI sheet is not run-loop
    /// modal** for the second: a menu key equivalent is matched by the menu bar
    /// whatever is on screen, so ⌘⌫ pressed over the collision sheet would
    /// reach Move to Trash and start a batch — whose `run` overwrites
    /// `activeSheet` with `.progress`, discarding the half-answered plan behind
    /// it with no way back. The sheets are questions the window is waiting on;
    /// nothing else may act until one is answered.
    var canStartWork: Bool { !isBatchRunning && activeSheet == nil }

    /// Whether ⌘Z has something to reverse.
    ///
    /// No selection required, unlike the batch commands: undo acts on the last
    /// batch, not on what happens to be highlighted now — and after a trash or
    /// a move out of scope there is nothing highlighted at all.
    var canUndo: Bool { lastCompletedBatch != nil && canStartWork }

    /// The selected photos as file URLs, in display order.
    var selectedURLs: [URL] {
        selectedRecords.map { URL(fileURLWithPath: $0.path) }
    }

    // MARK: - Starting a batch

    /// Puts the confirmation in front of a permanent delete.
    ///
    /// Spec §8: permanent delete is a separate command behind a confirmation
    /// naming the file count. The count comes from the selection rather than
    /// from a plan, because the plan is only built once the user has said yes —
    /// there is no point listing the companions of files nobody has agreed to
    /// destroy yet.
    func confirmPermanentDelete() {
        guard isEnabled(.deletePermanently) else { return }
        activeSheet = .confirmPermanentDelete(count: selection.selected.count)
    }

    /// Plans `kind` over the current selection and either asks about the
    /// collisions or runs it.
    ///
    /// Returns when the batch is over, or when the collision sheet has been
    /// raised — those are the two ways this ends, and a caller awaiting it (a
    /// test, or the sheet's Continue button) gets whichever happened. The UI
    /// never blocks on it: the menu commands start it in a detached `Task`.
    func beginBatch(_ kind: FileOperationKind, destination: URL?) async {
        guard !isBatchRunning else { return }
        await planAndRun(kind: kind, sources: selectedURLs, destination: destination)
    }

    /// Runs the plan the collision sheet has finished resolving.
    func continueWithResolvedPlan() async {
        guard case .collisions(let sheet)? = activeSheet, sheet.isFullyResolved else { return }
        await run(sheet.plan)
    }

    /// Retry Failed: the same batch again, over the items that failed and
    /// nothing else.
    ///
    /// Skips are deliberately not retried — a skip is the user's own choice at
    /// collision time, or a volume that has gone away, and neither is improved
    /// by trying again in the same breath.
    func retryFailedItems() async {
        guard case .summary(let summary)? = activeSheet, summary.canRetry else { return }
        activeSheet = nil
        await planAndRun(kind: summary.kind, sources: summary.failedSources,
                         destination: summary.destinationDirectory)
    }

    // MARK: - Undo

    /// ⌘Z: reverses the last batch this window completed, or says why it cannot.
    ///
    /// **Asks before acting.** `FileOperator.undoability(of:)` is consulted
    /// first and its refusal is shown, because the refusal that matters —
    /// a permanent delete — is worthless after the fact. `undo(batch:)` would
    /// throw the same refusal before touching anything, so the pre-check is not
    /// what makes this safe; it is what makes it *explicable*. A ⌘Z that
    /// silently did nothing would read as a broken menu item.
    ///
    /// The reversal runs as an ordinary batch — its own `batch_id`, its own
    /// journal rows, the same progress sheet and the same summary — which is
    /// also why redo needs nothing further: `lastCompletedBatch` becomes the
    /// reversal, and reversing *that* is the redo.
    func undoLastBatch() async {
        guard let batch = lastCompletedBatch, canStartWork else { return }
        isBatchStarting = true
        let op = fileOperator
        do {
            let undoability = try await op.undoability(of: batch.batchID)
            guard undoability.isUndoable else {
                isBatchStarting = false
                await present(.summary(OperationSummary(
                    kind: batch.kind, destinationDirectory: nil,
                    planningFailure: Self.describe(refusal: undoability.refusal))))
                return
            }
            await runUndo(batch, undoability: undoability)
        } catch {
            isBatchStarting = false
            await present(.summary(OperationSummary(
                kind: batch.kind, destinationDirectory: nil,
                planningFailure: Self.describe(planningError: error))))
        }
    }

    /// Dismisses whatever sheet is up, abandoning it. The batch itself is
    /// stopped with `cancelBatch()`; this only closes a question.
    func dismissSheet() {
        activeSheet = nil
    }

    /// Whether there is a batch in flight for Stop to act on.
    ///
    /// Not the same as `isBatchRunning`, and the gap is real: `run` presents the
    /// progress sheet before it has a `Task`, so for the length of that
    /// presentation `cancelBatch()` would be a silent no-op on a live-looking
    /// button. Reordering was the other option and is worse — the `Task` would
    /// then be able to finish and present the summary *before* `present(.progress)`
    /// ran, leaving a progress sheet over a finished batch. A briefly disabled
    /// Stop is the honest reading: there is nothing to stop yet.
    var canCancelBatch: Bool { batchTask != nil }

    /// Stops the batch after the item it is on.
    ///
    /// Not during one: `FileOperator` checks cancellation between items and
    /// never inside one, so a half-written file is not a state this can produce.
    /// Everything already done stays done and stays journalled.
    func cancelBatch() {
        batchTask?.cancel()
    }

    private func planAndRun(kind: FileOperationKind, sources: [URL],
                            destination: URL?) async {
        guard !sources.isEmpty else { return }
        // Set here, synchronously, before the `await` below — see
        // `isBatchRunning`. Cleared on every way out: the collision branch
        // below, the catch, and `finish`.
        isBatchStarting = true
        let op = fileOperator
        let companions = includeCompanions
        do {
            let plan = try await op.plan(kind: kind, sources: sources,
                                         destination: destination,
                                         includeCompanions: companions)
            if plan.hasUnresolvedCollisions {
                // Nothing runs until this sheet comes back resolved — spec §8's
                // "no batch discovers a collision at file 300".
                isBatchStarting = false
                await present(.collisions(CollisionSheetModel(plan: plan)))
            } else {
                await run(plan)
            }
        } catch {
            isBatchStarting = false
            await present(.summary(OperationSummary(
                kind: kind, destinationDirectory: destination,
                planningFailure: Self.describe(planningError: error))))
        }
    }

    // MARK: - Sheets

    /// Puts `sheet` on screen, taking down whatever is there first.
    ///
    /// **A `.sheet(item:)` whose item changes identity while a sheet is up is
    /// the classic macOS failure mode**: AppKit is still presenting the old one
    /// when it is asked for the new one, and the window ends up with no sheet at
    /// all while the model believes one is showing — which here would mean a
    /// batch running with no progress indicator and no way to cancel it. Every
    /// swap this file makes is one of those: confirm-delete → progress,
    /// collisions → progress, progress → summary.
    ///
    /// Nil, yield, then present. The yield is what splits the two assignments
    /// into two SwiftUI update transactions, so the framework sees a dismissal
    /// and *then* a presentation rather than one identity change. It is the same
    /// shape `retryFailedItems` gets for free by suspending between its nil and
    /// its next sheet. `HANDOFF` §7.6 owes this a live check: nothing in an
    /// `xcodebuild test` run presents a real sheet, so the model's state is all
    /// a test here can see.
    private func present(_ sheet: ActiveSheet?) async {
        guard sheet != nil, activeSheet != nil else {
            activeSheet = sheet
            return
        }
        activeSheet = nil
        await Task.yield()
        activeSheet = sheet
    }

    // MARK: - Running

    /// A progress handler for the batch identified by `token`.
    ///
    /// Built outside the `Task` that uses it, so its `[weak self]` weakly
    /// captures the model itself: a capture list nested inside another
    /// closure's `[weak self]` would be weakening an already-optional binding,
    /// which is not a thing.
    ///
    /// Hopped, not assigned: the handler is called on the operator's own queue,
    /// once per finished item, and `batchProgress` is main-actor state. The
    /// token is what stops a report from the batch that just finished landing
    /// on the one that just started — see `batchToken`.
    private func progressHandler(kind: FileOperationKind,
                                 token: Int) -> FileOperator.ProgressHandler {
        { [weak self] completed, total, current in
            Task { @MainActor in
                guard let self, self.batchToken == token else { return }
                self.batchProgress = BatchProgress(kind: kind, completed: completed,
                                                   total: total, current: current)
            }
        }
    }

    /// Takes the window out of "a batch is running".
    ///
    /// The token is bumped **before** the progress is cleared, so a callback
    /// still in flight for this batch cannot resurrect the indicator it belongs
    /// to. One copy, because both endings need the same four assignments in the
    /// same order and a drifting second copy is how the indicator outlives its
    /// batch.
    private func endBatch() {
        batchToken += 1
        batchProgress = nil
        batchTask = nil
        isBatchStarting = false
    }

    private func run(_ plan: FileOperationPlan) async {
        batchToken += 1
        let token = batchToken
        batchProgress = BatchProgress(kind: plan.kind, completed: 0,
                                      total: plan.items.count, current: nil)
        await present(.progress)

        let op = fileOperator
        let onProgress = progressHandler(kind: plan.kind, token: token)
        let task = Task { [weak self] in
            do {
                let results = try await op.execute(plan, onProgress: onProgress)
                await self?.finish(plan, results: results, cancelled: false)
            } catch FileOperatorError.cancelled(let completed) {
                // A cancelled batch has done real work — files moved, rows
                // rewritten, journal rows marked — and the results carry it.
                await self?.finish(plan, results: completed, cancelled: true)
            } catch {
                await self?.finish(plan, results: [], cancelled: false,
                                   planningFailure: Self.describe(planningError: error))
            }
        }
        batchTask = task
        await task.value
    }

    /// Puts the window back together after a batch.
    private func finish(_ plan: FileOperationPlan, results: [FileOperationResult],
                        cancelled: Bool, planningFailure: String? = nil) async {
        endBatch()

        let completed = results.filter(\.isCompleted)
        // A permanent delete is never remembered: nothing can undo it, and an
        // Undo item offering to is a lie with the worst possible payload.
        if !completed.isEmpty, plan.kind != .delete {
            // `isReversal: false` — a batch the user asked for directly, so the
            // next ⌘Z undoes it rather than redoing anything. Only `finishUndo`
            // ever sets that flag.
            lastCompletedBatch = CompletedBatch(batchID: plan.batchID, kind: plan.kind,
                                                results: completed, isReversal: false)
        }

        // The index already knows. See this extension's own documentation for
        // why this is `reload()` and not `refresh()`.
        await reload()
        follow(plan: plan, completed: completed)

        await presentSummary(kind: plan.kind,
                             destinationDirectory: plan.destinationDirectory,
                             results: results, cancelled: cancelled,
                             planningFailure: planningFailure)
    }

    /// The tail both a batch and an undo end with.
    ///
    /// Shown only when something failed. A run that did what it was told does
    /// not need a sheet dismissed before the user can carry on — and that
    /// includes a clean cancel; see `OperationSummary.wasCancelled`.
    private func presentSummary(kind: FileOperationKind, destinationDirectory: URL?,
                                results: [FileOperationResult], cancelled: Bool,
                                planningFailure: String?) async {
        if let planningFailure {
            await present(.summary(OperationSummary(
                kind: kind, destinationDirectory: destinationDirectory,
                planningFailure: planningFailure)))
            return
        }
        let summary = OperationSummary(kind: kind,
                                       destinationDirectory: destinationDirectory,
                                       results: results, wasCancelled: cancelled)
        await present(summary.failures.isEmpty ? nil : .summary(summary))
    }

    // MARK: - Running an undo

    /// The reversal, driven exactly as a batch is: same token discipline, same
    /// progress sheet, same cancel, same summary.
    ///
    /// Separate from `run(_:)` rather than folded into it because the two
    /// differ in what they await and in what they leave behind — an undo has no
    /// plan, no destination directory, and a different rule for the selection.
    /// What they must not differ in is the state discipline around the batch,
    /// which is why `present(_:)`, `batchToken` and `batchTask` are used here in
    /// the same order and for the same reasons; see `run(_:)`.
    private func runUndo(_ batch: CompletedBatch, undoability: BatchUndoability) async {
        batchToken += 1
        let token = batchToken
        // **`batch.kind` wins once this is already a reversal.** `undoability`
        // reads the journal of the batch being undone, and a reversal's rows
        // are the machinery rather than the user's operation — undoing a copy
        // trashes, so the second press would read `.trash` and the item would
        // offer "Undo Trash 3 Items" for what the user knows as a copy. See
        // `CompletedBatch.kind`, which exists to say exactly this.
        let kind = batch.isReversal ? batch.kind : (undoability.kind ?? batch.kind)
        batchProgress = BatchProgress(kind: kind, completed: 0,
                                      total: undoability.items, current: nil)
        await present(.progress)

        let op = fileOperator
        let onProgress = progressHandler(kind: kind, token: token)
        let task = Task { [weak self] in
            do {
                let undone = try await op.undo(batch: batch.batchID, onProgress: onProgress)
                await self?.finishUndo(batch, kind: kind, reversalID: undone.batchID,
                                       results: undone.results, cancelled: false)
            } catch FileOperatorError.cancelled(let completed) {
                // A cancelled undo has put real files back, journalled under a
                // reversal id this side never learns — `undo` only returns it
                // on the way out — so `lastCompletedBatch` still names the
                // original batch.
                //
                // **That batch is still `complete` and still undoable**, and
                // pressing ⌘Z again re-runs the *whole* reversal: the items
                // already restored have no source left to move and come back as
                // per-item failures, while the rest are restored. Noisy — a
                // summary sheet listing failures for work that actually
                // succeeded — but it finishes the job and loses nothing, which
                // is why it is left alone rather than refused. Asserted by
                // `aSecondUndoAfterACancelledOneFinishesTheJobNoisily`, down to
                // the failure count.
                //
                // The reason differs by what was reversed, because `reverse`
                // reports a missing source by where it was looking
                // (`step.fromTrash`): `sourceVanished` after a move or a copy,
                // `trashEmptied` when the batch being reversed was a trash and
                // the file is already out of the Trash. The test covers the
                // move; the trash leg is read off `FileOperator+Undo`, not
                // measured here.
                // Refusing would mean tracking a reversal id that the
                // cancellation path does not produce, to prevent a second press
                // that repairs the state.
                await self?.finishUndo(batch, kind: kind, reversalID: nil,
                                       results: completed, cancelled: true)
            } catch let refusal as UndoRefusal {
                await self?.finishUndo(batch, kind: kind, reversalID: nil, results: [],
                                       cancelled: false,
                                       planningFailure: Self.describe(refusal: refusal))
            } catch {
                await self?.finishUndo(batch, kind: kind, reversalID: nil, results: [],
                                       cancelled: false,
                                       planningFailure: Self.describe(planningError: error))
            }
        }
        batchTask = task
        await task.value
    }

    /// Puts the window back together after an undo.
    ///
    /// `finish`'s counterpart, and it differs in exactly two places: what it
    /// remembers for the *next* ⌘Z — the reversal, with the flag flipped, which
    /// is the whole of the redo mechanism — and that the selection empties
    /// rather than following anything. `reversalID` is nil when there is
    /// nothing to remember: a refusal, or a cancellation, which never learns
    /// the id.
    private func finishUndo(_ batch: CompletedBatch, kind: FileOperationKind,
                            reversalID: String?, results: [FileOperationResult],
                            cancelled: Bool, planningFailure: String? = nil) async {
        endBatch()

        let completed = results.filter(\.isCompleted)
        // The reversal becomes what ⌘Z offers next, with the flag flipped so it
        // is offered as the redo. Only when the reversal is known and did
        // something: a refused or cancelled undo leaves the original standing,
        // which is what the user would press ⌘Z for next anyway.
        if let reversalID, !completed.isEmpty {
            lastCompletedBatch = CompletedBatch(batchID: reversalID, kind: kind,
                                                results: completed,
                                                isReversal: !batch.isReversal)
        }

        await reload()
        // **Emptied, not followed.** An undo is the one run whose items do not
        // share a direction: undoing a copy trashes files while undoing a move
        // restores them, and a reversal can put photos back into folders that
        // are not on screen at all. A selection that is right for some of them
        // and wrong for the rest is worse than none, and the grid has just been
        // reloaded so the user can see where everything landed.
        selection.clear()

        await presentSummary(kind: kind, destinationDirectory: nil, results: results,
                             cancelled: cancelled, planningFailure: planningFailure)
    }

    /// What the selection means once the files have moved.
    ///
    /// - trash and delete: nothing. The photos are gone; a selection is a set
    ///   of rows, and there are no rows.
    /// - move: the same photos at their new rows, when those are still in
    ///   scope. A move *out* of the folder on screen leaves nothing to follow,
    ///   and the selection empties rather than clinging to ids the grid no
    ///   longer draws.
    /// - copy: untouched. The sources did not go anywhere, and selecting the
    ///   copies instead would be a different gesture than the one the user made.
    private func follow(plan: FileOperationPlan, completed: [FileOperationResult]) {
        switch plan.kind {
        case .trash, .delete:
            selection.clear()
        case .copy:
            break
        case .move:
            let destinations = Set(completed.compactMap(\.destination?.path))
            guard !destinations.isEmpty else { return }
            let surviving = records.compactMap {
                destinations.contains($0.path) ? $0.id : nil
            }
            if surviving.isEmpty {
                selection.clear()
            } else {
                selection.selectAll(surviving)
            }
        }
    }

    // MARK: - Wording

    /// The sentence for an undo the operator will not perform.
    ///
    /// Here rather than on `UndoRefusal` in `Core`, for the same reason
    /// `FileOperatorError`'s wording is here: a refusal is a pre-flight answer
    /// to a caller, not a per-item outcome shown in a list. The distinction
    /// that decides it is whether the string ends up in the summary sheet's
    /// *rows* — those are `FileOperationFailure.explanation`, which is `Core`'s
    /// because only `Core` knows why its cases differ — or in its headline,
    /// which is window copy.
    ///
    /// Exhaustive with no `default`, deliberately: a case added by a later
    /// `Core` change must fail to compile here rather than reach the user as an
    /// empty sheet.
    static func describe(refusal: UndoRefusal?) -> String {
        switch refusal {
        case nil:
            // Unreachable — the caller checks `isUndoable` first — but a
            // fatalError in a menu action is not a trade worth making.
            return "That operation can be undone."
        case .noSuchBatch:
            return "There is no record of that operation any more, so it cannot be undone."
        case .permanentDelete:
            return "That operation deleted files permanently. Unlinking a file cannot "
                + "be reversed, which is why it asked first."
        case .unsettled(let rows):
            return "\(rows) step\(rows == 1 ? "" : "s") of that operation never recorded "
                + "what they did, so reversing it could act on files that never moved."
        case .reconciledAfterACrash(let rows):
            return "\(rows) step\(rows == 1 ? "" : "s") of that operation were worked out "
                + "from the disk after an interrupted run rather than recorded as they "
                + "happened. Reversing a reconstruction can lose a file, so it is refused."
        case .someItemsFailed(let rows):
            return "That operation had \(rows) failure\(rows == 1 ? "" : "s"), so it is not "
                + "one reversible unit. The items that succeeded stay where they are."
        case .nothingToUndo:
            return "Nothing in that operation was attempted, so there is nothing to reverse."
        }
    }

    /// The sentence for a batch that never started.
    ///
    /// `FileOperatorError` deliberately has no `explanation` in `Core`, unlike
    /// `FileOperationFailure`: its cases are pre-flight and caller-side —
    /// "this destination cannot be read", "this plan still has open
    /// collisions" — so the wording is window copy rather than a property of
    /// the taxonomy. The per-item reasons, which are a property of it, come
    /// from `FileOperationFailure.explanation`.
    private static func describe(planningError error: any Error) -> String {
        guard let error = error as? FileOperatorError else {
            return "The operation could not be started: \(error.localizedDescription)"
        }
        switch error {
        case .destinationUnreadable(let path):
            return "The destination folder could not be read: \(path)"
        case .sourceDirectoryUnreadable(let path):
            return "A folder holding one of the selected files could not be read, "
                + "so its companion files cannot be found: \(path)"
        case .destinationRequired:
            return "This operation needs a destination folder."
        case .destinationNotAllowed:
            return "This operation does not take a destination folder."
        case .unresolvedCollisions(let indices):
            return "\(indices.count) name conflicts were never answered, so nothing ran."
        case .cancelled:
            return "The batch was cancelled."
        }
    }
}
