import SwiftUI
import LightboxCore

/// What the index knows about the selected files, and — since #9 — the spec §9
/// fields the selection can be edited through.
///
/// With more than one row selected every read-only field shows the value they
/// agree on, or `(multiple values)` where they do not — the same rule the
/// Finder's multiple-item Get Info uses. **The editable fields follow the other
/// half of spec §10's sentence**: a commit applies across the whole selection,
/// as one `MetadataWriter` batch with the progress sheet, the Stop button and
/// the per-item summary a move gets.
///
/// Three things the editable half deliberately does *not* do:
///
/// - **It does not commit on blur.** Return applies; clicking away does not. A
///   blur-commit writes to every selected file the moment focus moves, which
///   for a 300-file selection is a batch nobody asked for. The fields say so.
/// - **A blank box means unchanged — every box, no exceptions**, and for the
///   two boxes that are pre-filled from the index the rule is stated against
///   what they were filled with (`CaptureTimeSeed`) rather than against the
///   empty string. `onSubmit`
///   fires on Return whether or not the text changed, so tabbing into an
///   untouched Artist box on a 300-file selection and pressing Return would
///   otherwise erase Artist on 300 files and rewrite every one of them, with no
///   ⌘Z behind it. Erasing a tag is the ✕ beside the box, behind a
///   confirmation. `MetadataField.isClearable` says which fields have one and
///   why the other three do not.
/// - **It does not show the current Artist, Copyright, Description, Keywords,
///   Rating, Label or GPS.** The index has no columns for them (`FileRecord`
///   carries capture time, zone, camera and dimensions and nothing else of
///   §9's set), and reading them would be one exiftool fork per selected file
///   on every selection change. The boxes are therefore *blank meaning
///   unchanged*, which their prompts say. Capture time and zone, which the
///   index does hold, are seeded from it.
/// - **It offers no undo.** A metadata edit writes no `op_journal` rows, so ⌘Z
///   has nothing to reverse, and the panel says that rather than leaving the
///   Edit menu's "Undo Move 3 Items" looking like it applies.
struct InspectorView: View {
    @Bindable var model: BrowserModel

    private var records: [FileRecord] { model.selectedRecords }

    /// Absent, agreed, or disagreed — three states, not two.
    ///
    /// Collapsing "every selected file agrees it has no camera" into the same
    /// nil that means "these files disagree" would put `(multiple values)`
    /// next to Camera for a folder of screenshots, none of which has a camera
    /// and all of which agree about it. `—` and `(multiple values)` are
    /// different claims about the data and the inspector has to be able to
    /// make both.
    private enum SharedValue {
        case value(String)
        case absent
        case mixed

        func map(_ transform: (String) -> String) -> SharedValue {
            switch self {
            case .value(let text): .value(transform(text))
            case .absent: .absent
            case .mixed: .mixed
            }
        }
    }

    // The editable drafts. Reset whenever the selection changes — a box still
    // holding the previous selection's text is a box one Return away from
    // writing it to the wrong photos.
    @State private var captureTimeDraft = ""
    @State private var captureZoneDraft = ""
    @State private var artistDraft = ""
    @State private var copyrightDraft = ""
    @State private var descriptionDraft = ""
    @State private var keywordsDraft = ""
    @State private var ratingDraft = ""
    @State private var labelDraft = ""
    /// Why the last *Choose…* was refused, or nil. Cleared by the next
    /// successful choice; not model state because it is about one interaction
    /// with one panel, not about the window (#51).
    @State private var exiftoolRefusal: String?
    @State private var latitudeDraft = ""
    @State private var longitudeDraft = ""
    @State private var refusal: String?
    /// What `reseed()` put in the capture-time pair, so a Return that changed
    /// neither box can be recognised as changing nothing — see
    /// `CaptureTimeSeed`.
    @State private var captureSeed: CaptureTimeSeed?

    @FocusState private var focused: BrowserModel.TextField?

