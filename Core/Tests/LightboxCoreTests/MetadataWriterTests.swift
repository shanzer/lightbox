import Testing
import Foundation
import ImageIO
@testable import LightboxCore

// MARK: - Skip guard

/// Every round-trip test below runs the *real* exiftool. A stub would prove
/// nothing about the tag mapping, which is the whole substance of this feature.
///
/// The guard consults `MetadataWriter.availability` — the same lookup the
/// writer performs, as CONTRIBUTING requires. A guard that checked, say, the
/// existence of `/opt/homebrew/bin/exiftool` while the writer searched `PATH`
/// would produce a green run on CI that proves nothing at all.
private let needsExiftool = ConditionTrait.enabled(
    if: MetadataWriter.availability.isAvailable,
    "exiftool is not on PATH — MetadataWriter round-trip tests skipped")

// MARK: - Locating exiftool (no binary needed)

struct ExiftoolLocatorTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// Creates a directory holding an executable file called `exiftool`.
    private func fakeBinDirectory(named name: String = "bin") throws -> URL {
        let directory = try tree.directory(name)
        let binary = directory.appendingPathComponent("exiftool")
        try "#!/bin/sh\necho 13.55\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: binary.path)
        return directory
    }

    @Test func findsExiftoolOnPATH() throws {
        let directory = try fakeBinDirectory()
        let found = ExiftoolLocator.locate(environment: ["PATH": "/nowhere:\(directory.path)"])
        #expect(found == directory.appendingPathComponent("exiftool").path)
    }

    /// The bug this guards against is a hardcoded `/opt/homebrew/bin` or
    /// `/usr/local/bin`, which HANDOFF §3 calls out by name: the project moved
    /// between an Intel iMac and an M4 mini, and those are the two prefixes.
    /// A locator that quietly falls back to either one would pass every other
    /// test on this machine and fail on the other.
    @Test func doesNotFallBackToAHardcodedHomebrewPrefix() {
        #expect(ExiftoolLocator.locate(environment: ["PATH": "/nonexistent-bin"]) == nil)
        #expect(ExiftoolLocator.locate(environment: [:]) == nil)
    }

    @Test func skipsDirectoriesAndNonExecutables() throws {
        let directory = try tree.directory("notbin")
        try tree.directory("notbin/exiftool")            // a *directory* named exiftool
        #expect(ExiftoolLocator.locate(environment: ["PATH": directory.path]) == nil)

        let plain = try tree.directory("plain")
        try "not executable".write(to: plain.appendingPathComponent("exiftool"),
                                   atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: plain.appendingPathComponent("exiftool").path)
        #expect(ExiftoolLocator.locate(environment: ["PATH": plain.path]) == nil)
    }

    @Test func environmentOverrideWinsOverPATH() throws {
        let onPath = try fakeBinDirectory(named: "onpath")
        let elsewhere = try fakeBinDirectory(named: "elsewhere")
        let override = elsewhere.appendingPathComponent("exiftool").path
        let found = ExiftoolLocator.locate(environment: [
            "PATH": onPath.path,
            ExiftoolLocator.overrideEnvironmentKey: override,
        ])
        #expect(found == override)
    }

    /// exiftool's versions are `13.9`, `13.10`, `13.55`. A lexical compare puts
    /// `13.9` *after* `13.55`, so a minimum-version check written with `>=` on
    /// strings would reject a newer exiftool than the one it demands.
    @Test func versionsCompareNumericallyNotLexically() {
        #expect(ExiftoolLocator.compare("13.9", "13.55") < 0)
        #expect(ExiftoolLocator.compare("13.55", "13.9") > 0)
        #expect(ExiftoolLocator.compare("13.55", "13.55") == 0)
        #expect(ExiftoolLocator.compare("14.0", "13.99") > 0)
        #expect(ExiftoolLocator.isAtLeastMinimum("13.55"))
        #expect(ExiftoolLocator.isAtLeastMinimum("13.0"))
        #expect(!ExiftoolLocator.isAtLeastMinimum("12.99"))
    }

    /// Spec §11: exiftool absent disables editing *with an explanation*, and
    /// leaves everything else alone.
    @Test func absentExiftoolExplainsItselfAndFailsEveryItem() async throws {
        #expect(ExiftoolAvailability.notFound.explanation?.contains("exiftool") == true)
        #expect(ExiftoolAvailability.notFound.isAvailable == false)
        #expect(ExiftoolAvailability.tooOld(path: "/x", version: "12.0", minimum: "13.0")
            .isAvailable == false)

        let writer = MetadataWriter(availability: .notFound)
        let url = try tree.file("a.jpg")
        let outcomes = await writer.write(MetadataEdit(description: "x"), to: [url])
        #expect(outcomes.count == 1)
        guard case .exiftoolUnavailable(let reason) = outcomes[0].error else {
            Issue.record("expected .exiftoolUnavailable, got \(String(describing: outcomes[0].error))")
            return
        }
        #expect(reason.contains("exiftool"))
    }
}

// MARK: - What the API refuses (no binary needed)

