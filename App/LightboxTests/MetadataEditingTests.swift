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
/// Lets a test stand at an exact point inside a batch, with no sleep and no
/// poll anywhere in it.
///
/// **Sleeping and polling is what made the first version of the cancel test
/// flaky, and the reason is worth keeping.** The App suite runs suites in
/// parallel in one process, and three of them block the main actor
/// *synchronously* for seconds at a time — `renderFields`, `focus` and
/// `waitForEditableFieldsToDisappear` all spin `RunLoop.current.run`. The stub
/// writer is nonisolated, so it kept going while the main actor was blocked: by
/// the time the test's `@MainActor` poll of `batchProgress` got to run, the
/// batch had finished all five files and `endBatch()` had set `batchProgress`
/// back to nil, so the poll read `nil ?? 0` for its whole deadline and the test
/// failed claiming the batch "never started". 3 of 10 full runs.
///
/// So the stub parks instead. `reach(_:)` reports a finished item *and blocks
/// the writer there* until `release()`, and `waitForReach(_:)` returns when it
/// has. Neither side can outrun the other however long the main actor is held.
actor WriteGate {
    /// How many items the stub finishes before it parks.
    let pauseAfter: Int

    private var reached = 0
    private var observer: (count: Int, continuation: CheckedContinuation<Void, Never>)?
    private var parked: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(pauseAfter: Int) { self.pauseAfter = pauseAfter }

    /// Writer side: item `count` is done. Parks on the nth until released.
    func reach(_ count: Int) async {
        reached = count
        if let observer, observer.count <= count {
            self.observer = nil
            observer.continuation.resume()
        }
        guard count == pauseAfter, !isReleased else { return }
        // The body runs synchronously before the suspension, so `release()`
        // cannot land between the guard and the continuation being stored —
        // and `isReleased` covers a release that arrives before the park.
        await withCheckedContinuation { parked = $0 }
    }

    /// Test side: returns once the writer has finished `count` items.
    func waitForReach(_ count: Int) async {
        if reached >= count { return }
        await withCheckedContinuation { observer = (count, $0) }
    }

    /// Test side: lets the parked writer go.
    func release() {
        isReleased = true
        parked?.resume()
        parked = nil
    }
}

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
    /// Files the stub got as far as, in order. The stand-in for "already
    /// written stays written" — a stub writes no bytes, but it can say which
    /// files it reached before Stop.
    private var _written: [URL] = []
    /// Where a test wants the batch to stand still. See `WriteGate`.
    private var _gate: WriteGate?

    init(availability: ExiftoolAvailability = .available(path: "/stub/exiftool",
                                                         version: "13.55")) {
        _availability = availability
    }

    var calls: [Call] { lock.withLock { _calls } }
    var rechecks: Int { lock.withLock { _rechecks } }
    var written: [URL] { lock.withLock { _written } }

    func park(at gate: WriteGate) { lock.withLock { _gate = gate } }

    func fail(_ name: String, with error: MetadataWriteError) {
        lock.withLock { _failures[name] = error }
    }

    func warn(_ warning: WriteWarning) {
        lock.withLock { _warnings.append(warning) }
    }

    func become(_ availability: ExiftoolAvailability) {
        lock.withLock { _availability = availability }
    }

    /// #51: the paths handed to `setStoredPath`, in order. `[nil]` is a clear.
    private var _storedPaths: [String?] = []
    /// What `validate` answers. Available by default — a test that cares about
    /// a refusal says so.
    private var _validation: ExiftoolAvailability = .available(path: "/stub/exiftool",
                                                               version: "13.55")

    var storedPaths: [String?] { lock.withLock { _storedPaths } }

    func refuseValidation(reason: String) {
        lock.withLock {
            _validation = .unusable(path: "/stub/refused", reason: reason)
        }
    }

    func availability() async -> ExiftoolAvailability { lock.withLock { _availability } }

    func recheckAvailability() async -> ExiftoolAvailability {
        lock.withLock {
            _rechecks += 1
            return _availability
        }
    }

    func validate(_ path: String) async -> ExiftoolAvailability { lock.withLock { _validation } }

    func setStoredPath(_ path: String?) async -> ExiftoolAvailability {
        lock.withLock {
            _storedPaths.append(path)
            // The real one re-resolves; a stub that reports the new path as
            // available is what lets the caller's `metadataAvailability`
            // assertion mean something.
            if let path {
                _availability = .available(path: path, version: "13.55")
            }
            return _availability
        }
    }

    func write(_ edit: MetadataEdit, to urls: [URL],
               progress: @escaping @Sendable (Int, Int) -> Void) async -> [WriteOutcome] {
        let (failures, warnings, sidecars, gate) = lock.withLock {
            () -> ([String: MetadataWriteError], [WriteWarning], Set<String>, WriteGate?) in
            _calls.append(Call(edit: edit, urls: urls))
            return (_failures, _warnings, _sidecarExtensions, _gate)
        }
        var outcomes: [WriteOutcome] = []
        for (index, url) in urls.enumerated() {
            // **Between items, never inside one** — the real writer's rule, so
            // a cancelled stub batch has the shape a cancelled real one does.
            if Task.isCancelled {
                outcomes.append(WriteOutcome(source: url, result: .failure(.cancelled)))
                progress(index + 1, urls.count)
                continue
            }
            if let failure = failures[url.lastPathComponent] {
                outcomes.append(WriteOutcome(source: url, result: .failure(failure)))
            } else {
                lock.withLock { _written.append(url) }
                let isSidecar = sidecars.contains(url.pathExtension.lowercased())
                let written = isSidecar
                    ? url.deletingPathExtension().appendingPathExtension("xmp") : url
                outcomes.append(WriteOutcome(source: url, result: .success(
                    WriteSuccess(written: written,
                                 target: isSidecar ? .sidecar(written) : .inPlace,
                                 rehash: nil, warnings: warnings))))
            }
            progress(index + 1, urls.count)
            // After the item and after the progress report, so a test that has
            // been let through knows both have happened.
            await gate?.reach(index + 1)
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
///
/// **It carries a TIFF Make and Model, and that is not decoration.** A JPEG
/// written with no properties at all has no TIFF IFD, and ImageIO then reports
/// *no* `kCGImagePropertyTIFFDictionary` for it — even after exiftool has put an
/// `IFD0:Artist` in the file, which `exiftool -a -G1` shows plainly. Read back
/// through `{TIFF}`, a perfectly good write therefore looks like no write at
/// all. Every real photo has a Make and Model, `Core`'s `Fixtures.writeImage`
/// seeds the same two, and this fixture only looked like a photo until #41 made
/// the test that uses it run for the first time.
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
    let properties: [CFString: Any] = [
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam",
                                         kCGImagePropertyTIFFModel: "T1"],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw MetadataError.unreadable }
}

