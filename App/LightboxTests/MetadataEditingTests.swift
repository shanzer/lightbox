import Testing
import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import LightboxCore
@testable import Lightbox

// MARK: - The seam

/// Stands in for `MetadataWriter` so the App suite runs on a machine with no
/// exiftool — which is every CI runner (`macos-26`, clean).
///
/// **It records the calls rather than the files.** What this layer decides is
/// *how many batches a commit becomes and what is in each*, and that is
/// invisible to any assertion made about the bytes on disk: a model that looped
/// and called the writer once per file would write exactly the same metadata
/// and would still be wrong, because each call is its own `-stay_open` round
/// trip and its own progress sequence starting again at 1.
final class RecordingMetadataWriter: MetadataWriting, @unchecked Sendable {
    struct Call: Sendable {
        let edit: MetadataEdit
        let urls: [URL]
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _availability: ExiftoolAvailability
    private var _rechecks = 0
    /// Per-path failure to hand back, for the summary-sheet tests.
    private var _failures: [String: MetadataWriteError] = [:]
    private var _warnings: [WriteWarning] = []
    /// A RAW selection's outcome names the sidecar, which is what the summary
    /// counts.
    private var _sidecarExtensions: Set<String> = ["cr2", "cr3", "nef", "arw", "dng"]

    init(availability: ExiftoolAvailability = .available(path: "/stub/exiftool",
                                                         version: "13.55")) {
        _availability = availability
    }

    var calls: [Call] { lock.withLock { _calls } }
    var rechecks: Int { lock.withLock { _rechecks } }

    func fail(_ name: String, with error: MetadataWriteError) {
        lock.withLock { _failures[name] = error }
    }

    func warn(_ warning: WriteWarning) {
        lock.withLock { _warnings.append(warning) }
    }

    func become(_ availability: ExiftoolAvailability) {
        lock.withLock { _availability = availability }
    }

    func availability() async -> ExiftoolAvailability { lock.withLock { _availability } }

    func recheckAvailability() async -> ExiftoolAvailability {
        lock.withLock {
            _rechecks += 1
            return _availability
        }
    }

    func write(_ edit: MetadataEdit, to urls: [URL],
               progress: @escaping @Sendable (Int, Int) -> Void) async -> [WriteOutcome] {
        let (failures, warnings, sidecars) = lock.withLock { () -> ([String: MetadataWriteError],
                                                                    [WriteWarning], Set<String>) in
            _calls.append(Call(edit: edit, urls: urls))
            return (_failures, _warnings, _sidecarExtensions)
        }
        var outcomes: [WriteOutcome] = []
        for (index, url) in urls.enumerated() {
            if let failure = failures[url.lastPathComponent] {
                outcomes.append(WriteOutcome(source: url, result: .failure(failure)))
            } else {
                let isSidecar = sidecars.contains(url.pathExtension.lowercased())
                let written = isSidecar
                    ? url.deletingPathExtension().appendingPathExtension("xmp") : url
                outcomes.append(WriteOutcome(source: url, result: .success(
                    WriteSuccess(written: written,
                                 target: isSidecar ? .sidecar(written) : .inPlace,
                                 rehash: nil, warnings: warnings))))
            }
            progress(index + 1, urls.count)
        }
        return outcomes
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

// MARK: - Fixtures

/// A real JPEG, for the one test that runs the real writer.
private func writeJPEG(to url: URL) throws {
    let width = 8, height = 8
    var pixels = [UInt8](repeating: 0x7F, count: width * height * 4)
    // Not a flat colour: a uniform image compresses to something exiftool is
    // still happy with, but a little structure keeps this honest as a photo.
    for index in stride(from: 0, to: pixels.count, by: 4) { pixels[index] = UInt8(index % 251) }
    let context = CGContext(data: &pixels, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    guard let image = context?.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw MetadataError.unreadable
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw MetadataError.unreadable }
}

/// The same lookup the writer performs, as CONTRIBUTING requires of a skip
/// guard. A guard that checked `/opt/homebrew/bin/exiftool` while the writer
/// searched `PATH` would be green on CI and prove nothing.
private let needsExiftool = ConditionTrait.enabled(
    if: MetadataWriter.availability.isAvailable,
    "exiftool is not on PATH — the inspector's live write test is skipped")

// MARK: - Pure computations

/// Sequence maths, zone resolution and per-field validation, with no window and
/// no writer anywhere near them.
struct MetadataEditRequestTests {
    private func record(_ name: String, id: Int64, capture: Double? = nil,
                        offset: String? = nil) -> FileRecord {
        FileRecord(id: id, path: "/library/\(name)", parentDir: "/library", name: name,
                   ext: (name as NSString).pathExtension.lowercased(), size: 64, mtime: 0,
                   device: 1, inode: id, volumeUUID: nil, width: nil, height: nil,
                   captureTime: capture, captureOffset: offset, cameraMake: nil,
                   cameraModel: nil, orientation: nil, contentHash: nil, imageHash: nil,
                   imageHashKind: nil, phash: nil, hashedAt: nil, indexedAt: 0)
    }

    /// The acceptance bullet: 5 files at 10 s intervals from a start yield the
    /// expected 5 timestamps **in sort order**.
    ///
    /// Both halves are asserted, and both are mutations that would otherwise
    /// pass: an interval of 1 s instead of 10 gives five perfectly plausible
    /// timestamps, and numbering by anything other than the order it was handed
    /// gives the same five instants attached to the wrong photos.
    @Test func aSequenceNumbersFiveFilesTenSecondsApartInSortOrder() throws {
        let records = (1...5).map { record("IMG_000\($0).jpg", id: Int64($0)) }
        let built = MetadataEditRequest.build(
            .sequence(startWallClock: "2021-07-08 09:10:11", offset: "-04:00",
                      intervalSeconds: 10),
            for: records)
        let request = try #require(try built.get())

        // Five groups of one, not one group of five: each file gets a
        // different instant, so they cannot share a `MetadataEdit`.
        #expect(request.groups.count == 5)
        #expect(request.fileCount == 5)

        let zone = try #require(TimeZoneOffset.parse("-04:00"))
        let start = try #require(WallClock.parse("2021-07-08 09:10:11", in: zone))
        for (index, group) in request.groups.enumerated() {
            #expect(group.urls.map(\.lastPathComponent) == ["IMG_000\(index + 1).jpg"],
                    "group \(index) is attached to the wrong file")
            let capture = try #require(group.edit.captureTime)
            #expect(capture.date == start.addingTimeInterval(Double(index) * 10),
                    "group \(index) landed at \(capture.date), not \(index * 10)s after the start")
            #expect(capture.offset == "-04:00")
        }
    }