struct MetadataWriteValidationTests {
    /// Spec §9, constraint 1. Refused *at the API*, not merely discouraged in
    /// the inspector: a `DateTimeOriginal` with no `OffsetTimeOriginal` names a
    /// different instant on every machine that reads it.
    @Test func refusesACaptureTimeWithNoTimeZone() {
        let edit = MetadataEdit(captureTime: CaptureTime(date: Date(), offset: nil))
        #expect(MetadataWriter.validate(edit) == .captureTimeRequiresTimeZone)

        let blank = MetadataEdit(captureTime: CaptureTime(date: Date(), offset: "  "))
        #expect(MetadataWriter.validate(blank) == .captureTimeRequiresTimeZone)
    }

    /// An offset the *reader* cannot parse would round-trip to a different
    /// instant, so the writer refuses exactly what `MetadataReader` refuses.
    @Test(arguments: ["-5:00", "EST", "+05", "-05:00:00", "05:00"])
    func refusesAnOffsetTheReaderCannotParse(_ offset: String) {
        let edit = MetadataEdit(captureTime: CaptureTime(date: Date(), offset: offset))
        #expect(MetadataWriter.validate(edit) == .invalidTimeZoneOffset(offset))
    }

    @Test func acceptsAWellFormedOffset() {
        let edit = MetadataEdit(captureTime: CaptureTime(date: Date(), offset: "-05:00"))
        #expect(MetadataWriter.validate(edit) == nil)
    }

    @Test func refusesNonNumericSubSeconds() {
        let capture = CaptureTime(date: Date(), offset: "+00:00", subSeconds: "12x")
        #expect(MetadataWriter.validate(MetadataEdit(captureTime: capture))
            == .invalidSubSeconds("12x"))
    }

    @Test(arguments: [-1, 6, 99]) func refusesARatingOutsideZeroToFive(_ rating: Int) {
        #expect(MetadataWriter.validate(MetadataEdit(rating: rating)) == .invalidRating(rating))
    }

    @Test func refusesAnImpossibleCoordinate() {
        let edit = MetadataEdit(gps: GPSCoordinate(latitude: 91, longitude: 0))
        #expect(MetadataWriter.validate(edit) == .invalidCoordinate(latitude: 91, longitude: 0))
    }

    @Test func refusesAnEmptyEdit() {
        #expect(MetadataWriter.validate(MetadataEdit()) == .nothingToWrite)
    }
}

// MARK: - Hostile-argument routing (no binary needed)

/// Spec §9, constraint 4. The `-stay_open` argument protocol is newline
/// delimited *and* strips surrounding whitespace from each line, so these
/// inputs are argument injection rather than mere breakage.
struct ExiftoolRoutingTests {
    @Test func ordinaryArgumentsTakeTheStayOpenPath() {
        #expect(!ExiftoolRunner.requiresOneShot(
            arguments: ["-MWG:Description=a normal caption"],
            files: ["/tmp/photos/IMG_0001.jpg"]))
    }

    @Test(arguments: ["a\nb", "a\rb", "a\r\nb", "a\u{0}b"])
    func aValueCarryingALineBreakIsRoutedToTheOneShot(_ value: String) {
        #expect(ExiftoolRunner.requiresOneShot(
            arguments: ["-MWG:Description=\(value)"], files: ["/tmp/a.jpg"]))
    }

    @Test func aFilenameCarryingALineBreakIsRoutedToTheOneShot() {
        #expect(ExiftoolRunner.requiresOneShot(arguments: [], files: ["/tmp/we\nird.jpg"]))
    }

    /// The `-` case: a name beginning with a dash is read as an option
    /// wherever it appears, which is why the one-shot separates with `--`.
    @Test func aFilenameBeginningWithADashIsRoutedToTheOneShot() {
        #expect(ExiftoolRunner.requiresOneShot(arguments: [], files: ["/tmp/x/-foo.jpg"]))
        #expect(ExiftoolRunner.requiresOneShot(arguments: [], files: ["-foo.jpg"]))
    }

    /// The quiet one: `-@` strips leading and trailing whitespace from each
    /// line, so " /tmp/a.jpg" addresses a different file than the caller meant.
    @Test(arguments: [" /tmp/a.jpg", "/tmp/a.jpg ", "\t/tmp/a.jpg"])
    func aFilenameWithEdgeWhitespaceIsRoutedToTheOneShot(_ file: String) {
        #expect(ExiftoolRunner.requiresOneShot(arguments: [], files: [file]))
    }
}

// MARK: - The tag plan (no binary needed)

struct MetadataWriterPlanTests {
    @Test func keywordsAreClearedBeforeTheyAreSetSoAssignmentReplaces() {
        let plan = MetadataWriter.plan(MetadataEdit(keywords: ["alpha", "beta"]),
                                       target: .inPlace, options: WriteOptions())
        let keywordArguments = plan.writeArguments.filter { $0.hasPrefix("-MWG:Keywords") }
        #expect(keywordArguments == ["-MWG:Keywords=", "-MWG:Keywords=alpha", "-MWG:Keywords=beta"])
    }