/// The same lookup the writer performs, as CONTRIBUTING requires of a skip
/// guard. A guard that checked `/opt/homebrew/bin/exiftool` while the writer
/// searched `PATH` would be green on CI and prove nothing.
///
/// **This line is #41's before/after evidence.** The test host is the real
/// `Lightbox.app`, and a GUI-launched process gets
/// `PATH=/usr/bin:/bin:/usr/sbin:/sbin` — so until the lookup grew a
/// login-shell rung and a prefix list, this skipped on a machine with exiftool
/// installed, which is exactly what the shipped app did to every user. It runs
/// on such a machine now, and still skips cleanly on CI, which has exiftool in
/// none of the places the four rungs look.
private let needsExiftool = ConditionTrait.enabled(
    if: MetadataWriter.availability.isAvailable,
    "exiftool was not found — the inspector's live write test is skipped")

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

    /// **A shift may not invent a zone.** Substituting the machine's for a file
    /// that carries none writes an `OffsetTimeOriginal` nobody asked for —
    /// §9 constraint 1 read backwards — and would format it at the *pre-shift*
    /// instant, so a shift across a DST boundary would stamp the wrong one.
    @Test func aShiftIsRefusedWhenAFileHasNoParseableTimeZone() {
        let records = [record("a.jpg", id: 1, capture: 1_000, offset: "-04:00"),
                       record("b.jpg", id: 2, capture: 2_000),
                       record("c.jpg", id: 3, capture: 3_000, offset: "EST")]
        let built = MetadataEditRequest.build(.shift(seconds: 60), for: records)
        guard case .failure(let refusal) = built else {
            Issue.record("a shift over files with no zone must be refused")
            return
        }
        #expect(refusal == .noTimeZoneToShift(count: 2))
    }

    /// Spec §9, constraint 1, refused here rather than N times in a sheet.
    @Test(arguments: ["", "   "]) func aCaptureTimeWithNoZoneIsRefused(_ offset: String) {
        let built = MetadataEditRequest.build(
            .captureTime(wallClock: "2021-07-08 09:10:11", offset: offset, seed: nil),
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
            .captureTime(wallClock: "2021-07-08 09:10:11", offset: offset, seed: nil),
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

    /// The zone box is always populated and the wall clock is not, so a Return
    /// in the zone box of a selection whose capture times disagree must not
    /// report `"" is not a date and time` for a field nobody touched.
    @Test(arguments: ["", "   "]) func aBlankWallClockIsUnchanged(_ wallClock: String) {
        let built = MetadataEditRequest.build(
            .captureTime(wallClock: wallClock, offset: "-04:00", seed: nil),
            for: [record("a.jpg", id: 1)])
        guard case .failure(let refusal) = built else {
            Issue.record("a blank capture time must change nothing")
            return
        }
        #expect(refusal == .nothingToWrite)
    }

    /// **The two pre-filled boxes obey the same rule, stated against the seed.**
    /// `onSubmit` fires on every Return, so without this, tabbing through an
    /// untouched inspector rewrites every selected file to the capture time it
    /// already has.
    @Test func aCaptureTimeStillHoldingItsSeedChangesNothing() {
        let seed = CaptureTimeSeed(wallClock: "2021-07-08 09:10:11", offset: "-04:00")
        let built = MetadataEditRequest.build(
            .captureTime(wallClock: "2021-07-08 09:10:11", offset: "-04:00", seed: seed),
            for: [record("a.jpg", id: 1)])
        guard case .failure(let refusal) = built else {
            Issue.record("an untouched capture-time pair must change nothing")
            return
        }
        #expect(refusal == .nothingToWrite)
    }

    /// Either box moving is a real edit — the zone especially, because changing
    /// it alone is exactly how a mis-zoned camera is corrected.
    @Test(arguments: [("2021-07-08 09:10:12", "-04:00"), ("2021-07-08 09:10:11", "-05:00")])
    func aCaptureTimePairThatMovedStillWrites(_ pair: (String, String)) throws {
        let seed = CaptureTimeSeed(wallClock: "2021-07-08 09:10:11", offset: "-04:00")
        let request = try #require(try MetadataEditRequest.build(
            .captureTime(wallClock: pair.0, offset: pair.1, seed: seed),
            for: [record("a.jpg", id: 1)]).get())
        #expect(request.groups[0].edit.captureTime != nil)
    }

    @Test func aWallClockThatIsNotADateIsRefused() {
        let built = MetadataEditRequest.build(
            .captureTime(wallClock: "last tuesday", offset: "-04:00", seed: nil),
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

    /// **The one rule: blank means unchanged, keywords included.**
    ///
    /// Keywords used to be the exception — an empty box cleared the set,
    /// because `MetadataEdit.keywords` replaces wholesale. One rule everywhere
    /// is worth more than that convenience, and it is the same rule that stops
    /// a stray Return in an untouched Artist box erasing Artist across the
    /// selection.
    @Test(arguments: [MetadataFieldEdit.artist(""), .copyright("  "), .description(""),
                      .label(" "), .keywords(""), .keywords(" , , ")])
    func aBlankBoxIsUnchangedForEveryField(_ edit: MetadataFieldEdit) {
        let built = MetadataEditRequest.build(edit, for: [record("a.jpg", id: 1)])
        guard case .failure(let refusal) = built else {
            Issue.record("a blank \(edit.field.rawValue) box must change nothing")
            return
        }
        #expect(refusal == .nothingToWrite)
    }

    /// Erasing is its own gesture, and it is the *only* thing that produces the
    /// tag-removing write `MetadataWriter` turns an empty string into.
    @Test func clearingAFieldIsWhatProducesTheErasingWrite() throws {
        let records = [record("a.jpg", id: 1), record("b.jpg", id: 2)]
        let artist = try #require(try MetadataEditRequest.build(.clear(.artist),
                                                                for: records).get())
        #expect(artist.groups.count == 1)
        #expect(artist.groups[0].urls.count == 2)
        #expect(artist.groups[0].edit.artist == "")

        let keywords = try #require(try MetadataEditRequest.build(.clear(.keywords),
                                                                  for: records).get())
        #expect(keywords.groups[0].edit.keywords == [])
    }

    /// The three fields `MetadataEdit` cannot spell "remove this" for have no
    /// Clear control, and asking for one anyway changes nothing.
    @Test func onlyTheTextFieldsAreClearable() {
        #expect(MetadataField.allCases.filter(\.isClearable).map(\.rawValue).sorted()
            == ["artist", "copyright", "description", "keywords", "label"])
        for field in MetadataField.allCases where !field.isClearable {
            guard case .failure(let refusal) = MetadataEditRequest.build(
                .clear(field), for: [record("a.jpg", id: 1)]) else {
                Issue.record("\(field.rawValue) has no erase and must refuse one")
                return
            }
            #expect(refusal == .nothingToWrite)
        }
    }

    /// A value still writes, and arrives trimmed.
    @Test func aFilledBoxStillWritesAndIsTrimmed() throws {
        let request = try #require(try MetadataEditRequest.build(
            .artist("  Ansel Adams  "), for: [record("a.jpg", id: 1)]).get())
        #expect(request.groups[0].edit.artist == "Ansel Adams")
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

    /// Spec §9, constraint 2, where the user can see it — **and counted**. A
    /// RAW+JPEG pair is the common selection, and "writes to an .xmp sidecar"
    /// over a selection where two of thirty do is a claim about the other
    /// twenty-eight that is not true.
    @Test func theSidecarNoticeCountsRatherThanClaimingTheWholeSelection() throws {
        #expect(MetadataEditRequest.sidecarNotice([record("a.png", id: 1)]) == nil)

        let allRaw = try #require(MetadataEditRequest.sidecarNotice(
            [record("a.CR2", id: 1), record("b.nef", id: 2)]))
        #expect(allRaw == "These write to .xmp sidecars; the RAW files are untouched.")

        let one = try #require(MetadataEditRequest.sidecarNotice([record("a.CR2", id: 1)]))
        #expect(one == "Writes to an .xmp sidecar; the RAW file is untouched.")

        let mixed = try #require(MetadataEditRequest.sidecarNotice(
            [record("a.jpg", id: 1), record("b.nef", id: 2), record("c.png", id: 3)]))
        #expect(mixed
            == "1 of these write to an .xmp sidecar; those RAW files are untouched.")
    }

    /// The partition, at the value: `.cancelled` is a count, never a failure
    /// row, so it cannot raise the sheet on its own.
    @Test func cancelledOutcomesAreCountedNotReportedAsFailures() {
        let a = URL(fileURLWithPath: "/library/a.jpg")
        let b = URL(fileURLWithPath: "/library/b.jpg")
        let c = URL(fileURLWithPath: "/library/c.jpg")
        let summary = MetadataSummary(outcomes: [
            WriteOutcome(source: a, result: .success(
                WriteSuccess(written: a, target: .inPlace, rehash: nil, warnings: []))),
            WriteOutcome(source: b, result: .failure(.cancelled)),
            WriteOutcome(source: c, result: .failure(.cancelled)),
        ], wasCancelled: true)

        #expect(summary.written == 1)
        #expect(summary.notReached == 2)
        #expect(summary.failures.isEmpty,
                "a stopped batch reported \(summary.failures.count) failures")
        #expect(!summary.isWorthShowing,
                "a clean stop must not put a sheet in front of the user")
    }

    /// A real failure still reports, and the stop then explains the arithmetic.
    @Test func aRealFailureAlongsideAStopStillRaisesTheSheet() {
        let a = URL(fileURLWithPath: "/library/a.jpg")
        let b = URL(fileURLWithPath: "/library/b.jpg")
        let summary = MetadataSummary(outcomes: [
            WriteOutcome(source: a, result: .failure(.exiftoolFailed("no room"))),
            WriteOutcome(source: b, result: .failure(.cancelled)),
        ], wasCancelled: true)
        #expect(summary.failures.count == 1)
        #expect(summary.notReached == 1)
        #expect(summary.isWorthShowing)
        #expect(summary.headline == "1 file could not be written. The batch was stopped.")
        // The count is what explains why the numbers do not add up, so it has
        // to reach the sheet rather than only the value — `MetadataSummarySheet`
        // renders exactly this string.
        #expect(summary.notReachedNote == "1 file was not reached before the batch was stopped.")
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
    /// - Parameter sort: applied **before** `open`, so the grid's first and only
    ///   awaited reload already has it. Setting it afterwards would mean waiting
    ///   on `sort`'s `didSet` — a reload this helper does not hold and cannot
    ///   await — which is a poll, and a poll in this process races the suites
    ///   that block the main actor for seconds at a time.
    private func window(files count: Int,
                        availability: ExiftoolAvailability = .available(path: "/stub/exiftool",
                                                                        version: "13.55"),
                        sort: SearchQuery.Sort? = nil)
    async throws -> (BrowserModel, RecordingMetadataWriter, URL) {
        let root = try tree.directory("library")
        for index in 1...count {
            try tree.file("library/IMG_000\(index).jpg", bytes: 64)
        }
        let model = BrowserModel(store: try IndexStore.inMemory(), preferences: preferences)
        let writer = RecordingMetadataWriter(availability: availability)
        model.metadataWriter = writer
        if let sort { model.sort = sort }
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
            .captureTime(wallClock: "2021-07-08 09:10:11", offset: "", seed: nil))

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

    /// **The one rule, at the model.** A Return in an untouched box must reach
    /// no writer at all — `onSubmit` fires whether or not the text changed, so
    /// without this a stray Return on a 300-file selection erases the tag on
    /// 300 files and rewrites every one of them, with no ⌘Z behind it.
    @Test(arguments: [MetadataFieldEdit.artist(""), .copyright(""), .description(""),
                      .label(""), .keywords("")])
    func aBlankBoxCommitsNothing(_ edit: MetadataFieldEdit) async throws {
        let (model, writer, _) = try await window(files: 3)

        let refusal = await model.commitMetadataField(edit)

        #expect(refusal == .nothingToWrite)
        #expect(writer.calls.isEmpty,
                "a blank \(edit.field.rawValue) box reached the writer as \(writer.calls.count) call(s), which would erase the tag")
        #expect(model.activeSheet == nil)
    }

    /// **The seeded pair, at the model.** The two capture-time boxes are the
    /// only ones the index can pre-fill, so they are the only ones the
    /// blank-means-unchanged rule cannot reach; a Return that moved neither of
    /// them must still reach no writer. Without this, tabbing through an
    /// untouched inspector rewrites every selected file to the value it already
    /// has — a fork, a stash, a rehash and a bumped mtime each, and no sheet,
    /// because a clean success shows nothing.
    @Test func anUntouchedCaptureTimePairCommitsNothing() async throws {
        let (model, writer, _) = try await window(files: 3)
        let seed = CaptureTimeSeed(wallClock: "2021-07-08 09:10:11", offset: "-04:00")

        let refusal = await model.commitMetadataField(
            .captureTime(wallClock: "2021-07-08 09:10:11", offset: "-04:00", seed: seed))

        #expect(refusal == .nothingToWrite)
        #expect(writer.calls.isEmpty,
                "an untouched capture-time pair rewrote \(writer.calls.first?.urls.count ?? 0) files")
        #expect(model.activeSheet == nil)
    }

    /// Erasing goes through a confirmation and then writes the empty string
    /// that removes the tag — the only route to that write.
    @Test func clearingAFieldAsksFirstAndThenErasesAcrossTheSelection() async throws {
        let (model, writer, _) = try await window(files: 3)

        model.confirmClearMetadataField(.artist)
        guard case .confirmMetadataClear(let field, let count)? = model.activeSheet else {
            Issue.record("erasing must ask first, got \(model.activeSheet.map(\.id) ?? "no sheet")")
            return
        }
        #expect(field == .artist)
        #expect(count == 3)
        #expect(writer.calls.isEmpty, "the confirmation wrote before it was answered")

        let refusal = await model.clearMetadataField(.artist)
        #expect(refusal == nil)
        #expect(writer.calls.count == 1)
        #expect(writer.calls[0].urls.count == 3)
        #expect(writer.calls[0].edit.artist == "",
                "an erase is the empty string MetadataWriter turns into a tag removal")
    }

    /// "3 files written" over a tag that was deleted is a true sentence
    /// describing the wrong event.
    @Test func anEraseSummaryReportsClearedRatherThanWritten() async throws {
        let (model, writer, _) = try await window(files: 2)
        writer.warn(.indexRowNotUpdated)   // raises the sheet so it can be read
        await model.clearMetadataField(.label)
        guard case .metadataSummary(let summary)? = model.activeSheet else {
            Issue.record("expected the metadata summary sheet")
            return
        }
        #expect(summary.wasClear)
        #expect(summary.headline == "2 files cleared.")
    }

    /// **Stop shows no sheet**, the same as a clean cancel of a move. The
    /// writer reports every un-reached file as `.failure(.cancelled)`, which is
    /// the right shape for a result list and the wrong one for a sheet: folded
    /// into the failures it says "4 files could not be written" to a user who
    /// pressed Stop and watched the bar the whole time.
    ///
    /// Driven by a rendezvous rather than a timer — see `WriteGate` for the
    /// flake that idiom replaced. Nothing here reads `batchProgress`, which is
    /// main-actor state that another suite can keep this test from seeing until
    /// after the batch it describes has finished; `writer.written` only grows,
    /// so it says the same thing whenever it is read.
    @Test func stoppingABatchShowsNoSheetAndKeepsWhatWasAlreadyWritten() async throws {
        let (model, writer, _) = try await window(files: 5)
        let gate = WriteGate(pauseAfter: 1)
        writer.park(at: gate)

        let batch = Task { await model.commitMetadataField(.artist("Ansel")) }
        // Returns exactly when the first file is done and the writer is parked
        // on it. No deadline: neither side can outrun the other.
        await gate.waitForReach(1)
        #expect(writer.written.count == 1,
                "the gate let the batch past file 1 before the test could stop it")

        model.cancelBatch()
        await gate.release()
        _ = await batch.value

        #expect(model.activeSheet == nil,
                "Stop raised \(model.activeSheet.map(\.id) ?? "-"); a clean cancel reports nothing")
        #expect(model.batchProgress == nil)
        // Everything already done stays done, and nothing after the stop ran.
        #expect(writer.written.count == 1,
                "the stop let \(writer.written.count) of 5 files through")
    }

    /// **Sort order, not id order.** With the grid sorted by name ascending the
    /// two coincide, so the sequence test above cannot tell them apart. Sorted
    /// descending they disagree, and the sequence must follow what is on
    /// screen: that is the whole point of the operation.
    @Test func aSequenceFollowsTheGridsSortOrderRatherThanTheRowIds() async throws {
        let (model, writer, _) = try await window(
            files: 5, sort: SearchQuery.Sort(field: .name, ascending: false))
        try #require(model.selectedRecords.map(\.name)
            == ["IMG_0005.jpg", "IMG_0004.jpg", "IMG_0003.jpg",
                "IMG_0002.jpg", "IMG_0001.jpg"],
                     "the grid did not re-sort, so this proves nothing")

        let refusal = await model.applyBatchTimeOperation(
            .sequence(startWallClock: "2021-07-08 09:10:11", offset: "-04:00",
                      intervalSeconds: 10))
        #expect(refusal == nil)

        let zone = try #require(TimeZoneOffset.parse("-04:00"))
        let start = try #require(WallClock.parse("2021-07-08 09:10:11", in: zone))
        #expect(writer.calls.count == 5)
        for (index, call) in writer.calls.enumerated() {
            #expect(call.urls.map(\.lastPathComponent) == ["IMG_000\(5 - index).jpg"],
                    "step \(index) went to \(call.urls.map(\.lastPathComponent)), which is row-id order rather than sort order")
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
                     "exiftool was located but the window did not resolve it")
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

    /// The batch time sheet goes through the same builder, so its boxes report
    /// too. Only the `.set` mode's two are on screen at once — the picker
    /// cannot be driven from here — which is enough to prove the sheet is not
    /// carrying a second, unwalked copy of the field.
    @Test func theBatchTimeSheetsFieldsReportTheirFocus() async throws {
        let tree = try TempDirectory()
        let root = try tree.directory("library")
        try tree.file("library/IMG_0001.jpg", bytes: 64)
        let model = BrowserModel(store: try IndexStore.inMemory(),
                                 preferences: MemoryPreferences())
        model.metadataWriter = RecordingMetadataWriter()
        await model.open(root)
        model.selectAll()
        await model.resolveMetadataAvailability()

        let (window, fields) = renderFields(BatchTimeSheet(model: model), count: 2)
        defer { window.close() }
        try #require(fields.count >= 2,
                     "the batch time sheet rendered \(fields.count) fields, expected 2")

        var seen: Set<BrowserModel.TextField> = []
        for field in fields.prefix(2) {
            focus(field, in: model)
            seen.formUnion(model.editingFields)
        }
        #expect(seen == [.batchTimeSet, .batchTimeSetZone],
                "the batch time sheet's fields reported \(seen)")
    }

    /// **Spec §11, at the pixels rather than at the flag.** With exiftool
    /// unavailable the editing controls are *replaced by* the explanation: no
    /// editable box is rendered at all, and the sentence and the command that
    /// fixes it are.
    ///
    /// Driven as a transition rather than a bare negative: the same view is
    /// rendered with the writer available first, so "no fields" cannot pass by
    /// the host never having laid anything out.
    @Test func withExiftoolUnavailableTheInspectorRendersNoEditableField() async throws {
        let tree = try TempDirectory()
        let root = try tree.directory("library")
        try tree.file("library/IMG_0001.jpg", bytes: 64)
        let model = BrowserModel(store: try IndexStore.inMemory(),
                                 preferences: MemoryPreferences())
        model.metadataWriter = RecordingMetadataWriter()
        await model.open(root)
        model.selectAll()
        await model.resolveMetadataAvailability()

        let (window, fields) = renderFields(InspectorView(model: model), count: 10)
        defer { window.close() }
        try #require(fields.count >= 10,
                     "the inspector never rendered its fields, so their absence proves nothing")

        model.metadataAvailability = .notFound
        waitForEditableFieldsToDisappear(in: window)
        #expect(editableFields(in: window).isEmpty,
                "\(editableFields(in: window).count) editable fields survived exiftool going away")

        let text = staticText(in: window)
        #expect(text.contains { $0.contains("exiftool") },
                "the explanation is not on screen; the panel shows \(text)")
        #expect(text.contains(MetadataInspectorCopy.installCommand),
                "the install command is not on screen; the panel shows \(text)")
    }
}