    var body: some View {
        Form {
            if records.isEmpty {
                Text("No selection").foregroundStyle(.secondary)
            } else {
                Section(records.count == 1
                        ? records[0].name
                        : "\(records.count) images selected") {
                    row("Dimensions", shared { record in
                        guard let width = record.width, let height = record.height else {
                            return nil
                        }
                        return "\(width) × \(height)"
                    })
                    row("Size", shared {
                        ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file)
                    })
                    // **These two go stale after a capture-time edit, and that
                    // is issue #42.** `IndexStore.recordMetadataWrite` rewrites
                    // the row's size, mtime and hashes and leaves
                    // `capture_time`/`capture_offset` alone — and since it does
                    // rewrite size and mtime, `needsReindex` never asks for the
                    // file to be read again either, so the stale value is
                    // permanent rather than merely late. Nothing this view can
                    // do short of a rescan is honest; the fix is one `Core`
                    // change to that call.
                    row("Captured", shared { record in
                        record.captureDate.map { Self.dateFormatter.string(from: $0) }
                    })
                    row("Time zone", shared(\.captureOffset))
                    row("Camera", shared { record in
                        [record.cameraMake, record.cameraModel]
                            .compactMap { $0 }
                            .joined(separator: " ")
                    })
                    row("Modified", shared {
                        Self.dateFormatter.string(from: $0.modifiedDate)
                    })
                }

                editing

                if records.count == 1 {
                    Section("Location") {
                        row("Path", .value(records[0].path))
                    }
                }

                Section("Hashes") {
                    row("Content", shared(\.contentHash).map(Self.abbreviated))
                    row("Image data", shared(\.imageHash).map(Self.abbreviated))
                    row("Rule", shared(\.imageHashKind))
                    row("Perceptual", shared(\.phash).map(Self.abbreviated))
                    if records.contains(where: { $0.hashedAt == nil }) {
                        Text(records.count == 1
                             ? "Not yet hashed."
                             : "Some of these are not yet hashed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // The probe forks `exiftool -ver`, so it happens once, off the main
        // actor, the first time an inspector is on screen — not at launch.
        .task { await model.resolveMetadataAvailability() }
        .onChange(of: model.selection.selected, initial: true) { _, _ in reseed() }
    }

    // MARK: - Editing

    @ViewBuilder
    private var editing: some View {
        Section("Edit") {
            if let explanation = model.metadataUnavailableExplanation {
                // Spec §11: with exiftool absent the editing controls are
                // **replaced by** the explanation and the command that fixes
                // it — not rendered greyed out. A disabled box carrying a value
                // nobody can commit is furniture; the sentence is the whole of
                // what there is to say. Nothing else in the window changes.
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(MetadataInspectorCopy.installCommand)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                HStack {
                    Button("Try Again") {
                        Task { await model.resolveMetadataAvailability(recheck: true) }
                    }
                    // #51: the escape when none of the four rungs can see the
                    // install. Offered here rather than in a settings window
                    // because this is where the user is standing when they hit
                    // the problem — the same call `DestinationChooser` makes.
                    Button("Choose…") { chooseExiftool() }
                    if model.canClearStoredExiftoolPath {
                        Button("Use Default") {
                            Task { await model.clearStoredExiftoolPath() }
                        }
                    }
                }
                if let refusal = exiftoolRefusal {
                    Text(refusal)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if model.metadataAvailability == nil {
                Text("Checking for exiftool…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                fields
                // **Only when a stored path is what is running.** Editing works
                // and nothing else in the window says which exiftool is doing
                // it, so a preference the user set once — possibly months ago,
                // possibly on a volume now unplugged — would otherwise be
                // invisible until it broke.
                if let inForce = model.storedExiftoolPathInForce {
                    HStack {
                        Text("Using exiftool at \(inForce)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Change…") { chooseExiftool() }
                            .buttonStyle(.link)
                        Button("Use Default") {
                            Task { await model.clearStoredExiftoolPath() }
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }

    /// Runs the picker, then hands the choice to the model, which validates it
    /// before storing anything (#51, decision 4).
    private func chooseExiftool() {
        guard let path = ExiftoolChooser.chooseExecutable() else { return }
        Task {
            exiftoolRefusal = await model.chooseStoredExiftoolPath(path)
        }
    }

    @ViewBuilder
    private var fields: some View {
        field("Capture time", text: $captureTimeDraft, prompt: WallClock.placeholder,
              id: .inspectorCaptureTime) {
            .captureTime(wallClock: captureTimeDraft, offset: captureZoneDraft,
                         seed: captureSeed)
        }
        // **Always shown, never assumed.** A `DateTimeOriginal` with no
        // `OffsetTimeOriginal` names a different instant on every machine that
        // reads it, so the zone is a control rather than a default buried in
        // the code — spec §9, constraint 1.
        field("Time zone", text: $captureZoneDraft, prompt: "-05:00",
              id: .inspectorCaptureZone) {
            .captureTime(wallClock: captureTimeDraft, offset: captureZoneDraft,
                         seed: captureSeed)
        }
        Button("Batch Time Operations…") { model.openBatchTimeSheet() }
            .disabled(!model.canStartMetadataBatch)

        field("Artist", text: $artistDraft, prompt: unchangedPrompt,
              id: .inspectorArtist, clearing: .artist) { .artist(artistDraft) }
        field("Copyright", text: $copyrightDraft, prompt: unchangedPrompt,
              id: .inspectorCopyright, clearing: .copyright) { .copyright(copyrightDraft) }
        field("Description", text: $descriptionDraft, prompt: unchangedPrompt,
              id: .inspectorDescription, clearing: .description) { .description(descriptionDraft) }
        field("Keywords", text: $keywordsDraft, prompt: unchangedPrompt,
              id: .inspectorKeywords, clearing: .keywords) { .keywords(keywordsDraft) }
        field("Rating", text: $ratingDraft, prompt: unchangedPrompt,
              id: .inspectorRating) { .rating(ratingDraft) }
        field("Label", text: $labelDraft, prompt: unchangedPrompt,
              id: .inspectorLabel, clearing: .label) { .label(labelDraft) }
        field("Latitude", text: $latitudeDraft, prompt: unchangedPrompt,
              id: .inspectorLatitude) {
            .gps(latitude: latitudeDraft, longitude: longitudeDraft)
        }
        field("Longitude", text: $longitudeDraft, prompt: unchangedPrompt,
              id: .inspectorLongitude) {
            .gps(latitude: latitudeDraft, longitude: longitudeDraft)
        }

        if let refusal {
            Text(refusal)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let sidecar = MetadataEditRequest.sidecarNotice(records) {
            Text(sidecar)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("Press Return in a field to apply it to "
            + (records.count == 1 ? "this image." : "all \(records.count) images."))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text(MetadataInspectorCopy.notUndoable)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One editable field, through the shared `MetadataTextField` — the single
    /// place `reportingTextFocus` is called, so there is one place to forget it
    /// and `everyInspectorFieldReportsItsFocus` walks that place.
    ///
    /// `clearing` names the field the ✕ erases, and is absent for the three
    /// that have no erase: `MetadataEdit` cannot spell "remove this capture
    /// time / rating / position".
    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, prompt: String,
                       id: BrowserModel.TextField,
                       clearing clearable: MetadataField? = nil,
                       edit: @escaping () -> MetadataFieldEdit) -> some View {
        MetadataTextField(
            label: label, text: text, prompt: prompt, id: id, focused: $focused,
            model: model, isEnabled: model.canEditMetadata,
            onSubmit: { commit(edit()) },
            clear: clearable.map { field in { model.confirmClearMetadataField(field) } })
    }

    private func commit(_ edit: MetadataFieldEdit) {
        refusal = nil
        Task {
            if let failure = await model.commitMetadataField(edit) {
                refusal = failure.message
            }
        }
    }

    /// **Every editable box carries this prompt**, because every one of them
    /// means the same thing when empty: leave the tag alone. That is the rule
    /// the whole editor turns on — `TextField.onSubmit` fires on Return whether
    /// or not the text changed, so an empty box that erased would erase across
    /// the selection on a stray Return. Erasing is the ✕ beside the box.
    ///
    /// It has to be said in the prompt or a blank box reads as "this file has
    /// no Artist", which the index cannot actually tell us — see the type's own
    /// documentation.
    private var unchangedPrompt: String {
        records.count == 1 ? "unchanged" : "unchanged for all \(records.count)"
    }

    /// Puts the drafts back in step with whatever is selected now.
    ///
    /// Capture time and zone come off the index, because those two columns
    /// exist. The rest reset to empty, which is "unchanged" — the alternative,
    /// leaving the previous selection's text in the boxes, is one Return away
    /// from writing it to the wrong photos.
    private func reseed() {
        refusal = nil
        artistDraft = ""
        copyrightDraft = ""
        descriptionDraft = ""
        keywordsDraft = ""
        ratingDraft = ""
        labelDraft = ""
        latitudeDraft = ""
        longitudeDraft = ""

        guard !records.isEmpty else {
            captureTimeDraft = ""
            captureZoneDraft = ""
            captureSeed = nil
            return
        }
        let offset = MetadataEditRequest.defaultOffset(for: records)
        captureZoneDraft = offset
        let zone = TimeZoneOffset.parse(offset) ?? .current
        let dates = records.map(\.captureDate)
        if let first = dates.first, let agreed = first, dates.allSatisfy({ $0 == agreed }) {
            captureTimeDraft = WallClock.string(from: agreed, in: zone)
        } else {
            captureTimeDraft = ""
        }
        // Remembered, so a Return that changed neither box changes nothing.
        // Without it these two are the one pair that escapes the
        // blank-means-unchanged rule, by never being blank.
        captureSeed = CaptureTimeSeed(wallClock: captureTimeDraft, offset: captureZoneDraft)
    }

    // MARK: - Read-only rendering

    /// A full content hash is 64 hex characters and would force the inspector
    /// as wide as a value nobody reads in full. The prefix is enough to
    /// compare two rows by eye, and the text stays selectable for the rest.
    private static func abbreviated(_ value: String) -> String {
        value.count > 16 ? String(value.prefix(16)) + "…" : value
    }

    @ViewBuilder
    private func row(_ label: String, _ value: SharedValue) -> some View {
        LabeledContent(label) {
            switch value {
            case .value(let text):
                Text(text)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            case .absent:
                Text("—").foregroundStyle(.secondary)
            case .mixed:
                Text("(multiple values)").foregroundStyle(.secondary)
            }
        }
    }

    /// The value every selected record agrees on.
    ///
    /// Empty and absent are folded together on purpose: a record with
    /// `cameraMake == ""` and one with `cameraMake == nil` do not disagree
    /// about anything a user would recognise, and reporting them as mixed
    /// would be a lie about the data.
    private func shared(_ extract: (FileRecord) -> String?) -> SharedValue {
        var agreed: String?
        for record in records {
            let value = extract(record) ?? ""
            if let agreed {
                guard agreed == value else { return .mixed }
            } else {
                agreed = value
            }
        }
        guard let agreed, !agreed.isEmpty else { return .absent }
        return .value(agreed)
    }

    private func shared(_ keyPath: KeyPath<FileRecord, String?>) -> SharedValue {
        shared { $0[keyPath: keyPath] }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
