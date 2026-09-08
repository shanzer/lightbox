import Foundation
import LightboxCore

/// The inspector's side of spec §9, with no view and no model in it.
///
/// Everything here is a value or a static function over values, so the whole of
/// the interesting behaviour — which files get which edit, what a zone-less
/// capture time does, where a sequence's timestamps land — is testable without
/// a window. `BrowserModel+MetadataEditing.swift` only decides *when* to build
/// one of these and hands the result to `MetadataWriter`.
///
/// **Nothing reaches the writer that has not been through
/// `MetadataEditRequest.build`.** `MetadataWriter.validate` refuses the same
/// things at the API — a UI that merely discourages a zone-less capture time is
/// a UI that writes one the first time a batch path skips it — but a writer
/// refusal arrives as one `WriteOutcome` per file in a summary sheet, which is
/// the wrong shape for "you typed the offset wrong". The two layers refuse the
/// same inputs on purpose; this one refuses them *before* a batch starts, with
/// a sentence next to the field.

// MARK: - Time-zone offsets

/// EXIF `OffsetTimeOriginal`, the zero-padded `±HH:MM` form.
///
/// **Reimplemented here rather than shared with `MetadataReader.timeZone(fromOffset:)`,
/// which is internal to `Core`.** The two must agree, because an offset this
/// layer accepts and the writer's validation rejects is a batch that fails
/// every item with a message the user has already been shown a different
/// version of. `anOffsetThisLayerAcceptsIsOneTheWriterAccepts` pins the pair.
enum TimeZoneOffset {
    /// Parses `±HH:MM`, and nothing looser — the same strictness
    /// `MetadataReader` applies on the read side, because an offset the reader
    /// cannot parse round-trips to a different instant.
    static func parse(_ text: String) -> TimeZone? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 6 else { return nil }
        let sign: Int
        switch trimmed.first {
        case "+": sign = 1
        case "-": sign = -1
        default: return nil
        }
        let body = trimmed.dropFirst().split(separator: ":")
        guard body.count == 2, body[0].count == 2, body[1].count == 2,
              body[0].allSatisfy(\.isASCIIDigit), body[1].allSatisfy(\.isASCIIDigit),
              let hours = Int(body[0]), let minutes = Int(body[1]),
              hours <= 23, minutes <= 59 else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }

    /// `TimeZone` → `±HH:MM`, at a given instant so a summer photo in a
    /// daylight-saving zone is offered `-04:00` rather than `-05:00`.
    static func format(_ zone: TimeZone, at instant: Date) -> String {
        format(secondsFromGMT: zone.secondsFromGMT(for: instant))
    }

    static func format(secondsFromGMT seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        let hours = magnitude / 3600
        let minutes = (magnitude % 3600) / 60
        return String(format: "%@%02d:%02d", sign, hours, minutes)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: - Wall clock

/// The capture-time field's text format, in both directions.
///
/// A wall clock plus an offset, never an instant on its own: that pairing is
/// spec §9's first constraint made visible. The field shows `2021-07-08
/// 09:10:11` and the zone control shows `-04:00`, and the absolute instant the
/// writer receives is the first read *in* the second. Change the offset alone
/// and the photo's moment moves, which is exactly what a user fixing a
/// mis-zoned camera means to do.
enum WallClock {
    static let format = "yyyy-MM-dd HH:mm:ss"
    static let placeholder = "yyyy-mm-dd hh:mm:ss"

    /// Accepts the seconds-less form too, because a user typing a time by hand
    /// routinely stops at the minute. Seconds default to zero, which is a
    /// different instant from "leave it alone" — but "leave it alone" is what
    /// not editing the field means, so the ambiguity does not arise.
    private static let accepted = [format, "yyyy-MM-dd HH:mm"]

    static func parse(_ text: String, in zone: TimeZone) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        for candidate in accepted {
            let formatter = makeFormatter(candidate, zone: zone)
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    static func string(from date: Date, in zone: TimeZone) -> String {
        makeFormatter(format, zone: zone).string(from: date)
    }

    /// `en_US_POSIX` and a fixed calendar, not the user's: a fixed-format
    /// parser under a Buddhist or Japanese calendar reads `2021` as a different
    /// year, and the value is on its way into EXIF.
    private static func makeFormatter(_ template: String, zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = template
        formatter.isLenient = false
        return formatter
    }
}

/// How far a wrong camera clock was wrong, as the shift field spells it.
///
/// Two forms, because the two ways this goes wrong have different magnitudes: a
/// zone the camera was never told about is a whole number of hours
/// (`-1:00:00`), and a clock that drifted is seconds (`-37`). Requiring the
/// long form for the second, or arithmetic in the user's head for the first,
/// would make one of the two unpleasant enough to do wrong.
enum ShiftAmount {
    static let placeholder = "-3600, or -1:00:00"

    /// Plain seconds, or `[+-]H:MM:SS` / `[+-]H:MM`. Nil for anything else —
    /// including an empty string, which is not a shift of zero but a field the
    /// user has not filled in.
    static func parseSeconds(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var sign = 1
        var body = Substring(trimmed)
        if body.first == "-" { sign = -1; body = body.dropFirst() }
        else if body.first == "+" { body = body.dropFirst() }
        guard !body.isEmpty else { return nil }

        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        var values: [Int] = []
        for part in parts {
            guard part.allSatisfy(\.isASCIIDigit), let value = Int(part) else { return nil }
            values.append(value)
        }
        switch values.count {
        case 1: return sign * values[0]
        case 2: return sign * (values[0] * 3600 + values[1] * 60)
        case 3: return sign * (values[0] * 3600 + values[1] * 60 + values[2])
        default: return nil
        }
    }
}

// MARK: - The editable fields

/// The §9 set, as the inspector's controls rather than as tags.
///
/// GPS is one field with two boxes and capture time is one field with two boxes,
/// because in both cases half a value is not a value: a latitude with no
/// longitude is not a position, and an instant with no zone is spec §9's first
/// constraint. Committing either commits the pair.
enum MetadataField: String, CaseIterable, Sendable {
    case captureTime
    case artist
    case copyright
    case description
    case keywords
    case rating
    case label
    case gps

    var title: String {
        switch self {
        case .captureTime: "Capture time"
        case .artist: "Artist"
        case .copyright: "Copyright"
        case .description: "Description"
        case .keywords: "Keywords"
        case .rating: "Rating"
        case .label: "Label"
        case .gps: "GPS"
        }
    }
}

/// One committed field: the field, and the text the user left in its boxes.
///
/// Strings rather than parsed values, deliberately. The parse is the validation
/// — "0..5" and "±HH:MM" and "a position on Earth" are all the same check — and
/// doing it once, in `MetadataEditRequest.build`, is what stops the inspector
/// and the writer from disagreeing about what a field accepts.
enum MetadataFieldEdit: Sendable, Equatable {
    case artist(String)
    case copyright(String)
    case description(String)
    /// Comma-separated. `MetadataEdit.keywords` replaces the set wholesale, so
    /// an empty string clears every keyword rather than doing nothing.
    case keywords(String)
    /// `0`…`5`, or empty to leave the rating alone.
    case rating(String)
    case label(String)
    case gps(latitude: String, longitude: String)
    case captureTime(wallClock: String, offset: String)

    var field: MetadataField {
        switch self {
        case .artist: .artist
        case .copyright: .copyright
        case .description: .description
        case .keywords: .keywords
        case .rating: .rating
        case .label: .label
        case .gps: .gps
        case .captureTime: .captureTime
        }
    }
}

// MARK: - Batch time operations

/// Spec §9's three batch time operations, as a sheet asks for them.
enum BatchTimeOperation: Sendable, Equatable {
    /// Every selected file gets the same instant.
    case set(wallClock: String, offset: String)
    /// The camera clock was wrong: every file's existing capture time moves by
    /// the same number of seconds, keeping its own zone.
    case shift(seconds: Int)
    /// A burst that lost its timestamps: the first selected file gets `start`
    /// and each subsequent one is `interval` seconds later, **in the grid's
    /// current sort order**.
    case sequence(startWallClock: String, offset: String, intervalSeconds: Int)
}

// MARK: - Refusals

/// Why a request was not built. One sentence, shown next to the field rather
/// than in a summary sheet — nothing has run, so there is nothing to summarise.
enum MetadataEditRefusal: Error, Sendable, Equatable {
    case noSelection
    case nothingToWrite
    /// exiftool is missing or too old (spec §11). The fields render read-only
    /// in that case, so this is the belt on the braces: a commit that arrives
    /// anyway — a stale view, a keystroke racing the probe — is refused here
    /// rather than turned into a batch that fails every item identically.
    case editingUnavailable
    /// A batch is already running in this window, or a sheet is waiting on an
    /// answer. Same rule as the file-operation commands: two batches
    /// interleaving index writes over the same rows is the one thing the
    /// journal ordering cannot describe.
    case busy
    case captureTimeRequiresTimeZone
    case invalidTimeZoneOffset(String)
    case invalidCaptureTime(String)
    case invalidRating(String)
    case invalidCoordinate(latitude: String, longitude: String)
    case incompleteCoordinate
    case invalidInterval(String)
    case invalidShift(String)
    /// A shift moves each file's *existing* capture time, so a file that has
    /// none has nothing to move. Refused for the whole batch rather than
    /// silently skipping those files: "8 of 12 were shifted" discovered
    /// afterwards is worse than being told first.
    case noCaptureTimeToShift(count: Int)

    var message: String {
        switch self {
        case .noSelection:
            "Select at least one image first."
        case .nothingToWrite:
            "Nothing to write: no field was changed."
        case .editingUnavailable:
            "Metadata editing is unavailable."
        case .busy:
            "Another operation is still running in this window."
        case .captureTimeRequiresTimeZone:
            """
            A capture time needs a time zone. Without one the timestamp means a \
            different moment on every machine that reads it.
            """
        case .invalidTimeZoneOffset(let offset):
            "\"\(offset)\" is not a time-zone offset. It must look like -05:00."
        case .invalidCaptureTime(let text):
            "\"\(text)\" is not a date and time. It must look like \(WallClock.placeholder)."
        case .invalidRating(let text):
            "\"\(text)\" is not a rating. Ratings run from 0 to 5, or leave it blank."
        case .invalidCoordinate(let latitude, let longitude):
            """
            \(latitude), \(longitude) is not a position on Earth. Latitude runs \
            -90 to 90 and longitude -180 to 180.
            """
        case .incompleteCoordinate:
            "A position needs both a latitude and a longitude."
        case .invalidInterval(let text):
            "\"\(text)\" is not an interval in seconds."
        case .invalidShift(let text):
            "\"\(text)\" is not a number of seconds to shift by."
        case .noCaptureTimeToShift(let count):
            "\(count) selected \(count == 1 ? "image has" : "images have") no capture time "
                + "to shift. Set a capture time on \(count == 1 ? "it" : "them") first."
        }
    }
}

// MARK: - The request

/// What one commit asks the writer to do.
///
/// **Grouped, not flattened.** A field edit is one `MetadataEdit` over every
/// selected file, and that is one `MetadataWriter.write` call — a batch of N,
/// with the writer's own progress and cancellation. A time *sequence* gives
/// every file a different instant, so it is N groups of one. The count of
/// groups is therefore load-bearing and is what
/// `aFieldEditOnThreeFilesIsOneWriterBatchOfThree` asserts: a model that looped
/// and called the writer once per file would still write the right bytes and
/// would still be wrong, because each call is its own `-stay_open` round trip
/// and its own progress sequence starting again at 1.
struct MetadataEditRequest: Sendable, Equatable {
    struct Group: Sendable, Equatable {
        let edit: MetadataEdit
        let urls: [URL]
    }

    let groups: [Group]

    var fileCount: Int { groups.reduce(0) { $0 + $1.urls.count } }
    var isEmpty: Bool { groups.allSatisfy(\.urls.isEmpty) }

    /// Every file this request touches, in the order the writer will reach it.
    var urls: [URL] { groups.flatMap(\.urls) }

    // MARK: One field, across the selection

    static func build(_ edit: MetadataFieldEdit,
                      for records: [FileRecord]) -> Result<Self, MetadataEditRefusal> {
        guard !records.isEmpty else { return .failure(.noSelection) }
        switch metadataEdit(for: edit) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let metadata):
            guard !metadata.isEmpty else { return .failure(.nothingToWrite) }
            return .success(Self(groups: [Group(edit: metadata, urls: records.map(\.fileURL))]))
        }
    }

    private static func metadataEdit(
        for edit: MetadataFieldEdit
    ) -> Result<MetadataEdit, MetadataEditRefusal> {
        switch edit {
        case .artist(let value):
            return .success(MetadataEdit(artist: value))
        case .copyright(let value):
            return .success(MetadataEdit(copyright: value))
        case .description(let value):
            return .success(MetadataEdit(description: value))
        case .keywords(let value):
            return .success(MetadataEdit(keywords: keywords(from: value)))
        case .label(let value):
            return .success(MetadataEdit(label: value))
        case .rating(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            // Blank is "leave it alone", not zero: zero is a real rating that
            // clears a star count, and a user who empties the box to stop
            // editing has not asked for that.
            guard !trimmed.isEmpty else { return .failure(.nothingToWrite) }
            guard let rating = Int(trimmed), (0...5).contains(rating) else {
                return .failure(.invalidRating(text))
            }
            return .success(MetadataEdit(rating: rating))
        case .gps(let latitudeText, let longitudeText):
            let latitude = latitudeText.trimmingCharacters(in: .whitespaces)
            let longitude = longitudeText.trimmingCharacters(in: .whitespaces)
            if latitude.isEmpty && longitude.isEmpty { return .failure(.nothingToWrite) }
            guard !latitude.isEmpty, !longitude.isEmpty else {
                return .failure(.incompleteCoordinate)
            }
            guard let lat = Double(latitude), let long = Double(longitude),
                  lat.isFinite, long.isFinite,
                  (-90...90).contains(lat), (-180...180).contains(long) else {
                return .failure(.invalidCoordinate(latitude: latitude, longitude: longitude))
            }
            return .success(MetadataEdit(gps: GPSCoordinate(latitude: lat, longitude: long)))
        case .captureTime(let wallClock, let offset):
            return captureTime(wallClock: wallClock, offset: offset)
                .map { MetadataEdit(captureTime: $0) }
        }
    }

    /// Spec §9, constraint 1, enforced here so the refusal is a message beside
    /// the field rather than N identical rows in a summary sheet.
    static func captureTime(wallClock: String,
                            offset: String) -> Result<CaptureTime, MetadataEditRefusal> {
        let trimmedOffset = offset.trimmingCharacters(in: .whitespaces)
        guard !trimmedOffset.isEmpty else { return .failure(.captureTimeRequiresTimeZone) }
        guard let zone = TimeZoneOffset.parse(trimmedOffset) else {
            return .failure(.invalidTimeZoneOffset(offset))
        }
        guard let date = WallClock.parse(wallClock, in: zone) else {
            return .failure(.invalidCaptureTime(wallClock))
        }
        return .success(CaptureTime(date: date, offset: trimmedOffset))
    }

    /// One per line or one per comma, whichever the user used. Empties are
    /// dropped; an entirely empty string is an empty array, which
    /// `MetadataEdit.keywords` defines as "clear them".
    static func keywords(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: Batch time operations

    /// - Parameter records: the selection **in the grid's current sort order**.
    ///   `sequence` numbers them in exactly that order, which is the whole
    ///   point of the operation: a burst is re-timed the way it is displayed.
    static func build(_ operation: BatchTimeOperation,
                      for records: [FileRecord]) -> Result<Self, MetadataEditRefusal> {
        guard !records.isEmpty else { return .failure(.noSelection) }
        switch operation {
        case .set(let wallClock, let offset):
            return captureTime(wallClock: wallClock, offset: offset).map { capture in
                Self(groups: [Group(edit: MetadataEdit(captureTime: capture),
                                    urls: records.map(\.fileURL))])
            }

        case .shift(let seconds):
            let missing = records.filter { $0.captureDate == nil }.count
            guard missing == 0 else { return .failure(.noCaptureTimeToShift(count: missing)) }
            var groups: [Group] = []
            groups.reserveCapacity(records.count)
            for record in records {
                // `captureDate` is non-nil for every record here — the guard
                // above is the whole batch's precondition — but the shift is
                // still expressed per record rather than hoisted, because each
                // file keeps **its own** zone: a shift fixes a wrong clock, it
                // does not move photos between zones.
                guard let existing = record.captureDate else { continue }
                let offset = record.captureOffset.flatMap { TimeZoneOffset.parse($0) != nil ? $0 : nil }
                    ?? TimeZoneOffset.format(.current, at: existing)
                let capture = CaptureTime(date: existing.addingTimeInterval(Double(seconds)),
                                          offset: offset)
                groups.append(Group(edit: MetadataEdit(captureTime: capture),
                                    urls: [record.fileURL]))
            }
            return .success(Self(groups: groups))

        case .sequence(let startWallClock, let offset, let interval):
            return captureTime(wallClock: startWallClock, offset: offset).map { start in
                let groups = records.enumerated().map { index, record in
                    let instant = start.date.addingTimeInterval(Double(index * interval))
                    return Group(edit: MetadataEdit(captureTime: CaptureTime(date: instant,
                                                                            offset: start.offset)),
                                 urls: [record.fileURL])
                }
                return Self(groups: groups)
            }
        }
    }

    // MARK: Defaults read off the selection

    /// The zone the capture-time control opens on.
    ///
    /// The issue's rule, in order: the file's own `OffsetTimeOriginal` when the
    /// selection agrees on one, else the machine's zone — and **always shown**,
    /// never merely assumed, because the whole reason this control exists is
    /// that `DateTimeOriginal` carries no zone.
    ///
    /// The machine's zone is read *at the photo's own instant* rather than at
    /// `now`, so a July photo in New York is offered `-04:00` and a January one
    /// `-05:00`. Reading it at `now` would silently shift half the library by
    /// an hour every March.
    static func defaultOffset(for records: [FileRecord],
                              zone: TimeZone = .current,
                              now: Date = Date()) -> String {
        // An unparseable stored offset counts as *no* offset rather than as a
        // value to agree on: it would be refused on the way back out, and
        // offering it in the control would be offering a write that cannot
        // happen.
        let offsets = records.map { record in
            record.captureOffset.flatMap { TimeZoneOffset.parse($0) != nil ? $0 : nil }
        }
        if let first = offsets.first, let agreed = first,
           offsets.allSatisfy({ $0 == agreed }) {
            return agreed
        }
        let reference = records.compactMap(\.captureDate).first ?? now
        return TimeZoneOffset.format(zone, at: reference)
    }

    /// Whether any selected file is a RAW container, which
    /// `MetadataWriter` edits through an `.xmp` sidecar rather than in place
    /// (spec §9, constraint 2). The inspector says so beside the fields, so the
    /// user knows the container is untouched.
    static func writesToSidecar(_ records: [FileRecord]) -> Bool {
        records.contains { MediaType.forExtension($0.ext)?.kind == .raw }
    }
}

extension FileRecord {
    var fileURL: URL { URL(fileURLWithPath: path) }
}

// MARK: - The summary

/// What a metadata batch has to report. `OperationSummary`'s counterpart, and
/// separate from it because the two describe different things: a file operation
/// has a destination, a collision history and an undo, and a metadata write has
/// none of those and has *warnings*, which a file operation does not.
///
/// **Never `lastCompletedBatch`.** A metadata edit is not journalled in
/// `op_journal`, so ⌘Z has nothing to reverse and the inspector says so rather
/// than letting the Edit menu offer to undo the previous file operation as
/// though it were this write.
struct MetadataSummary: Identifiable, Sendable {
    struct Row: Identifiable, Sendable {
        let id: String
        let source: URL
        let detail: String
    }

    let id = UUID()
    let wasCancelled: Bool
    let written: Int
    let failures: [Row]
    /// Warnings from writes that *succeeded*. Shown when the sheet is up, and
    /// they can raise it on their own — see `isWorthShowing`.
    let notes: [Row]
    /// Files whose edit landed in an `.xmp` sidecar rather than the container.
    let sidecars: Int

    init(outcomes: [WriteOutcome], wasCancelled: Bool) {
        self.wasCancelled = wasCancelled
        var failures: [Row] = []
        var notes: [Row] = []
        var written = 0
        var sidecars = 0
        for outcome in outcomes {
            switch outcome.result {
            case .failure(let error):
                failures.append(Row(id: "fail:" + outcome.source.path,
                                    source: outcome.source, detail: error.explanation))
            case .success(let success):
                written += 1
                if case .sidecar = success.target { sidecars += 1 }
                for (index, warning) in success.warnings.enumerated() {
                    guard let detail = Self.describe(warning) else { continue }
                    notes.append(Row(id: "warn:\(index):" + outcome.source.path,
                                     source: outcome.source, detail: detail))
                }
            }
        }
        self.failures = failures
        self.notes = notes
        self.written = written
        self.sidecars = sidecars
    }

    /// **Two of the five warnings are expected rather than surprising**, and a
    /// sheet in front of every HEIC edit would be a sheet nobody reads.
    /// `imageHashUnavailable` fires on every HEIC, TIFF, GIF and PSD write by
    /// construction (spec §11's last row), and `exiftool` stderr is routinely
    /// a minor-warning line on a file that wrote correctly. Both are dropped.
    /// The other three each mean something the user would want to know did not
    /// go the way it looked.
    private static func describe(_ warning: WriteWarning) -> String? {
        switch warning {
        case .imageHashUnavailable, .exiftool:
            nil
        case .containerModifiedBySidecarWrite:
            "The RAW container was expected to be untouched by a sidecar write and was not."
        case .indexRowNotUpdated:
            "The file was written, but the index row no longer described it, so the row "
                + "was left to be re-read rather than updated."
        case .sweptOrphanedBackup(let name):
            "An abandoned backup (\(name)) from an interrupted earlier run was removed."
        }
    }

    /// Whether the sheet goes up at all.
    ///
    /// The same rule the file-operation summary follows — report the
    /// exceptions, do not congratulate the rule — with warnings folded in,
    /// because the three warnings that survive `describe` are exceptions too. A
    /// clean cancel shows nothing: the progress sheet was on screen counting up
    /// until Stop was pressed.
    var isWorthShowing: Bool { !failures.isEmpty || !notes.isEmpty }

    var headline: String {
        guard !failures.isEmpty else {
            return "\(written) \(written == 1 ? "file" : "files") written."
        }
        let noun = failures.count == 1 ? "file" : "files"
        let stem = "\(failures.count) \(noun) could not be written"
        return wasCancelled ? "\(stem). The batch was cancelled." : "\(stem)."
    }
}