/// Pumps the run loop until the panel has taken its editable fields down.
///
/// A synchronous helper because `RunLoop.current` is unavailable from an async
/// context, and bounded by a deadline for the reason everything else here is:
/// a fixed pump fails as "no fields", which reads like the assertion passing.
@MainActor
private func waitForEditableFieldsToDisappear(in window: NSWindow) {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, !editableFields(in: window).isEmpty {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

/// Every editable `NSTextField` currently in `window`.
@MainActor
private func editableFields(in window: NSWindow) -> [NSTextField] {
    allTextFields(in: window).filter(\.isEditable)
}

/// The selectable-but-not-editable ones, which is what `Text(...).textSelection(.enabled)`
/// becomes on macOS — the only route a test has to the panel's own copy.
@MainActor
private func staticText(in window: NSWindow) -> [String] {
    allTextFields(in: window).filter { !$0.isEditable }.map(\.stringValue)
}

@MainActor
private func allTextFields(in window: NSWindow) -> [NSTextField] {
    var found: [NSTextField] = []
    func walk(_ view: NSView) {
        if let field = view as? NSTextField { found.append(field) }
        view.subviews.forEach(walk)
    }
    if let content = window.contentView { walk(content) }
    return found
}

// MARK: - The stored exiftool path (#51)

/// Rung 1.5 from the window's side: remembering the path, putting it into
/// force, and taking it back out.
///
/// The resolution order itself is Core's and is asserted there
/// (`ExiftoolLocatorTests`). What can only be asserted here is the wiring —
/// that a chosen path is written to the preference, read back on the next
/// launch, and handed to the writer rather than remembered and ignored.
@MainActor
struct StoredExiftoolPathTests {
    private func model(_ preferences: MemoryPreferences) throws -> BrowserModel {
        BrowserModel(store: try IndexStore.inMemory(), preferences: preferences)
    }

    /// The acceptance line: a chosen path survives relaunch. Two models over
    /// one preference store is the same shape
    /// `theCompanionToggleIsRememberedAndReachesThePlan` uses, and it is where
    /// "remembered" is actually observable — a model that only kept the value
    /// in memory would pass every single-model assertion.
    @Test func aChosenPathIsRememberedAcrossModels() throws {
        let preferences = MemoryPreferences()
        let first = try model(preferences)
        first.storedExiftoolPath = "/opt/elsewhere/bin/exiftool"

        let second = try model(preferences)
        #expect(second.storedExiftoolPath == "/opt/elsewhere/bin/exiftool")
    }

    /// *Use default.* Clearing has to erase the preference, not write an empty
    /// string that a later reader treats as a path — Core normalises "" to nil
    /// as a backstop, and this is the other end of that.
    @Test func clearingThePathRemovesThePreference() throws {
        let preferences = MemoryPreferences()
        let first = try model(preferences)
        first.storedExiftoolPath = "/opt/elsewhere/bin/exiftool"
        first.storedExiftoolPath = nil

        #expect(try model(preferences).storedExiftoolPath == nil)
        #expect(preferences.path(forKey: BrowserModel.storedExiftoolPathKey) == nil)
    }

    /// A stored path is only worth anything if it reaches the thing that runs
    /// exiftool. Without this the preference is remembered, shown in the
    /// footnote, and never used — which is the bug this test exists to catch,
    /// because every other test here passes with the writer never told.
    @Test func settingThePathTellsTheWriterAndReResolves() async throws {
        let preferences = MemoryPreferences()
        let model = try model(preferences)
        let writer = RecordingMetadataWriter(availability: .notFound)
        model.metadataWriter = writer

        await model.chooseStoredExiftoolPath("/opt/elsewhere/bin/exiftool")

        #expect(writer.storedPaths == ["/opt/elsewhere/bin/exiftool"])
        #expect(model.storedExiftoolPath == "/opt/elsewhere/bin/exiftool")
    }

    /// Decision 4: a file that is not a usable exiftool is **refused, not
    /// stored**. Storing it leaves a broken state that costs a second trip
    /// through the picker to escape.
    @Test func aRefusedChoiceIsNotStored() async throws {
        let preferences = MemoryPreferences()
        let model = try model(preferences)
        let writer = RecordingMetadataWriter(availability: .notFound)
        model.metadataWriter = writer
        writer.refuseValidation(reason: "it is not an executable file")

        let refusal = await model.chooseStoredExiftoolPath("/bin/echo")

        #expect(refusal != nil)
        #expect(model.storedExiftoolPath == nil)
        #expect(preferences.path(forKey: BrowserModel.storedExiftoolPathKey) == nil)
        #expect(writer.storedPaths.isEmpty, "a refused path must never be put into force")
    }

    /// The footnote's job: when a stored path is in force and working, the
    /// Edit section still has to say which binary it is using. Nothing else in
    /// the window reveals it, and a preference the user cannot see is one they
    /// cannot undo.
    @Test func theFootnoteNamesThePathOnlyWhenOneIsInForce() throws {
        let preferences = MemoryPreferences()
        let model = try model(preferences)
        model.metadataAvailability = .available(path: "/opt/homebrew/bin/exiftool",
                                                version: "13.55")

        #expect(model.storedExiftoolPathInForce == nil,
                "the footnote must not appear for a path found by the ordinary rungs")

        model.storedExiftoolPath = "/opt/elsewhere/bin/exiftool"
        model.metadataAvailability = .available(path: "/opt/elsewhere/bin/exiftool",
                                                version: "13.55")
        #expect(model.storedExiftoolPathInForce == "/opt/elsewhere/bin/exiftool")
    }

    /// A stored path that has rotted must still offer the way out. The
    /// explanation is Core's and names the path; what this asserts is that the
    /// window puts the *Use default* affordance up for it — the failure mode
    /// being a user stuck with a refusal naming a file they cannot unpick.
    @Test func aBrokenStoredPathStillOffersTheDefault() throws {
        let preferences = MemoryPreferences()
        let model = try model(preferences)
        model.storedExiftoolPath = "/Volumes/Gone/bin/exiftool"
        model.metadataAvailability = .storedPathUnusable(
            path: "/Volumes/Gone/bin/exiftool", reason: "it is not there")

        #expect(model.canClearStoredExiftoolPath)
        let sentence = try #require(model.metadataUnavailableExplanation)
        #expect(sentence.contains("/Volumes/Gone/bin/exiftool"))
    }

    /// **The relaunch half of the acceptance line, and the one that is easy to
    /// ship broken.** Reading the preference at init only fills a property;
    /// unless the path is also put *into force*, the next launch shows the
    /// remembered path in the footnote and resolves through #41's four rungs
    /// anyway — which on the machine this feature exists for means editing is
    /// still dead. Every other test in this suite passes with that bug present.
    @Test func aRememberedPathIsPutIntoForceOnTheFirstResolve() async throws {
        let preferences = MemoryPreferences()
        preferences.setPath("/opt/elsewhere/bin/exiftool",
                            forKey: BrowserModel.storedExiftoolPathKey)

        let model = try model(preferences)
        let writer = RecordingMetadataWriter(availability: .notFound)
        model.metadataWriter = writer

        await model.resolveMetadataAvailability()

        #expect(writer.storedPaths == ["/opt/elsewhere/bin/exiftool"],
                "the remembered path was read but never put into force")
        #expect(model.metadataAvailability?.executablePath == "/opt/elsewhere/bin/exiftool")
    }

    /// And with nothing remembered, the first resolve must stay on the plain
    /// lookup — no stored-path call at all, or #41's order is perturbed for
    /// every user who never touched this feature.
    @Test func noRememberedPathLeavesTheOrdinaryResolveAlone() async throws {
        let model = try model(MemoryPreferences())
        let writer = RecordingMetadataWriter()
        model.metadataWriter = writer

        await model.resolveMetadataAvailability()

        #expect(writer.storedPaths.isEmpty)
    }

    /// *Use default* has to reach the writer too, or the window returns to the
    /// four rungs while the process keeps running the old binary.
    @Test func clearingTellsTheWriterAsWell() async throws {
        let preferences = MemoryPreferences()
        let model = try model(preferences)
        let writer = RecordingMetadataWriter()
        model.metadataWriter = writer
        model.storedExiftoolPath = "/opt/elsewhere/bin/exiftool"

        await model.clearStoredExiftoolPath()

        #expect(model.storedExiftoolPath == nil)
        #expect(writer.storedPaths == [nil])
    }
}
