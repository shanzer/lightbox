import Testing
import Foundation
@testable import LightboxCore

/// A `struct` suite so swift-testing builds a fresh instance per test and
/// releases it afterwards: teardown of `tree` is then the framework's
/// contract rather than an ARC ordering inferred from where it was last used.
struct MetadataReaderTests {
    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    @Test func readsDimensionsAndCameraAndCaptureTime() throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"),
                                          width: 200, height: 120)
        let md = try MetadataReader().read(url)
        #expect(md.width == 200)
        #expect(md.height == 120)
        #expect(md.cameraMake == "TestCam")
        #expect(md.cameraModel == "T1")
        #expect(md.captureOffset == "-05:00")
        #expect(md.orientation == 1)

        var components = DateComponents()
        components.year = 2019; components.month = 3; components.day = 4
        components.hour = 10; components.minute = 11; components.second = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!
        #expect(md.captureTime == calendar.date(from: components))
    }

    // What this test does and does not cover, honestly:
    //
    // It pins the parsed time to an absolute epoch value and additionally
    // asserts inequality against two independent non-UTC interpretations
    // (US Eastern, JST). That is real signal: it *does* catch a zone-
    // confusion bug whose result differs from UTC on this input -- for
    // example accidentally applying an offset, or misreading month/day.
    //
    // It does *not* reliably catch a regression to `TimeZone.current` in
    // `parseEXIFDate`. On a runner whose local zone happens to already be
    // UTC (a common CI default, e.g. TZ=UTC), the regressed implementation
    // and the correct one produce a bit-identical `Date`, so no assertion
    // built from `read(_:)`'s *output* can tell them apart -- this was
    // confirmed experimentally by injecting that exact regression and
    // running this test under TZ=UTC, where it passed despite the bug.
    // `MetadataReader.defaultCaptureZone` and
    // `defaultCaptureZoneIsUTCRegardlessOfTheRunnersLocalZone` below are
    // what actually cover that case, by asserting on the fallback constant
    // directly rather than routing through date arithmetic.
    @Test func treatsCaptureTimeAsUTCWhenNoOffsetIsPresent() throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("b.jpg"), offset: nil)
        let md = try MetadataReader().read(url)

        var components = DateComponents()
        components.year = 2019; components.month = 3; components.day = 4
        components.hour = 10; components.minute = 11; components.second = 12

        func date(zoneOffsetSeconds seconds: Int) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: seconds)!
            return calendar.date(from: components)!
        }

        let utcInterpretation = date(zoneOffsetSeconds: 0)
        // 2019-03-04T10:11:12Z, independently computed (date -u -j -f ...).
        #expect(utcInterpretation.timeIntervalSince1970 == 1_551_694_272)

        #expect(md.captureTime == utcInterpretation)
        #expect(md.captureTime != date(zoneOffsetSeconds: -5 * 3600)) // US Eastern
        #expect(md.captureTime != date(zoneOffsetSeconds: 9 * 3600))  // JST
        #expect(md.captureOffset == nil)
    }

    /// The genuinely zone-independent half of the UTC-fallback coverage.
    /// Asserts on the fallback constant directly rather than on any value
    /// produced by parsing a date, so it cannot coincidentally pass on a
    /// runner whose local zone happens to already be UTC: a regression to
    /// `TimeZone.current` at the fallback site changes this constant's
    /// value (or removes it) regardless of what zone the test happens to
    /// run in. See the comment on `treatsCaptureTimeAsUTCWhenNoOffsetIsPresent`.
    @Test func defaultCaptureZoneIsUTCRegardlessOfTheRunnersLocalZone() {
        #expect(MetadataReader.defaultCaptureZone.secondsFromGMT() == 0)
    }

    @Test func readsPNGAndHEICAndTIFF() throws {
        for format in [Fixtures.Format.png, .heic, .tiff] {
            let url = try Fixtures.writeImage(
                to: tree.root.appendingPathComponent("x.\(format.ext)"),
                format: format, width: 40, height: 30)
            let md = try MetadataReader().read(url)
            #expect(md.width == 40, "width for \(format.ext)")
            #expect(md.height == 30, "height for \(format.ext)")
        }
    }

    @Test func returnsNilCaptureTimeWhenTheImageHasNoEXIF() throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("c.png"),
                                          format: .png, captureTime: nil, offset: nil,
                                          make: nil, model: nil)
        let md = try MetadataReader().read(url)
        #expect(md.captureTime == nil)
        #expect(md.cameraMake == nil)
    }

    @Test func throwsNotAnImageForGarbageContent() throws {
        let url = tree.root.appendingPathComponent("junk.jpg")
        try Data("this is not an image".utf8).write(to: url)
        #expect(throws: MetadataError.notAnImage) { try MetadataReader().read(url) }
    }

    @Test func throwsNotAnImageForAnEmptyFile() throws {
        let url = try tree.file("empty.jpg", bytes: 0)
        #expect(throws: MetadataError.notAnImage) { try MetadataReader().read(url) }
    }

    @Test func throwsUnreadableForAMissingFile() throws {
        let url = tree.root.appendingPathComponent("absent.jpg")
        #expect(throws: MetadataError.unreadable) { try MetadataReader().read(url) }
    }
}