    /// A shift moves each file's own instant and keeps each file's own zone: it
    /// fixes a clock, it does not move photos between zones.
    @Test func aShiftMovesEachFileByTheSameSecondsAndKeepsItsOwnZone() throws {
        let records = [record("a.jpg", id: 1, capture: 1_000, offset: "-04:00"),
                       record("b.jpg", id: 2, capture: 5_000, offset: "+09:00")]
        let request = try #require(try MetadataEditRequest.build(.shift(seconds: -3600),
                                                                for: records).get())
        #expect(request.groups.count == 2)
        #expect(request.groups[0].edit.captureTime?.date.timeIntervalSince1970 == -2_600)
        #expect(request.groups[0].edit.captureTime?.offset == "-04:00")
        #expect(request.groups[1].edit.captureTime?.date.timeIntervalSince1970 == 1_400)
        #expect(request.groups[1].edit.captureTime?.offset == "+09:00")
    }

    /// A file with no capture time has nothing to move, and "8 of 12 were
    /// shifted" discovered afterwards is worse than being told first.
    @Test func aShiftIsRefusedWhenAnySelectedFileHasNoCaptureTime() {
        let records = [record("a.jpg", id: 1, capture: 1_000, offset: "-04:00"),
                       record("b.jpg", id: 2)]
        let built = MetadataEditRequest.build(.shift(seconds: 60), for: records)
        guard case .failure(let refusal) = built else {
            Issue.record("a shift over a file with no capture time must be refused")
            return
        }
        #expect(refusal == .noCaptureTimeToShift(count: 1))
    }

    /// Spec §9, constraint 1, refused here rather than N times in a sheet.
    @Test(arguments: ["", "   "]) func aCaptureTimeWithNoZoneIsRefused(_ offset: String) {
        let built = MetadataEditRequest.build(
            .captureTime(wallClock: "2021-07-08 09:10:11", offset: offset),
            for: [record("a.jpg", id: 1)])
        guard case .failure(let refusal) = built else {
            Issue.record("a zone-less capture time must be refused")
            return
        }
        #expect(refusal == .captureTimeRequiresTimeZone)
    }

    /// The reader's strictness, restated: an offset the reader cannot parse
    /// round-trips to a different instant.
    @Test(arguments: ["-5:00", "EST", "+05", "-05:00:00", "05:00", "+25:00", "+00:99"])
    func anOffsetTheReaderCannotParseIsRefused(_ offset: String) {
        #expect(TimeZoneOffset.parse(offset) == nil)
        let built = MetadataEditRequest.build(
            .captureTime(wallClock: "2021-07-08 09:10:11", offset: offset),
            for: [record("a.jpg", id: 1)])
        guard case .failure(let refusal) = built else {
            Issue.record("\(offset) must be refused")
            return
        }
        #expect(refusal == .invalidTimeZoneOffset(offset))
    }

    /// **The two layers must agree.** An offset this one accepts and
    /// `MetadataWriter.validate` rejects is a batch that fails every item with
    /// a second, different sentence about the same box.
    ///
    /// Asserted through the real writer rather than against a copy of its
    /// rules: `validate` runs before any file is touched and before exiftool is
    /// reached for, so a path that does not exist gets as far as the validator
    /// and no further.
    @Test(arguments: ["-04:00", "+00:00", "+09:30", "-11:00", "+14:00"])
    func anOffsetThisLayerAcceptsIsOneTheWriterAccepts(_ offset: String) async throws {
        let capture = try #require(try MetadataEditRequest.captureTime(
            wallClock: "2021-07-08 09:10:11", offset: offset).get())
        // `.available` with a path that does not exist: validation happens
        // first, and the per-file `fileExists` check stops it before anything
        // is forked.
        let writer = MetadataWriter(availability: .available(path: "/nonexistent/exiftool",
                                                             version: "13.55"))
        let outcomes = await writer.write(MetadataEdit(captureTime: capture),
                                          to: [URL(fileURLWithPath: "/nonexistent/a.jpg")])
        let error = outcomes[0].error
        #expect(error == .fileMissing("/nonexistent/a.jpg"),
                "the writer refused an offset this layer accepted: \(String(describing: error))")
    }

    @Test func aWallClockThatIsNotADateIsRefused() {
        let built = MetadataEditRequest.build(
            .captureTime(wallClock: "last tuesday", offset: "-04:00"),
            for: [record("a.jpg", id: 1)])
        guard case .failure(let refusal) = built else {
            Issue.record("an unparseable wall clock must be refused")
            return
        }
        #expect(refusal == .invalidCaptureTime("last tuesday"))
    }

    /// The zone control opens on the file's own offset when the selection
    /// agrees, and on the machine's when it does not — but it is *shown* either
    /// way, which is the whole point of the control.
    @Test func theZoneDefaultsToTheFilesOwnOffsetWhenTheSelectionAgrees() {
        let agreeing = [record("a.jpg", id: 1, capture: 0, offset: "+09:30"),
                        record("b.jpg", id: 2, capture: 0, offset: "+09:30")]
        #expect(MetadataEditRequest.defaultOffset(for: agreeing) == "+09:30")
    }

    @Test func theZoneFallsBackToTheMachineWhenTheSelectionDisagrees() {
        let machine = TimeZone(secondsFromGMT: -7 * 3600)!
        let disagreeing = [record("a.jpg", id: 1, capture: 0, offset: "+09:30"),
                           record("b.jpg", id: 2, capture: 0, offset: "-04:00")]
        #expect(MetadataEditRequest.defaultOffset(for: disagreeing, zone: machine) == "-07:00")
    }

    @Test func theZoneFallsBackToTheMachineWhenNoFileCarriesOne() {
        let machine = TimeZone(secondsFromGMT: 5 * 3600 + 30 * 60)!
        #expect(MetadataEditRequest.defaultOffset(for: [record("a.jpg", id: 1)],
                                                  zone: machine) == "+05:30")
    }

    /// A stored offset the reader cannot parse is not a value to agree on: it
    /// would be refused on the way back out, so offering it would be offering a
    /// write that cannot happen.
    @Test func anUnparseableStoredOffsetIsNotOfferedBack() {
        let machine = TimeZone(secondsFromGMT: 0)!
        let records = [record("a.jpg", id: 1, capture: 0, offset: "EST")]
        #expect(MetadataEditRequest.defaultOffset(for: records, zone: machine) == "+00:00")
    }

    @Test func keywordsSplitOnCommasAndNewlines() {
        #expect(MetadataEditRequest.keywords(from: "alpha, beta\ngamma ,, ")
            == ["alpha", "beta", "gamma"])
        #expect(MetadataEditRequest.keywords(from: "   ").isEmpty)
    }

    /// An empty keyword string clears the set — `MetadataEdit.keywords`
    /// replaces wholesale — rather than being "nothing to write".
    @Test func anEmptyKeywordStringClearsTheSetRatherThanDoingNothing() throws {
        let request = try #require(try MetadataEditRequest.build(
            .keywords(""), for: [record("a.jpg", id: 1)]).get())
        #expect(request.groups[0].edit.keywords == [])
    }

    @Test(arguments: ["6", "-1", "five", "3.5"])
    func aRatingOutsideZeroToFiveIsRefused(_ text: String) {
        let built = MetadataEditRequest.build(.rating(text), for: [record("a.jpg", id: 1)])
        guard case .failure(let refusal) = built else {
            Issue.record("\(text) must be refused as a rating")
            return
        }
        #expect(refusal == .invalidRating(text))
    }

    /// Blank is "leave it alone", not zero. Zero is a real rating that clears a
    /// star count, and a user who empties the box has not asked for that.
    @Test func aBlankRatingIsNothingToWriteRatherThanZero() {
        let built = MetadataEditRequest.build(.rating(" "), for: [record("a.jpg", id: 1)])
        guard case .failure(let refusal) = built else {
            Issue.record("a blank rating must not become a zero")
            return
        }
        #expect(refusal == .nothingToWrite)
    }

    @Test func halfACoordinateIsNotAPosition() {
        let built = MetadataEditRequest.build(.gps(latitude: "37.7", longitude: ""),
                                              for: [record("a.jpg", id: 1)])
        guard case .failure(let refusal) = built else {
            Issue.record("an incomplete coordinate must be refused")
            return
        }
        #expect(refusal == .incompleteCoordinate)
    }

    @Test func aCoordinateOffTheEarthIsRefused() {
        let built = MetadataEditRequest.build(.gps(latitude: "91", longitude: "0"),
                                              for: [record("a.jpg", id: 1)])
        guard case .failure(let refusal) = built else {
            Issue.record("91 degrees of latitude must be refused")
            return
        }
        #expect(refusal == .invalidCoordinate(latitude: "91", longitude: "0"))
    }

    /// Spec §9, constraint 2, where the user can see it.
    @Test func aRawInTheSelectionIsAnnouncedAsASidecarWrite() {
        #expect(MetadataEditRequest.writesToSidecar([record("a.CR2", id: 1)]))
        #expect(MetadataEditRequest.writesToSidecar([record("a.jpg", id: 1),
                                                     record("b.nef", id: 2)]))
        #expect(!MetadataEditRequest.writesToSidecar([record("a.jpg", id: 1),
                                                      record("b.png", id: 2)]))
    }

    @Test func nothingIsBuiltFromAnEmptySelection() {
        guard case .failure(let refusal) = MetadataEditRequest.build(.artist("x"), for: []) else {
            Issue.record("an empty selection must be refused")
            return
        }
        #expect(refusal == .noSelection)
    }
}