    @Test func everyLogicalFieldIsWrittenAcrossFamiliesNotJustOne() {
        let edit = MetadataEdit(artist: "Jane", copyright: "(c)", description: "d",
                                keywords: ["k"], gps: GPSCoordinate(latitude: 1, longitude: 2),
                                rating: 3, label: "Red")
        let plan = MetadataWriter.plan(edit, target: .inPlace, options: WriteOptions())
        let arguments = plan.writeArguments
        #expect(arguments.contains("-MWG:Description=d"))
        #expect(arguments.contains("-MWG:Creator=Jane"))
        #expect(arguments.contains("-MWG:Copyright=(c)"))
        #expect(arguments.contains("-MWG:Rating=3"))
        #expect(arguments.contains("-XMP-xmp:Label=Red"))
        // Both GPS families, or the two disagree about the hemisphere.
        #expect(arguments.contains("-EXIF:GPSLatitudeRef=N"))
        #expect(arguments.contains("-EXIF:GPSLongitudeRef=E"))
        #expect(arguments.contains { $0.hasPrefix("-XMP-exif:GPSLatitude=") })
        // Keeps every later MWG reader from declaring the IPTC block stale.
        #expect(arguments.contains("-IPTCDigest=new"))
    }

    @Test func southernAndWesternHemispheresGetTheRightReferences() {
        let edit = MetadataEdit(gps: GPSCoordinate(latitude: -33.8688, longitude: -70.6693))
        let arguments = MetadataWriter.plan(edit, target: .inPlace,
                                            options: WriteOptions()).writeArguments
        #expect(arguments.contains("-EXIF:GPSLatitudeRef=S"))
        #expect(arguments.contains("-EXIF:GPSLongitudeRef=W"))
        // EXIF carries an unsigned magnitude; XMP carries the sign.
        #expect(arguments.contains("-EXIF:GPSLatitude=33.8688"))
        #expect(arguments.contains("-XMP-exif:GPSLatitude=-33.8688"))
    }

    /// A sidecar is an XMP file: EXIF-group directives have nowhere to land, so
    /// planning them would ask exiftool for something it cannot do and then
    /// verify a tag that can never be there.
    @Test func aSidecarPlanCarriesNoEXIFDirectives() {
        let capture = CaptureTime(date: Date(), offset: "+00:00", subSeconds: "250")
        let edit = MetadataEdit(captureTime: capture,
                                gps: GPSCoordinate(latitude: 1, longitude: 2))
        let sidecar = URL(fileURLWithPath: "/tmp/a.xmp")
        let plan = MetadataWriter.plan(edit, target: .sidecar(sidecar), options: WriteOptions())
        #expect(!plan.writeArguments.contains { $0.hasPrefix("-EXIF:") })
        #expect(!plan.expectations.contains { $0.key.hasPrefix("GPS:") })
        #expect(plan.expectations.contains { $0.key == "XMP-exif:GPSLatitude" })
    }

    @Test func preserveModificationTimeAddsDashP() {
        let plain = MetadataWriter.plan(MetadataEdit(rating: 1), target: .inPlace,
                                        options: WriteOptions())
        #expect(!plain.writeArguments.contains("-P"))
        let preserving = MetadataWriter.plan(
            MetadataEdit(rating: 1), target: .inPlace,
            options: WriteOptions(preserveModificationTime: true))
        #expect(preserving.writeArguments.contains("-P"))
    }

    /// A cleared field must verify as *absent*, not as the empty string —
    /// exiftool removes the tag rather than storing "".
    @Test func clearingAFieldExpectsTheTagToBeGone() {
        let plan = MetadataWriter.plan(MetadataEdit(description: ""), target: .inPlace,
                                       options: WriteOptions())
        #expect(plan.expectations.contains(
            MetadataWriter.Expectation(argument: "-MWG:Description",
                                       key: "MWG:Description", expected: .absent)))
    }

    @Test func aOneElementKeywordListReadsBackAsABareString() {
        // exiftool renders a single-valued list tag as a scalar, so the
        // comparison has to accept both shapes or every one-keyword write is
        // reported as a verification failure and rolled back.
        #expect(MetadataWriter.matches(.list(["alpha"]), "alpha"))
        #expect(MetadataWriter.matches(.list(["alpha", "beta"]), ["alpha", "beta"]))
        #expect(!MetadataWriter.matches(.list(["alpha"]), "beta"))
        #expect(!MetadataWriter.matches(.list(["alpha"]), nil))
        #expect(MetadataWriter.matches(.absent, nil))
        #expect(!MetadataWriter.matches(.absent, "x"))
    }

    @Test func sidecarPathReplacesTheExtension() {
        #expect(MetadataWriter.sidecarURL(for: URL(fileURLWithPath: "/p/IMG_0001.CR2")).path
            == "/p/IMG_0001.xmp")
        #expect(MetadataWriter.sidecarURL(for: URL(fileURLWithPath: "/p/-foo.dng")).path
            == "/p/-foo.xmp")
    }
}

// MARK: - Backup and restore (no binary needed)

struct MetadataWriteRestoreTests {
    let tree: TempTree
    init() throws { tree = try TempTree() }

