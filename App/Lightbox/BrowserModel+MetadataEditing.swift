import Foundation
import LightboxCore

/// The window's side of spec §9: turn a committed inspector field into a
/// validated request, run it through `MetadataWriter` off the main thread with
/// the same progress sheet a move gets, and put the window back together.
///
/// **A metadata batch is a batch.** It takes the same `batchToken` /
/// `batchTask` / `isBatchStarting` discipline, the same `present(_:)` sheet
/// swap and the same Stop button as `BrowserModel+FileOperations.swift`,
/// because the failure modes are the same ones: a progress indicator that
/// outlives its batch, two batches interleaving index writes, a `.sheet(item:)`
/// asked for a new item while one is up. What it does *not* share is the
/// journal — `MetadataWriter` writes no `op_journal` rows — so nothing here
/// touches `lastCompletedBatch`, and the inspector says in words that ⌘Z will
/// not reverse a metadata edit in this phase.
///
/// **The grid reloads from the index, never rescans.** `MetadataWriter` is
/// handed the store and rewrites each edited row's size, mtime and hashes as
/// part of the write, so by the time a batch returns the index already
/// describes the files on disk. A `refresh()` here would re-walk the folder —
/// minutes on an external drive — to learn it again.
extension BrowserModel {
    // MARK: - Availability

    /// The writer for this window, built on first use.
    ///
    /// Lazily, and never in `init`: `MetadataWriter.availability` forks
    /// `exiftool -ver`, and a window that pays for that before it has drawn is
    /// a window that stalls on launch for a feature the user may not touch.
    var metadataEditor: any MetadataWriting {
        if let metadataWriter { return metadataWriter }
        let live = LiveMetadataWriter(store: store)
        metadataWriter = live
        return live
    }

    /// Spec §11: exiftool absent disables editing *with an explanation*, and
    /// leaves browsing and search alone.
    ///
    /// Nil until `resolveMetadataAvailability()` has answered. The inspector
    /// renders read-only in that window too — an unresolved probe is not
    /// permission to write.
    var isMetadataEditingAvailable: Bool { metadataAvailability?.isAvailable ?? false }

    /// The sentence shown where the editing controls would be, or nil while the
    /// answer is still being fetched or the answer is yes.
    var metadataUnavailableExplanation: String? {
        guard let metadataAvailability, !metadataAvailability.isAvailable else { return nil }
        return metadataAvailability.explanation
    }

    /// Resolves the probe once per window, or again on request.
    ///
    /// - Parameter recheck: for the *Try Again* button. The explanation says
    ///   "install it, then try again", and a cached answer would make that
    ///   instruction a lie.
    func resolveMetadataAvailability(recheck: Bool = false) async {
        let writer = metadataEditor
        guard recheck || metadataAvailability == nil else { return }
        let answer = recheck
            ? await writer.recheckAvailability()
            : await writer.availability()
        metadataAvailability = answer
    }

    // MARK: - Committing

    /// Whether the inspector's fields accept a keystroke at all.
    var canEditMetadata: Bool { isMetadataEditingAvailable && !selection.selected.isEmpty }

    /// Whether a metadata batch may start right now. `canStartWork` is the
    /// shared rule — no batch in flight, no sheet waiting on an answer.
    var canStartMetadataBatch: Bool { canEditMetadata && canStartWork }

    /// Commits one field across the whole selection.
    ///
    /// Returns the refusal when the request could not be built, so the
    /// inspector can put a sentence under the field. A refusal never starts a
    /// batch and never reaches the writer: `MetadataWriter.validate` would
    /// refuse the same inputs, but it would do so once per file, as N identical
    /// rows in a summary sheet, for a typo in one box.
    @discardableResult
    func commitMetadataField(_ edit: MetadataFieldEdit) async -> MetadataEditRefusal? {
        guard canStartWork else { return .busy }
        return await apply(MetadataEditRequest.build(edit, for: selectedRecords))
    }

    /// Raises the batch time sheet — spec §9's set / shift / assign-a-sequence.
    func openBatchTimeSheet() {
        guard canStartMetadataBatch else { return }
        activeSheet = .batchTime
    }