// MARK: - Text parsing

struct ShiftAmountTests {
    @Test func plainSecondsAndClockFormsBothParse() {
        #expect(ShiftAmount.parseSeconds("-3600") == -3600)
        #expect(ShiftAmount.parseSeconds("37") == 37)
        #expect(ShiftAmount.parseSeconds("+37") == 37)
        #expect(ShiftAmount.parseSeconds("-1:00:00") == -3600)
        #expect(ShiftAmount.parseSeconds("2:30") == 9_000)
        #expect(ShiftAmount.parseSeconds("0:00:05") == 5)
    }

    /// An empty box is a field the user has not filled in, not a shift of zero.
    @Test(arguments: ["", "   ", "-", "1:", ":30", "1:2:3:4", "x", "1.5"])
    func anythingElseIsRefused(_ text: String) {
        #expect(ShiftAmount.parseSeconds(text) == nil)
    }
}

struct WallClockTests {
    @Test func theWallClockIsReadInTheZoneItIsShownWith() throws {
        let east = try #require(TimeZoneOffset.parse("+00:00"))
        let west = try #require(TimeZoneOffset.parse("-05:00"))
        let atUTC = try #require(WallClock.parse("2021-07-08 09:10:11", in: east))
        let atNewYork = try #require(WallClock.parse("2021-07-08 09:10:11", in: west))
        // Same wall clock, different zone, five hours apart. If the zone were
        // ignored these would be equal, which is spec §9's whole objection to
        // a `DateTimeOriginal` with no `OffsetTimeOriginal`.
        #expect(atNewYork.timeIntervalSince(atUTC) == 5 * 3600)
    }