    @Test func restoringPutsTheOriginalBytesBackAndRemovesTheBackup() throws {
        let file = tree.root.appendingPathComponent("a.jpg")
        let backup = tree.root.appendingPathComponent("a.jpg_original")
        try Data("half-written".utf8).write(to: file)
        try Data("the original".utf8).write(to: backup)

        try MetadataWriter.restore(backup: backup, to: file, created: false, tags: ["X"])

        #expect(try Data(contentsOf: file) == Data("the original".utf8))
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    /// A sidecar exiftool had to *create* has no `_original` to restore from,
    /// so undoing the write means deleting the file it made. Without this the
    /// failure leaves a half-written sidecar next to the RAW forever.
    @Test func restoringACreatedSidecarDeletesIt() throws {
        let sidecar = tree.root.appendingPathComponent("a.xmp")
        try Data("<x:xmpmeta/>".utf8).write(to: sidecar)

        try MetadataWriter.restore(backup: nil, to: sidecar, created: true, tags: ["X"])

        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test func restoringAPreexistingFileWithNoBackupLeavesItAlone() throws {
        let file = tree.root.appendingPathComponent("a.jpg")
        try Data("untouched".utf8).write(to: file)
        try MetadataWriter.restore(backup: nil, to: file, created: false, tags: ["X"])
        #expect(try Data(contentsOf: file) == Data("untouched".utf8))
    }
}

// MARK: - Round trips against the real exiftool

@Suite(.serialized)
struct MetadataWriterRoundTripTests {
    let tree: TempTree
    init() throws { tree = try TempTree() }

    private func exiftoolRead(_ url: URL, _ tags: [String]) throws -> [String: Any] {
        guard let path = MetadataWriter.availability.executablePath else {
            throw FixtureError.missing("exiftool")
        }
        let runner = ExiftoolRunner(executable: path)
        defer { runner.shutdown() }
        let run = try runner.run(arguments: ["-j", "-G1", "-n", "-s", "-a"] + tags,
                                 files: [url.path])
        return try MetadataWriter.parseJSON(run.stdout)
    }

    private var everyField: MetadataEdit {
        var components = DateComponents()
        components.year = 2021; components.month = 7; components.day = 8
        components.hour = 9; components.minute = 10; components.second = 11
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -4 * 3600)!
        let capture = CaptureTime(date: calendar.date(from: components)!,
                                  offset: "-04:00", subSeconds: "250")
        return MetadataEdit(captureTime: capture,
                            artist: "Jane Doe",
                            copyright: "(c) 2021 Jane Doe",
                            description: "A caption with an accent: café",
                            keywords: ["alpha", "beta"],
                            gps: GPSCoordinate(latitude: 41.878100, longitude: -87.629800),
                            rating: 4,
                            label: "Red")
    }

    /// The acceptance criterion, in one test: every field written, then read
    /// back by exiftool *and* by ImageIO, with the three tag families each
    /// carrying the value. Writing only XMP is the failure mode this exists to
    /// catch, and it is invisible to a test that reads back through the same
    /// composite tag it wrote.
    @Test(needsExiftool) func everyFieldRoundTripsThroughAllThreeFamilies() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
        let writer = MetadataWriter()
        let outcomes = await writer.write(everyField, to: [url])
        try #require(outcomes[0].error == nil,
                     "write failed: \(String(describing: outcomes[0].error))")

        // --- exiftool, per family ---
        let tags = ["-IFD0:ImageDescription", "-IPTC:Caption-Abstract", "-XMP-dc:Description",
                    "-IFD0:Artist", "-IPTC:By-line", "-XMP-dc:Creator",
                    "-IFD0:Copyright", "-IPTC:CopyrightNotice", "-XMP-dc:Rights",
                    "-IPTC:Keywords", "-XMP-dc:Subject",
                    "-ExifIFD:DateTimeOriginal", "-ExifIFD:OffsetTimeOriginal",
                    "-IPTC:DateCreated", "-XMP-photoshop:DateCreated",
                    "-XMP-xmp:Rating", "-XMP-xmp:Label",
                    "-GPS:GPSLatitude", "-GPS:GPSLatitudeRef",
                    "-GPS:GPSLongitude", "-GPS:GPSLongitudeRef",
                    "-XMP-exif:GPSLatitude", "-XMP-exif:GPSLongitude"]
        let read = try exiftoolRead(url, tags)

