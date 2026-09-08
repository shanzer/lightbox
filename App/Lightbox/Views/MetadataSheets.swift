import SwiftUI
import LightboxCore

// MARK: - Batch time operations

/// Spec §9's three batch time operations, in one sheet.
///
/// Each is a different question — an instant, a displacement, an instant plus a
/// stride — so each gets its own controls rather than one set of boxes whose
/// meaning changes with the picker. The zone is present on the two that write
/// an absolute instant and absent from the shift, which keeps every file's own
/// zone: a shift fixes a clock, it does not move photos between zones.
struct BatchTimeSheet: View {
    @Bindable var model: BrowserModel

    private enum Mode: String, CaseIterable, Identifiable {
        case set, shift, sequence
        var id: String { rawValue }
        var title: String {
            switch self {
            case .set: "Set to"
            case .shift: "Shift by"
            case .sequence: "Sequence"
            }
        }
    }

    @State private var mode: Mode = .set
    @State private var setWallClock = ""
    @State private var setOffset = ""
    @State private var shiftText = ""
    @State private var sequenceStart = ""
    @State private var sequenceOffset = ""
    @State private var sequenceInterval = "10"
    @State private var refusal: String?

    @FocusState private var focused: BrowserModel.TextField?

    private var count: Int { model.selection.selected.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture time for \(count) \(count == 1 ? "image" : "images")")
                .font(.headline)

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                switch mode {
                case .set:
                    field("Date and time", text: $setWallClock,
                          prompt: WallClock.placeholder, id: .batchTimeSet)
                    field("Time zone", text: $setOffset, prompt: "-05:00", id: .batchTimeSetZone)
                case .shift:
                    field("Seconds", text: $shiftText,
                          prompt: ShiftAmount.placeholder, id: .batchTimeShift)
                    Text("Each image keeps its own time zone; only the instant moves.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .sequence:
                    field("Start at", text: $sequenceStart,
                          prompt: WallClock.placeholder, id: .batchTimeSequenceStart)
                    field("Time zone", text: $sequenceOffset, prompt: "-05:00",
                          id: .batchTimeSequenceZone)
                    field("Interval (seconds)", text: $sequenceInterval, prompt: "10",
                          id: .batchTimeSequenceInterval)
                    Text("Numbered in the order the grid is sorted in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 200)

            if let refusal {
                Text(refusal)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(MetadataInspectorCopy.notUndoable)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            // The zone is shown, never assumed — spec §9, constraint 1, and the
            // reason this sheet has a zone box at all.
            let offset = MetadataEditRequest.defaultOffset(for: model.selectedRecords)
            if setOffset.isEmpty { setOffset = offset }
            if sequenceOffset.isEmpty { sequenceOffset = offset }
        }
    }

    /// The shared builder — see `MetadataTextField`. One place calls
    /// `reportingTextFocus`, so there is one place to forget it and a test that
    /// walks it.
    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, prompt: String,
                       id: BrowserModel.TextField) -> some View {
        MetadataTextField(label: label, text: text, prompt: prompt, id: id,
                          focused: $focused, model: model)
    }

    private func apply() {
        guard let operation = operation() else { return }
        Task {
            if let failure = await model.applyBatchTimeOperation(operation) {
                refusal = failure.message
            }
        }
    }

    /// Nil only for the two numeric boxes, whose refusals are decided here
    /// because `BatchTimeOperation` carries an `Int` — everything else is
    /// refused by `MetadataEditRequest.build`, so the sheet and the writer
    /// cannot disagree about what a valid capture time is.
    private func operation() -> BatchTimeOperation? {
        refusal = nil
        switch mode {
        case .set:
            return .set(wallClock: setWallClock, offset: setOffset)
        case .shift:
            guard let seconds = ShiftAmount.parseSeconds(shiftText) else {
                refusal = MetadataEditRefusal.invalidShift(shiftText).message
                return nil
            }
            return .shift(seconds: seconds)
        case .sequence:
            let trimmed = sequenceInterval.trimmingCharacters(in: .whitespaces)
            guard let interval = Int(trimmed), interval > 0 else {
                refusal = MetadataEditRefusal.invalidInterval(sequenceInterval).message
                return nil
            }
            return .sequence(startWallClock: sequenceStart, offset: sequenceOffset,
                             intervalSeconds: interval)
        }
    }
}

// MARK: - Metadata summary

/// A metadata batch's report. Up only when there is something to report — see
/// `MetadataSummary.isWorthShowing`.
struct MetadataSummarySheet: View {
    @Bindable var model: BrowserModel
    let summary: MetadataSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary.headline).font(.headline)
            if let note = summary.notReachedNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if summary.sidecars > 0 {
                Text("\(summary.sidecars) of them were written to an .xmp sidecar; "
                    + "the RAW files themselves were not opened.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !summary.failures.isEmpty {
                Divider()
                rows(summary.failures)
            }
            if !summary.notes.isEmpty {
                Divider()
                Text("Worth knowing").font(.callout.weight(.medium))
                rows(summary.notes)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { model.dismissSheet() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func rows(_ rows: [MetadataSummary.Row]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.source.lastPathComponent).font(.body.weight(.medium))
                        Text(row.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .frame(minHeight: 80, maxHeight: 220)
    }
}

/// Sentences the inspector and the batch sheet both say, in one place so they
/// cannot drift apart.
enum MetadataInspectorCopy {
    /// The issue's constraint, said out loud rather than discovered: a metadata
    /// edit writes no `op_journal` rows, so there is nothing for ⌘Z to reverse.
    static let notUndoable = "Metadata edits are not undoable with ⌘Z in this phase."

    static let installCommand = "brew install exiftool"

    /// The confirmation in front of an erase. Says "erase", not "clear the
    /// field": the field is a box on screen and the tag is in the user's files,
    /// and only one of the two is about to change.
    static func clearWarning(field: MetadataField, count: Int) -> String {
        "\(field.title) will be erased from \(count) \(count == 1 ? "file" : "files"). "
            + "Leaving the box empty does nothing; this is how the tag is removed. "
            + "It cannot be undone with ⌘Z."
    }
}

// MARK: - Clearing a field

/// The confirmation in front of erasing one field across the selection.
///
/// **Blank means unchanged**, so this is the only way a tag is removed — and it
/// asks first, for the reasons a permanent delete does: it acts on everything
/// selected, it rewrites every one of those files, and no ⌘Z will put the tag
/// back.
struct MetadataClearSheet: View {
    @Bindable var model: BrowserModel
    let field: MetadataField
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Erase \(field.title) from \(count) \(count == 1 ? "item" : "items")?")
                .font(.headline)
            Text(MetadataInspectorCopy.clearWarning(field: field, count: count))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Erase", role: .destructive) {
                    Task { await model.clearMetadataField(field) }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