    @Test func theSecondsLessFormIsAccepted() throws {
        let zone = try #require(TimeZoneOffset.parse("+00:00"))
        let withSeconds = try #require(WallClock.parse("2021-07-08 09:10:00", in: zone))
        #expect(WallClock.parse("2021-07-08 09:10", in: zone) == withSeconds)
    }

    @Test func offsetsRoundTripThroughTheFormatter() {
        #expect(TimeZoneOffset.format(secondsFromGMT: -4 * 3600) == "-04:00")
        #expect(TimeZoneOffset.format(secondsFromGMT: 0) == "+00:00")
        #expect(TimeZoneOffset.format(secondsFromGMT: 5 * 3600 + 45 * 60) == "+05:45")
    }
}

// MARK: - The batch, through the model

/// What the window does with a committed field: one batch, the right shape, the
/// grid reloaded from the index, and nothing offered to ⌘Z.
@MainActor
struct InspectorEditingTests {
    let tree: TempDirectory
    let preferences = MemoryPreferences()

    init() throws { tree = try TempDirectory() }

    /// A window with `count` files selected and a stub writer in place of
    /// exiftool.
    private func window(files count: Int,
                        availability: ExiftoolAvailability = .available(path: "/stub/exiftool",
                                                                        version: "13.55"))
    async throws -> (BrowserModel, RecordingMetadataWriter, URL) {
        let root = try tree.directory("library")
        for index in 1...count {
            try tree.file("library/IMG_000\(index).jpg", bytes: 64)
        }
        let model = BrowserModel(store: try IndexStore.inMemory(), preferences: preferences)
        let writer = RecordingMetadataWriter(availability: availability)
        model.metadataWriter = writer
        await model.open(root)
        await model.resolveMetadataAvailability()
        model.selectAll()
        return (model, writer, root)
    }