        for key in ["IFD0:ImageDescription", "IPTC:Caption-Abstract", "XMP-dc:Description"] {
            #expect(read[key] as? String == "A caption with an accent: café",
                    "\(key) disagrees: \(String(describing: read[key]))")
        }
        for key in ["IFD0:Artist", "IPTC:By-line", "XMP-dc:Creator"] {
            #expect(read[key] as? String == "Jane Doe", "\(key) disagrees")
        }
        for key in ["IFD0:Copyright", "IPTC:CopyrightNotice", "XMP-dc:Rights"] {
            #expect(read[key] as? String == "(c) 2021 Jane Doe", "\(key) disagrees")
        }
        for key in ["IPTC:Keywords", "XMP-dc:Subject"] {
            #expect(read[key] as? [String] == ["alpha", "beta"], "\(key) disagrees")
        }
        #expect(read["ExifIFD:DateTimeOriginal"] as? String == "2021:07:08 09:10:11")
        #expect(read["ExifIFD:OffsetTimeOriginal"] as? String == "-04:00")
        #expect(read["IPTC:DateCreated"] as? String == "2021:07:08")
        #expect((read["XMP-photoshop:DateCreated"] as? String)?.hasPrefix("2021:07:08 09:10:11")
            == true)
        #expect((read["XMP-xmp:Rating"] as? NSNumber)?.intValue == 4)
        #expect(read["XMP-xmp:Label"] as? String == "Red")
        #expect(read["GPS:GPSLatitudeRef"] as? String == "N")
        #expect(read["GPS:GPSLongitudeRef"] as? String == "W")
        // EXIF stores the magnitude; XMP stores the sign. Both must agree on
        // the actual place.
        #expect(abs(((read["GPS:GPSLongitude"] as? NSNumber)?.doubleValue ?? 0) - 87.6298) < 1e-6)
        #expect(abs(((read["XMP-exif:GPSLongitude"] as? NSNumber)?.doubleValue ?? 0) + 87.6298)
            < 1e-6)

        // --- ImageIO, the app's own reader ---
        let tiff = ImageIOProbe.tiff(url)
        #expect(tiff[kCGImagePropertyTIFFImageDescription] as? String
            == "A caption with an accent: café")
        #expect(tiff[kCGImagePropertyTIFFArtist] as? String == "Jane Doe")
        #expect(tiff[kCGImagePropertyTIFFCopyright] as? String == "(c) 2021 Jane Doe")

        let iptc = ImageIOProbe.iptc(url)
        #expect(iptc[kCGImagePropertyIPTCKeywords] as? [String] == ["alpha", "beta"])
        #expect(iptc[kCGImagePropertyIPTCCaptionAbstract] as? String
            == "A caption with an accent: café")

        let gps = ImageIOProbe.gps(url)
        #expect(gps[kCGImagePropertyGPSLatitudeRef] as? String == "N")
        #expect(gps[kCGImagePropertyGPSLongitudeRef] as? String == "W")

        // And the capture instant, through the reader the indexer uses.
        let metadata = try MetadataReader().read(url)
        #expect(metadata.captureOffset == "-04:00")
        #expect(metadata.captureTime == everyField.captureTime?.date)
    }

    /// Spec §9 lists JPEG, HEIC, TIFF and PNG as edited in place; WebP is here
    /// too because the image-hash tripwire below has to cover it.
    @Test(needsExiftool, arguments: [Fixtures.Format.jpeg, .png, .heic, .tiff])
    func writesInPlaceForEveryNonRAWContainer(_ format: Fixtures.Format) async throws {
        let url = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("a.\(format.ext)"), format: format)
        let writer = MetadataWriter()
        let outcomes = await writer.write(everyField, to: [url])
        try #require(outcomes[0].error == nil,
                     "\(format.ext) write failed: \(String(describing: outcomes[0].error))")
        #expect(outcomes[0].success?.target == .inPlace)
        // Nothing beside the file itself: the backup is removed on commit.
        #expect(!FileManager.default.fileExists(atPath: url.path + "_original"))

        let read = try exiftoolRead(url, ["-MWG:Description", "-MWG:Keywords",
                                          "-XMP-xmp:Label", "-MWG:DateTimeOriginal"])
        #expect(read["MWG:Description"] as? String == "A caption with an accent: café")
        #expect(read["MWG:Keywords"] as? [String] == ["alpha", "beta"])
        #expect(read["XMP-xmp:Label"] as? String == "Red")
        #expect(read["MWG:DateTimeOriginal"] as? String == "2021:07:08 09:10:11.250-04:00")
    }

    @Test(needsExiftool) func writesInPlaceForWebP() async throws {
        let source = try Fixtures.url("simple.webp")
        let url = tree.root.appendingPathComponent("a.webp")
        try FileManager.default.copyItem(at: source, to: url)

        let writer = MetadataWriter()
        let outcomes = await writer.write(everyField, to: [url])
        try #require(outcomes[0].error == nil,
                     "webp write failed: \(String(describing: outcomes[0].error))")
        let read = try exiftoolRead(url, ["-MWG:Description", "-XMP-xmp:Label"])
        #expect(read["MWG:Description"] as? String == "A caption with an accent: café")
        #expect(read["XMP-xmp:Label"] as? String == "Red")
    }

    /// **The tripwire** (HANDOFF §6). `image_hash` exists precisely so that a
    /// metadata edit does not invalidate duplicate detection. Every rule in
    /// `Hashing/` was verified against an exiftool round-trip by hand during
    /// design; this is the first time the app performs one, and the first time
    /// it is checked automatically. If this fails, the format's denylist or
    /// allowlist is wrong — that is a bug to file, not to paper over by
    /// loosening the rule.
    @Test(needsExiftool, arguments: ["jpg", "png", "webp"])
    func postWriteImageHashEqualsPreWriteImageHash(_ ext: String) async throws {
        let url = tree.root.appendingPathComponent("a.\(ext)")
        switch ext {
        case "jpg": try Fixtures.writeImage(to: url, format: .jpeg)
        case "png": try Fixtures.writeImage(to: url, format: .png)
        default: try FileManager.default.copyItem(at: Fixtures.url("simple.webp"), to: url)
        }
        let mediaType = try #require(MediaType.forExtension(ext))
        let before = try FileHasher().hashes(for: url, mediaType: mediaType)
        try #require(before.imageHash != nil, "\(ext) fixture has no image hash to compare")

        let writer = MetadataWriter()
        let outcomes = await writer.write(everyField, to: [url])
        try #require(outcomes[0].error == nil,
                     "\(ext) write failed: \(String(describing: outcomes[0].error))")

        let after = try FileHasher().hashes(for: url, mediaType: mediaType)
        #expect(after.imageHash == before.imageHash,
                "image_hash moved for \(ext): the \(mediaType.imageHashKind ?? "?") rule is wrong")
        // The content hash *must* change; the bytes did.
        #expect(after.contentHash != before.contentHash)
        // And the writer reports the same thing it just proved.
        #expect(outcomes[0].success?.rehash?.imageHash == before.imageHash)
        #expect(outcomes[0].success?.rehash?.contentHash == after.contentHash)
        #expect(outcomes[0].success?.warnings.contains { warning in
            if case .imageHashChanged = warning { return true }
            return false
        } == false)
    }

    /// Spec §9, constraint 2. The RAW container is never opened for writing —
    /// that is where files get corrupted — so the edit goes to a sidecar and
    /// the container's `content_hash` is untouched.
    @Test(needsExiftool) func rawGetsASidecarAndTheContainerIsUntouched() async throws {
        // A real TIFF under a RAW extension: `MediaType` classifies `.dng` as
        // `.raw`, and the sidecar path never reads the container, so the
        // container's only job here is to have stable bytes to compare.
        let container = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("IMG_0001.dng"), format: .tiff)
        try #require(MediaType.forExtension("dng")?.kind == .raw)
        let mediaType = try #require(MediaType.forExtension("dng"))
        let before = try FileHasher().hashes(for: container, mediaType: mediaType)

        let sidecar = tree.root.appendingPathComponent("IMG_0001.xmp")
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))

        let writer = MetadataWriter()
        let outcomes = await writer.write(everyField, to: [container])
        try #require(outcomes[0].error == nil,
                     "raw write failed: \(String(describing: outcomes[0].error))")
        #expect(outcomes[0].success?.target == .sidecar(sidecar))
        #expect(outcomes[0].success?.rehash == nil)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))

        let after = try FileHasher().hashes(for: container, mediaType: mediaType)
        #expect(after.contentHash == before.contentHash,
                "the RAW container was modified by a sidecar write")

        let read = try exiftoolRead(sidecar, ["-MWG:Description", "-MWG:Keywords",
                                              "-MWG:Creator", "-XMP-xmp:Label",
                                              "-MWG:DateTimeOriginal", "-XMP-exif:GPSLatitude"])
        #expect(read["MWG:Description"] as? String == "A caption with an accent: café")
        #expect(read["MWG:Keywords"] as? [String] == ["alpha", "beta"])
        #expect(read["MWG:Creator"] as? String == "Jane Doe")
        #expect(read["XMP-xmp:Label"] as? String == "Red")
        #expect(read["MWG:DateTimeOriginal"] as? String == "2021:07:08 09:10:11.250-04:00")
    }

    @Test(needsExiftool) func aSecondSidecarWriteUpdatesTheExistingFile() async throws {
        let container = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("IMG_0002.dng"), format: .tiff)
        let writer = MetadataWriter()
        _ = await writer.write(MetadataEdit(description: "first"), to: [container])
        let outcomes = await writer.write(MetadataEdit(description: "second"), to: [container])
        try #require(outcomes[0].error == nil)

        let sidecar = tree.root.appendingPathComponent("IMG_0002.xmp")
        let read = try exiftoolRead(sidecar, ["-MWG:Description"])
        #expect(read["MWG:Description"] as? String == "second")
        #expect(!FileManager.default.fileExists(atPath: sidecar.path + "_original"))
    }

    /// An empty value clears the field out of all three families, and must
    /// verify as *absent* — exiftool removes the tag rather than storing "".
    @Test(needsExiftool) func anEmptyValueClearsTheFieldEverywhere() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("clear.jpg"))
        let writer = MetadataWriter()
        _ = await writer.write(MetadataEdit(description: "set", keywords: ["k1", "k2"]),
                               to: [url])

        let cleared = await writer.write(MetadataEdit(description: "", keywords: []), to: [url])
        try #require(cleared[0].error == nil,
                     "clearing failed: \(String(describing: cleared[0].error))")

        let read = try exiftoolRead(url, ["-MWG:Description", "-MWG:Keywords",
                                          "-IFD0:ImageDescription", "-IPTC:Caption-Abstract",
                                          "-XMP-dc:Description", "-IPTC:Keywords",
                                          "-XMP-dc:Subject"])
        for key in ["MWG:Description", "MWG:Keywords", "IFD0:ImageDescription",
                    "IPTC:Caption-Abstract", "XMP-dc:Description", "IPTC:Keywords",
                    "XMP-dc:Subject"] {
            #expect(read[key] == nil, "\(key) survived the clear: \(String(describing: read[key]))")
        }
    }

    /// Rating 0 is a *value*, not an absence — it is the bottom of the 0...5
    /// range, and a writer that treats it as "clear the tag" cannot express it.
    @Test(needsExiftool) func aRatingOfZeroIsWrittenRatherThanTreatedAsAbsent() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("zero.jpg"))
        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(rating: 0), to: [url])
        try #require(outcomes[0].error == nil,
                     "rating 0 failed: \(String(describing: outcomes[0].error))")
        let read = try exiftoolRead(url, ["-MWG:Rating", "-XMP-xmp:Rating"])
        #expect((read["MWG:Rating"] as? NSNumber)?.intValue == 0)
        #expect((read["XMP-xmp:Rating"] as? NSNumber)?.intValue == 0)
    }

    // MARK: Hostile fixtures

    /// The two hostile cases at once: a RAW whose name begins with a dash, so
    /// the sidecar has to be *created* through the one-shot path.
    @Test(needsExiftool) func aDashNamedRAWGetsItsSidecarThroughTheOneShot() async throws {
        let container = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("-raw.dng"), format: .tiff)
        let sidecar = tree.root.appendingPathComponent("-raw.xmp")
        #expect(ExiftoolRunner.requiresOneShot(arguments: [], files: [sidecar.path]))

        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(description: "dash raw"), to: [container])
        try #require(outcomes[0].error == nil,
                     "dash-named raw failed: \(String(describing: outcomes[0].error))")
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        let read = try exiftoolRead(sidecar, ["-MWG:Description"])
        #expect(read["MWG:Description"] as? String == "dash raw")
    }

    /// A file the user made in Finder called `-foo.jpg`. Through `-stay_open`
    /// it is read as an option; through the one-shot it is separated by `--`.
    @Test(needsExiftool) func aFilenameBeginningWithADashRoundTrips() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("-foo.jpg"))
        #expect(ExiftoolRunner.requiresOneShot(arguments: [], files: [url.path]))

        let writer = MetadataWriter()
        let outcomes = await writer.write(
            MetadataEdit(description: "dash named", keywords: ["k"]), to: [url])
        try #require(outcomes[0].error == nil,
                     "hostile-name write failed: \(String(describing: outcomes[0].error))")

        let read = try exiftoolRead(url, ["-MWG:Description", "-MWG:Keywords"])
        #expect(read["MWG:Description"] as? String == "dash named")
        #expect(read["MWG:Keywords"] as? String == "k")
    }

    /// A description containing a newline. Through `-stay_open` this is
    /// argument injection: exiftool would read the tail of the value as its
    /// next argument — here, a literal `-delete_original!`.
    ///
    /// The CRLF case is the one a caption pasted from Windows actually carries,
    /// and it is the case Swift's `Character` comparison misses, so it is
    /// exercised against the real binary rather than only against the routing
    /// predicate.
    @Test(needsExiftool, arguments: ["first line\n-delete_original!\nthird line",
                                     "windows\r\ncaption\r\n-delete_original!"])
    func aDescriptionContainingANewlineRoundTrips(_ hostile: String) async throws {
        let name = "b-\(hostile.utf8.count).jpg"
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent(name))
        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(description: hostile), to: [url])
        try #require(outcomes[0].error == nil,
                     "hostile-value write failed: \(String(describing: outcomes[0].error))")

        let read = try exiftoolRead(url, ["-MWG:Description"])
        #expect(read["MWG:Description"] as? String == hostile)
        // The injected text must have been stored, not executed: the file is
        // still here and so is its neighbour.
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test(needsExiftool) func anOrdinaryWriteTakesTheStayOpenPathAndReusesIt() throws {
        let path = try #require(MetadataWriter.availability.executablePath)
        let runner = ExiftoolRunner(executable: path)
        defer { runner.shutdown() }

        let first = try runner.run(arguments: ["-ver"], files: [])
        #expect(first.route == .stayOpen)
        #expect(first.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("13")
            || first.stdout.contains("."))

        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("c.jpg"))
        let second = try runner.run(arguments: ["-j", "-s", "-MWG:Description"],
                                    files: [url.path])
        #expect(second.route == .stayOpen)

        let hostile = try Fixtures.writeImage(to: tree.root.appendingPathComponent("-d.jpg"))
        let third = try runner.run(arguments: ["-j", "-s", "-MWG:Description"],
                                   files: [hostile.path])
        #expect(third.route == .oneShot)
    }

    // MARK: Failure behaviour

    /// Spec §11: a batch never fails as a unit.
    @Test(needsExiftool) func aBatchReportsPerItemResults() async throws {
        let good = try Fixtures.writeImage(to: tree.root.appendingPathComponent("good.jpg"))
        let missing = tree.root.appendingPathComponent("gone.jpg")
        let unsupported = try tree.file("notes.txt")

        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(rating: 2),
                                          to: [good, missing, unsupported])
        #expect(outcomes.count == 3)
        #expect(outcomes[0].error == nil)
        #expect(outcomes[1].error == .fileMissing(missing.path))
        #expect(outcomes[2].error == .unsupportedFormat("txt"))
    }

    /// Spec §9, constraint 3, end to end: a mismatch restores from the
    /// `_original` backup and reports a failure rather than leaving the
    /// half-written file in place.
    @Test(needsExiftool) func averificationMismatchRestoresTheOriginal() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("e.jpg"))
        let originalBytes = try Data(contentsOf: url)

        let writer = MetadataWriter()
        await writer.setVerificationOverride { _ in ["MWG:Description"] }
        let outcomes = await writer.write(MetadataEdit(description: "never lands"), to: [url])

        #expect(outcomes[0].error == .verificationFailed(["MWG:Description"]))
        #expect(try Data(contentsOf: url) == originalBytes,
                "a failed verification must leave the original bytes on disk")
        #expect(!FileManager.default.fileExists(atPath: url.path + "_original"),
                "the backup must not be left lying around")
    }

    /// The same, for a sidecar exiftool had to create: there is no `_original`,
    /// so the undo is deleting it.
    @Test(needsExiftool) func afailedSidecarVerificationRemovesTheCreatedSidecar() async throws {
        let container = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("IMG_0003.dng"), format: .tiff)
        let sidecar = tree.root.appendingPathComponent("IMG_0003.xmp")

        let writer = MetadataWriter()
        await writer.setVerificationOverride { _ in ["MWG:Description"] }
        let outcomes = await writer.write(MetadataEdit(description: "never lands"),
                                          to: [container])

        #expect(outcomes[0].error == .verificationFailed(["MWG:Description"]))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path),
                "a sidecar created for a write that failed verification must be removed")
    }

    @Test(needsExiftool) func preservesTheModificationTimeWhenAsked() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("f.jpg"))
        // Backdated so "unchanged" cannot be confused with "written just now".
        let then = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: then],
                                              ofItemAtPath: url.path)

        let writer = MetadataWriter()
        let outcomes = await writer.write(
            MetadataEdit(description: "kept"), to: [url],
            options: WriteOptions(preserveModificationTime: true))
        try #require(outcomes[0].error == nil)

        let mtime = try #require(outcomes[0].success?.rehash?.mtime)
        #expect(abs(mtime - then.timeIntervalSince1970) < 1)
    }

    @Test(needsExiftool) func doesNotPreserveTheModificationTimeByDefault() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("g.jpg"))
        let then = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: then],
                                              ofItemAtPath: url.path)

        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(description: "moved on"), to: [url])
        try #require(outcomes[0].error == nil)
        let mtime = try #require(outcomes[0].success?.rehash?.mtime)
        #expect(mtime > then.timeIntervalSince1970 + 1)
    }

    // MARK: The index

    /// After a successful write the row carries the new `size`/`mtime` and the
    /// re-verified hashes, so tier 0 does not decide the file is stale and
    /// clear every hash on it — including the `phash`, which is still correct
    /// because no pixel moved.
    @Test(needsExiftool) func updatesTheIndexRowAfterASuccessfulWrite() async throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("h.jpg"))
        let store = try IndexStore.inMemory()
        let mediaType = try #require(MediaType.forExtension("jpg"))
        let before = try FileHasher().hashes(for: url, mediaType: mediaType)
        let stat = try FileManager.default.attributesOfItem(atPath: url.path)

        var record = FileRecord(
            id: nil, path: url.path, parentDir: url.deletingLastPathComponent().path,
            name: url.lastPathComponent, ext: "jpg",
            size: (stat[.size] as! NSNumber).int64Value,
            mtime: (stat[.modificationDate] as! Date).timeIntervalSince1970,
            device: 1, inode: 1, width: 64, height: 48,
            captureTime: nil, captureOffset: nil, cameraMake: nil, cameraModel: nil,
            orientation: 1, contentHash: before.contentHash, imageHash: before.imageHash,
            imageHashKind: before.imageHashKind, phash: "abcdef0123456789",
            hashedAt: 100, indexedAt: 100)
        record.id = try store.upsert(record)

        let writer = MetadataWriter()
        let outcomes = await writer.write(MetadataEdit(description: "indexed"), to: [url],
                                          updating: store)
        try #require(outcomes[0].error == nil)
        #expect(outcomes[0].success?.warnings.contains(.indexRowNotUpdated) == false)

        let row = try #require(try store.record(atPath: url.path))
        let rehash = try #require(outcomes[0].success?.rehash)
        #expect(row.size == rehash.size)
        #expect(row.mtime == rehash.mtime)
        #expect(row.contentHash == rehash.contentHash)
        #expect(row.contentHash != before.contentHash)
        #expect(row.imageHash == before.imageHash)
        // The perceptual hash survives: an EXIF edit moves no pixels.
        #expect(row.phash == "abcdef0123456789")
        #expect(try store.needsReindex(path: url.path, size: row.size, mtime: row.mtime) == false)
    }
}