    /// Spec §9's batch time operations, from that sheet.
    ///
    /// `selectedRecords` is in the grid's display order, which is what
    /// `.sequence` numbers by — the operation exists to re-time a burst the way
    /// it is shown.
    ///
    /// **`canStartWork` is deliberately not consulted here**, unlike a field
    /// commit: the sheet asking the question *is* the sheet on screen, so that
    /// rule would refuse every press of Apply. A batch already running is still
    /// refused, and `present(.progress)` performs the sheet swap — nil, yield,
    /// present — that `.sheet(item:)` needs to take one sheet down and another
    /// up without ending with neither.
    @discardableResult
    func applyBatchTimeOperation(_ operation: BatchTimeOperation) async -> MetadataEditRefusal? {
        guard !isBatchRunning else { return .busy }
        return await apply(MetadataEditRequest.build(operation, for: selectedRecords))
    }

    private func apply(
        _ built: Result<MetadataEditRequest, MetadataEditRefusal>
    ) async -> MetadataEditRefusal? {
        // **Checked before the request is even looked at.** Without this a
        // window whose probe came back `.notFound` still forks a batch that
        // fails every item with the same sentence the inspector is already
        // showing.
        guard isMetadataEditingAvailable else { return .editingUnavailable }
        guard !selection.selected.isEmpty else { return .noSelection }
        switch built {
        case .failure(let refusal):
            return refusal
        case .success(let request):
            guard !request.isEmpty else { return .nothingToWrite }
            await run(request)
            return nil
        }
    }

    // MARK: - Running

    /// A progress handler for one group of a metadata batch.
    ///
    /// **Built out here, not inside the batch's `Task`**, for the reason
    /// `BrowserModel+FileOperations.progressHandler(kind:token:)` gives: a
    /// `[weak self]` nested inside another closure's `[weak self]` is weakening
    /// an already-optional binding, which is not a thing. One handler per
    /// group, all of them built before the task starts, because `base` — how
    /// many files earlier groups accounted for — is known up front.
    ///
    /// `base + completed` is what makes a sequence's progress move: a sequence
    /// is N groups of one, each counting from 1 again, and a sheet fed those
    /// directly would sit at "1 of 5" for the whole run.
    private func metadataProgressHandler(token: Int, base: Int, total: Int,
                                         urls: [URL]) -> @Sendable (Int, Int) -> Void {
        { [weak self] completed, _ in
            Task { @MainActor in
                guard let self, self.batchToken == token else { return }
                let current = completed > 0 && completed <= urls.count
                    ? urls[completed - 1] : nil
                self.batchProgress = BatchProgress(kind: .metadata,
                                                   completed: base + completed,
                                                   total: total, current: current)
            }
        }
    }

    private func run(_ request: MetadataEditRequest) async {
        // Set synchronously, before any suspension, for the reason
        // `isBatchRunning` gives: between the commit and the first `await`
        // there is otherwise a window in which a second commit sees nothing
        // running and starts a second batch over the same files.
        isBatchStarting = true
        batchToken += 1
        let token = batchToken
        let total = request.fileCount
        batchProgress = BatchProgress(kind: .metadata, completed: 0, total: total, current: nil)
        await present(.progress)

        let writer = metadataEditor
        let groups = request.groups
        var handlers: [@Sendable (Int, Int) -> Void] = []
        var base = 0
        for group in groups {
            handlers.append(metadataProgressHandler(token: token, base: base,
                                                    total: total, urls: group.urls))
            base += group.urls.count
        }

        let task = Task { [weak self] in
            var outcomes: [WriteOutcome] = []
            outcomes.reserveCapacity(total)
            var cancelled = false

            for (index, group) in groups.enumerated() {
                // Between groups, never inside one. A group is one
                // `MetadataWriter.write` call, and that call checks
                // cancellation between its own items; what it will not do is
                // abandon a file half-written.
                if Task.isCancelled {
                    cancelled = true
                    outcomes.append(contentsOf: group.urls.map {
                        WriteOutcome(source: $0, result: .failure(.cancelled))
                    })
                    continue
                }
                outcomes.append(contentsOf: await writer.write(group.edit, to: group.urls,
                                                               progress: handlers[index]))
            }
            if Task.isCancelled { cancelled = true }
            await self?.finish(outcomes, cancelled: cancelled)
        }
        batchTask = task
        await task.value
    }

    private func finish(_ outcomes: [WriteOutcome], cancelled: Bool) async {
        endBatch()

        // **`lastCompletedBatch` is deliberately not written.** A metadata edit
        // has no `op_journal` rows, so there is nothing for `FileOperator.undo`
        // to reverse; recording it would leave ⌘Z offering to undo this write
        // and actually reversing whatever file operation came before it.

        // See this extension's own documentation for why this is `reload()`.
        await reload()

        let summary = MetadataSummary(outcomes: outcomes, wasCancelled: cancelled)
        await present(summary.isWorthShowing ? .metadataSummary(summary) : nil)
    }
}