    /// **The acceptance bullet.** A field edit on a 3-file selection produces
    /// *one* writer batch of 3.
    ///
    /// Both numbers are asserted because both are mutations that pass the other
    /// half: a model that looped would produce three calls of one, and a model
    /// that built its request from the wrong source would produce one call of
    /// the wrong size.
    @Test func aFieldEditOnThreeFilesIsOneWriterBatchOfThree() async throws {
        let (model, writer, _) = try await window(files: 3)
        #expect(model.selectedRecords.count == 3)

        let refusal = await model.commitMetadataField(.artist("Ansel"))
        #expect(refusal == nil)

        #expect(writer.calls.count == 1,
                "expected one batch, got \(writer.calls.count) — a per-file loop is not a batch")
        #expect(writer.calls[0].urls.count == 3)
        #expect(writer.calls[0].urls.map(\.lastPathComponent).sorted()
            == ["IMG_0001.jpg", "IMG_0002.jpg", "IMG_0003.jpg"])
        #expect(writer.calls[0].edit.artist == "Ansel")
        // Only the field that was committed: a request that carried the other
        // boxes' contents would overwrite fields nobody edited.
        #expect(writer.calls[0].edit.copyright == nil)
        #expect(writer.calls[0].edit.captureTime == nil)
    }

    /// **The acceptance bullet.** A zone-less capture time is rejected before
    /// reaching the writer.
    ///
    /// The second assertion is the one that matters: `MetadataWriter.validate`
    /// would refuse this too, so a model with no guard at all still ends up
    /// writing nothing — and would still be wrong, because the user would get
    /// three identical failure rows in a summary sheet instead of a sentence
    /// under the box.
    @Test func aZoneLessCaptureTimeNeverReachesTheWriter() async throws {
        let (model, writer, _) = try await window(files: 3)

        let refusal = await model.commitMetadataField(
            .captureTime(wallClock: "2021-07-08 09:10:11", offset: ""))

        #expect(refusal == .captureTimeRequiresTimeZone)
        #expect(writer.calls.isEmpty,
                "a zone-less capture time reached the writer as \(writer.calls.count) call(s)")
        #expect(model.batchProgress == nil)
        #expect(model.activeSheet == nil)
    }

    /// **The acceptance bullet.** With the writer reporting unavailable, no
    /// field is editable — and a commit that arrives anyway writes nothing.
    @Test func withExiftoolUnavailableNoFieldIsEditable() async throws {
        let (model, writer, _) = try await window(files: 3, availability: .notFound)

        #expect(!model.isMetadataEditingAvailable)
        #expect(!model.canEditMetadata)
        #expect(!model.canStartMetadataBatch)
        let explanation = try #require(model.metadataUnavailableExplanation)
        #expect(explanation.contains("exiftool"))

        let refusal = await model.commitMetadataField(.artist("Ansel"))
        #expect(refusal == .editingUnavailable)
        #expect(writer.calls.isEmpty,
                "editing was disabled and the writer was still called")
    }

    /// The explanation says "install it, then try again", and a cached answer
    /// would make that instruction a lie.
    @Test func tryAgainReRunsTheLookup() async throws {
        let (model, writer, _) = try await window(files: 1, availability: .notFound)
        #expect(!model.isMetadataEditingAvailable)

        writer.become(.available(path: "/stub/exiftool", version: "13.55"))
        await model.resolveMetadataAvailability(recheck: true)

        #expect(writer.rechecks == 1)
        #expect(model.isMetadataEditingAvailable)
    }

    /// A resolve that is not a recheck asks once and keeps the answer: a batch
    /// of 500 files must not fork 500 `-ver` probes.
    @Test func theProbeIsResolvedOncePerWindow() async throws {
        let (model, writer, _) = try await window(files: 1)
        await model.resolveMetadataAvailability()
        await model.resolveMetadataAvailability()
        #expect(writer.rechecks == 0)
        #expect(model.isMetadataEditingAvailable)
    }

    /// A sequence is N groups of one, so it is N writer calls — each with its
    /// own instant, in the grid's sort order.
    @Test func aSequenceIsOneWriterCallPerFileWithItsOwnInstant() async throws {
        let (model, writer, _) = try await window(files: 5)

        let refusal = await model.applyBatchTimeOperation(
            .sequence(startWallClock: "2021-07-08 09:10:11", offset: "-04:00",
                      intervalSeconds: 10))
        #expect(refusal == nil)

        #expect(writer.calls.count == 5)
        let zone = try #require(TimeZoneOffset.parse("-04:00"))
        let start = try #require(WallClock.parse("2021-07-08 09:10:11", in: zone))
        for (index, call) in writer.calls.enumerated() {
            #expect(call.urls.map(\.lastPathComponent) == ["IMG_000\(index + 1).jpg"])
            #expect(call.edit.captureTime?.date
                == start.addingTimeInterval(Double(index) * 10))
        }
    }

    /// Set-to-a-fixed-value is one batch, like any other field: every file gets
    /// the same instant.
    @Test func setToAFixedValueIsOneBatch() async throws {
        let (model, writer, _) = try await window(files: 3)
        let refusal = await model.applyBatchTimeOperation(
            .set(wallClock: "2021-07-08 09:10:11", offset: "-04:00"))
        #expect(refusal == nil)
        #expect(writer.calls.count == 1)
        #expect(writer.calls[0].urls.count == 3)
    }

    /// **The grid updates from the index, never by rescanning.**
    ///
    /// `ghost.jpg` is the assertion, not decoration: it is created on disk
    /// after the folder was indexed, so only a tier 0 pass could put it in the
    /// grid. A `refresh()` here would still leave the edited files right, and
    /// would still be wrong — it re-walks the folder, which is minutes on an
    /// external drive, to learn what the writer told the index a millisecond
    /// ago.
    @Test func aSuccessfulWriteReloadsTheGridWithoutRescanningTheFolder() async throws {
        let (model, _, _) = try await window(files: 2)
        #expect(model.records.count == 2)

        try tree.file("library/ghost.jpg", bytes: 16)
        await model.commitMetadataField(.artist("Ansel"))

        #expect(model.records.count == 2,
                "the grid holds \(model.records.map(\.name)); a rescan would have added ghost.jpg")
        #expect(model.batchProgress == nil, "the progress indicator outlived the batch")
        #expect(model.activeSheet == nil,
                "a metadata batch with nothing to report must not raise a sheet")
    }

    /// The selection survives the reload, because the same rows are still
    /// there — a metadata write moves nothing.
    @Test func theSelectionSurvivesAMetadataWrite() async throws {
        let (model, _, _) = try await window(files: 3)
        let before = model.selection.selected
        await model.commitMetadataField(.label("Red"))
        #expect(model.selection.selected == before)
    }

    /// **Not ⌘Z-able, and the model says so.** A metadata edit writes no
    /// `op_journal` rows, so recording it as the last completed batch would
    /// leave ⌘Z offering to undo this write and actually reversing whatever
    /// file operation came before it.
    @Test func aMetadataEditIsNeverOfferedToUndo() async throws {
        let (model, _, root) = try await window(files: 2)
        // A real, undoable file batch first, so "nothing to undo" cannot pass
        // for the right answer by accident.
        let destination = try tree.directory("elsewhere")
        await model.beginBatch(.copy, destination: destination)
        let afterCopy = try #require(model.lastCompletedBatch)

        await model.open(root)
        model.selectAll()
        await model.commitMetadataField(.artist("Ansel"))

        #expect(model.lastCompletedBatch?.batchID == afterCopy.batchID,
                "the metadata write replaced the copy as ⌘Z's subject")
        #expect(model.undoMenuTitle == afterCopy.undoTitle)
    }

    /// Spec §11: a batch never fails as a unit, and the sheet reports the
    /// exceptions.
    @Test func aFailedItemRaisesTheSummarySheetAndTheRestStillWrite() async throws {
        let (model, writer, _) = try await window(files: 3)
        writer.fail("IMG_0002.jpg", with: .exiftoolFailed("no room on device"))

        await model.commitMetadataField(.artist("Ansel"))

        guard case .metadataSummary(let summary)? = model.activeSheet else {
            Issue.record("expected the metadata summary sheet, got \(model.activeSheet.map(\.id) ?? "no sheet")")
            return
        }
        #expect(summary.failures.count == 1)
        #expect(summary.failures[0].source.lastPathComponent == "IMG_0002.jpg")
        #expect(summary.failures[0].detail.contains("no room on device"))
        #expect(summary.written == 2)
    }

    /// Two of the five warnings are expected rather than surprising, and a
    /// sheet in front of every HEIC edit is a sheet nobody reads.
    @Test func anExpectedWarningDoesNotRaiseASheetButASurprisingOneDoes() async throws {
        let (quiet, quietWriter, _) = try await window(files: 1)
        quietWriter.warn(.imageHashUnavailable(kind: "heic"))
        await quiet.commitMetadataField(.artist("Ansel"))
        #expect(quiet.activeSheet == nil,
                "an expected warning raised the sheet \(quiet.activeSheet.map(\.id) ?? "-")")

        let (loud, loudWriter, _) = try await window(files: 1)
        loudWriter.warn(.indexRowNotUpdated)
        await loud.commitMetadataField(.artist("Ansel"))
        guard case .metadataSummary? = loud.activeSheet else {
            Issue.record("a surprising warning must be reported")
            return
        }
    }

    /// One progress sheet, not two — and it says what it is doing.
    @Test func theProgressSheetNamesAMetadataBatch() {
        let metadata = BatchProgress(kind: .metadata, completed: 1, total: 4, current: nil)
        #expect(metadata.title == "Writing metadata to 4 files…")
        #expect(metadata.fraction == 0.25)
        // The file-operation spelling still reads as it did.
        #expect(BatchProgress(kind: .move, completed: 0, total: 2, current: nil).title
            == "Moving 2 items…")
    }

    /// The batch-time sheet is the sheet on screen when Apply is pressed, so
    /// the "no sheet may be up" rule the field commits follow would refuse
    /// every press of it.
    @Test func theBatchTimeSheetCanApplyWhileItIsItselfOnScreen() async throws {
        let (model, writer, _) = try await window(files: 2)
        model.openBatchTimeSheet()
        #expect(model.activeSheet?.id == "batchTime")

        let refusal = await model.applyBatchTimeOperation(
            .set(wallClock: "2021-07-08 09:10:11", offset: "-04:00"))
        #expect(refusal == nil)
        #expect(writer.calls.count == 1)
        #expect(model.activeSheet == nil)
    }

    /// A field commit, on the other hand, waits for whatever question is on
    /// screen to be answered — the same rule the four batch commands follow.
    @Test func aFieldCommitIsRefusedWhileASheetIsWaiting() async throws {
        let (model, writer, _) = try await window(files: 2)
        model.openBatchTimeSheet()

        let refusal = await model.commitMetadataField(.artist("Ansel"))
        #expect(refusal == .busy)
        #expect(writer.calls.isEmpty)
    }

    /// A RAW selection's writes land in sidecars, and the summary counts them
    /// so the user knows the containers were not opened.
    @Test func aRawWriteIsCountedAsASidecar() async throws {
        let root = try tree.directory("raws")
        try tree.file("raws/IMG_0001.cr2", bytes: 64)
        let model = BrowserModel(store: try IndexStore.inMemory(), preferences: preferences)
        let writer = RecordingMetadataWriter()
        writer.warn(.indexRowNotUpdated)   // raises the sheet so it can be read
        model.metadataWriter = writer
        await model.open(root)
        await model.resolveMetadataAvailability()
        model.selectAll()
        #expect(MetadataEditRequest.writesToSidecar(model.selectedRecords))

        await model.commitMetadataField(.artist("Ansel"))
        guard case .metadataSummary(let summary)? = model.activeSheet else {
            Issue.record("expected the metadata summary sheet")
            return
        }
        #expect(summary.sidecars == 1)
    }
}

