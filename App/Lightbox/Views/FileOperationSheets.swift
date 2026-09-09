import SwiftUI
import LightboxCore

/// Whichever of the four sheets `BrowserModel.activeSheet` is naming.
///
/// One switch and one `.sheet(item:)` on `BrowserView`. The views below are
/// deliberately thin: every decision they present — what a collision is, what a
/// failure means, whether Retry is offered — is answered by `CollisionSheetModel`
/// or `OperationSummary`, which are plain types with tests.
struct FileOperationSheetView: View {
    @Bindable var model: BrowserModel
    let sheet: ActiveSheet

    var body: some View {
        switch sheet {
        case .collisions(let collisions):
            CollisionSheet(model: model, sheet: collisions)
        case .progress:
            BatchProgressSheet(model: model)
        case .summary(let summary):
            OperationSummarySheet(model: model, summary: summary)
        case .confirmPermanentDelete(let count):
            PermanentDeleteSheet(model: model, count: count)
        case .batchTime:
            BatchTimeSheet(model: model)
        case .confirmMetadataClear(let field, let count):
            MetadataClearSheet(model: model, field: field, count: count)
        case .metadataSummary(let summary):
            MetadataSummarySheet(model: model, summary: summary)
        }
    }
}

// MARK: - Collisions

/// Spec §8: skip / rename / replace, per item or applied to all, and **nothing
/// runs until this comes back with every one of them answered**.
private struct CollisionSheet: View {
    @Bindable var model: BrowserModel
    let sheet: CollisionSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(sheet.collidingIndices.count) name conflicts")
                .font(.headline)
            Text("Choose what to do with each. Nothing is moved until every "
                + "conflict has an answer.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("Apply to all:")
                ForEach(CollisionResolution.allCases, id: \.self) { resolution in
                    Button(Self.title(resolution)) { sheet.resolveAll(with: resolution) }
                        // Replace is withheld from the bulk control whenever any
                        // item's claim came from the batch itself: `Core` would
                        // degrade it to rename for those, and a button whose
                        // effect differs per row is worse than no button.
                        .disabled(resolution == .replace && !bulkReplaceIsMeaningful)
                }
                Spacer()
            }
            .font(.callout)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sheet.collidingIndices, id: \.self) { index in
                        row(index)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 160, maxHeight: 320)

            Divider()

            HStack {
                if !sheet.isFullyResolved {
                    Text("\(sheet.pendingIndices.count) still unanswered")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    Task { await model.continueWithResolvedPlan() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!sheet.isFullyResolved)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var bulkReplaceIsMeaningful: Bool {
        sheet.collidingIndices.allSatisfy { sheet.offersReplace(forItemAt: $0) }
    }

    @ViewBuilder
    private func row(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sheet.name(forItemAt: index)).font(.body.weight(.medium))
            Text(sheet.describeCollision(forItemAt: index))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(CollisionResolution.allCases, id: \.self) { resolution in
                    let chosen = sheet.resolution(forItemAt: index) == resolution
                    Button(Self.title(resolution)) {
                        sheet.resolve(itemAt: index, with: resolution)
                    }
                    .buttonStyle(.bordered)
                    .tint(chosen ? .accentColor : nil)
                    .disabled(resolution == .replace && !sheet.offersReplace(forItemAt: index))
                }
                if let name = sheet.destinationName(forItemAt: index),
                   sheet.resolution(forItemAt: index) == .rename {
                    Text("→ \(name)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    private static func title(_ resolution: CollisionResolution) -> String {
        switch resolution {
        case .skip: "Skip"
        case .rename: "Rename"
        case .replace: "Replace"
        }
    }
}

// MARK: - Progress

/// One cancellable indicator per batch, in the window that started it.
///
/// Cancel stops the batch after the item it is on; the items already finished
/// stay finished, because they are on disk and in the journal. That is why the
/// button says what it does rather than "Stop".
private struct BatchProgressSheet: View {
    @Bindable var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress = model.batchProgress {
                Text(progress.title).font(.headline)
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                Text("\(progress.completed) of \(progress.total)"
                    + (progress.current.map { " — \($0.lastPathComponent)" } ?? ""))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                // The window between the last item and the sheet being taken
                // down. Worded rather than blank.
                Text("Finishing…").font(.headline)
            }

            HStack {
                Spacer()
                // `canCancelBatch`, not `batchProgress != nil`: the sheet is
                // presented a moment before the batch has a `Task`, and a live
                // button that silently does nothing is worse than one that is
                // briefly off.
                Button("Stop After This Item") { model.cancelBatch() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!model.canCancelBatch)
            }
        }
        .padding(20)
        .frame(width: 460)
        // The batch is running; dismissing the sheet would leave it running
        // with nothing on screen and no way to stop it.
        .interactiveDismissDisabled()
    }
}

// MARK: - Summary

/// Shown only when at least one item failed — spec §11: a batch never fails as
/// a unit, and the sheet reports the exceptions.
private struct OperationSummarySheet: View {
    @Bindable var model: BrowserModel
    let summary: OperationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary.headline).font(.headline)
            if summary.planningFailure == nil {
                Text("\(summary.completedCount) completed"
                    + (summary.skippedCount > 0 ? ", \(summary.skippedCount) skipped" : "")
                    + ".")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !summary.failures.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(summary.failures) { failure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.source.lastPathComponent)
                                    .font(.body.weight(.medium))
                                Text(failure.reason)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 120, maxHeight: 300)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { model.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                if summary.canRetry {
                    Button("Retry Failed") {
                        Task { await model.retryFailedItems() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - Permanent delete

/// Spec §8: permanent delete is behind a confirmation naming the file count.
private struct PermanentDeleteSheet: View {
    @Bindable var model: BrowserModel
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete \(count) \(count == 1 ? "item" : "items") permanently?")
                .font(.headline)
            Text("This does not go to the Trash and cannot be undone. Companion "
                + "files travelling with the selection are deleted too.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete Permanently", role: .destructive) {
                    Task { await model.beginBatch(.delete, destination: nil) }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
