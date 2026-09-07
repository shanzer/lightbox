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
    var isBatchRunning: Bool { batchProgress != nil }

    /// Whether `command` can act right now.
    ///
    /// The single rule behind all four menu items. Keyed on `FileCommand` so
    /// the menu and this cannot drift: `MenuCommandTests` walks `allCases`
    /// against the real `NSMenu`, and `FileOperationBatchTests` walks them
    /// against a real selection.
    func isEnabled(_ command: FileCommand) -> Bool {
        guard !selection.selected.isEmpty else { return false }
        // Not "queue it up": two batches interleaving index writes over the
        // same rows is the one thing the journal ordering cannot describe.
        return !isBatchRunning
    }

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
    /// Returns when the batch is over, so a caller — a test, or the sheet's
    /// Continue button — can await the whole thing. The UI never blocks on it:
    /// the menu commands start it in a detached `Task`.
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
    /// Skips are deliberately not retried. A skip is either what the user asked
    /// for at collision time, or a volume that went away — and retrying that in
    /// the same breath fails the same way, at the same file, for the same
    /// reason.
    func retryFailedItems() async {
        guard case .summary(let summary)? = activeSheet, summary.canRetry else { return }
        activeSheet = nil
        await planAndRun(kind: summary.kind, sources: summary.failedSources,
                         destination: summary.destinationDirectory)
    }

    /// Dismisses whatever sheet is up, abandoning it. The batch itself is
    /// stopped with `cancelBatch()`; this only closes a question.
    func dismissSheet() {
        activeSheet = nil
    }

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
        let op = fileOperator
        let companions = includeCompanions
        do {
            let plan = try await op.plan(kind: kind, sources: sources,
                                         destination: destination,
                                         includeCompanions: companions)
            if plan.hasUnresolvedCollisions {
                // Nothing runs until this sheet comes back resolved — spec §8's
                // "no batch discovers a collision at file 300".
                activeSheet = .collisions(CollisionSheetModel(plan: plan))
            } else {
                await run(plan)
            }
        } catch {
            activeSheet = .summary(OperationSummary(
                kind: kind, destinationDirectory: destination,
                planningFailure: Self.describe(planningError: error)))
        }
    }

    // MARK: - Running

    private func run(_ plan: FileOperationPlan) async {
        batchToken += 1
        let token = batchToken
        batchProgress = BatchProgress(kind: plan.kind, completed: 0,
                                      total: plan.items.count, current: nil)
        activeSheet = .progress

        let op = fileOperator
        // Built here rather than inline in the `Task` below, so its `[weak
        // self]` weakly captures the model itself: a capture list nested inside
        // another closure's `[weak self]` would be weakening an already-optional
        // binding, which is not a thing.
        //
        // Hopped, not assigned: the handler is called on the operator's own
        // queue, once per finished item, and `batchProgress` is main-actor state.
        let onProgress: FileOperator.ProgressHandler = { [weak self] completed, total, current in
            Task { @MainActor in
                guard let self, self.batchToken == token else { return }
                self.batchProgress = BatchProgress(kind: plan.kind, completed: completed,
                                                   total: total, current: current)
            }
        }
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
        // Bumped before the progress is cleared, so a callback still in flight
        // for this batch cannot resurrect the indicator it belongs to.
        batchToken += 1
        batchProgress = nil
        batchTask = nil

        let completed = results.filter(\.isCompleted)
        // A permanent delete is never remembered: nothing can undo it, and an
        // Undo item offering to is a lie with the worst possible payload.
        if !completed.isEmpty, plan.kind != .delete {
            lastCompletedBatch = CompletedBatch(batchID: plan.batchID, kind: plan.kind,
                                                results: completed)
        }

        // The index already knows. See this extension's own documentation for
        // why this is `reload()` and not `refresh()`.
        await reload()
        follow(plan: plan, completed: completed)

        if let planningFailure {
            activeSheet = .summary(OperationSummary(
                kind: plan.kind, destinationDirectory: plan.destinationDirectory,
                planningFailure: planningFailure))
            return
        }
        let summary = OperationSummary(kind: plan.kind,
                                       destinationDirectory: plan.destinationDirectory,
                                       results: results, wasCancelled: cancelled)
        // Shown only when something failed. A batch that did what it was told
        // does not need a sheet dismissed before the user can carry on.
        activeSheet = summary.failures.isEmpty ? nil : .summary(summary)
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