// MARK: - The real writer

/// The one test that writes bytes. Everything above proves what the *window*
/// decides; this proves the window is wired to something that actually writes.
@MainActor
struct InspectorLiveWriteTests {
    let tree: TempDirectory
    let preferences = MemoryPreferences()

    init() throws { tree = try TempDirectory() }

    /// Three real JPEGs, Artist set from the inspector, read back with
    /// ImageIO — the automated half of the live check §7 owes.
    @Test(needsExiftool) func settingArtistOnThreeJPEGsWritesAllThree() async throws {
        let root = try tree.directory("library")
        for index in 1...3 {
            try writeJPEG(to: root.appendingPathComponent("IMG_000\(index).jpg"))
        }
        let model = BrowserModel(store: try IndexStore.inMemory(), preferences: preferences)
        await model.open(root)
        await model.resolveMetadataAvailability()
        try #require(model.isMetadataEditingAvailable,
                     "exiftool is on PATH but the window did not resolve it")
        model.selectAll()
        #expect(model.selectedRecords.count == 3)

        let refusal = await model.commitMetadataField(.artist("Ansel Adams"))
        #expect(refusal == nil)
        if case .metadataSummary(let summary)? = model.activeSheet {
            #expect(summary.failures.isEmpty,
                    "\(summary.failures.map(\.detail))")
        }

        for index in 1...3 {
            let url = root.appendingPathComponent("IMG_000\(index).jpg")
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] ?? [:]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            #expect(tiff[kCGImagePropertyTIFFArtist] as? String == "Ansel Adams",
                    "IMG_000\(index).jpg did not get the Artist")
            // The write commits by removing its own backup.
            #expect(!FileManager.default.fileExists(atPath: url.path + "_original"))
        }
    }
}

// MARK: - The focus contract

/// **Every text field in the app must call `reportingTextFocus`.** A field that
/// forgets leaves ⌘Z reversing the last file batch while the user types in it,
/// and #9 added ten of them at once. `BrowserModel.TextField` is the checklist;
/// this walks the rendered inspector against it.
///
/// Serialized for the reason `TextFocusReportingTests` is: it puts a real
/// window on screen.
@Suite(.serialized)
@MainActor
struct InspectorTextFocusTests {
    /// The ten boxes the editable inspector renders, all of them reporting and
    /// all of them reporting *distinctly* — asserted as a union, so nothing
    /// depends on the order SwiftUI lays them out in.
    @Test func everyInspectorFieldReportsItsFocus() async throws {
        let tree = try TempDirectory()
        let root = try tree.directory("library")
        try tree.file("library/IMG_0001.jpg", bytes: 64)
        let model = BrowserModel(store: try IndexStore.inMemory(),
                                 preferences: MemoryPreferences())
        // A stub in place of the probe: the test host's PATH has no exiftool,
        // and with the fields rendered read-only there would be nothing to
        // focus and this would pass by rendering nothing.
        model.metadataWriter = RecordingMetadataWriter()
        await model.open(root)
        model.selectAll()
        await model.resolveMetadataAvailability()
        try #require(model.isMetadataEditingAvailable)

        let expected: Set<BrowserModel.TextField> = [
            .inspectorCaptureTime, .inspectorCaptureZone, .inspectorArtist,
            .inspectorCopyright, .inspectorDescription, .inspectorKeywords,
            .inspectorRating, .inspectorLabel, .inspectorLatitude, .inspectorLongitude]

        let (window, fields) = renderFields(InspectorView(model: model),
                                            count: expected.count)
        defer { window.close() }
        try #require(fields.count >= expected.count,
                     "the inspector rendered \(fields.count) editable fields, expected \(expected.count)")

        var seen: Set<BrowserModel.TextField> = []
        for field in fields.prefix(expected.count) {
            focus(field, in: model)
            seen.formUnion(model.editingFields)
        }
        #expect(seen == expected,
                "the inspector's fields reported \(seen.map(\.self)); every one must report, and distinctly")
    }
}
