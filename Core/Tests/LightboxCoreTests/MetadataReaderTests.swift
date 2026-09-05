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

    // Deliberately does not rely on a plain `== ` against a value computed
    // with an explicit UTC `Calendar` alone: that equality holds today, but a
    // regression to `TimeZone.current` in `parseEXIFDate` would only be
    // *caught* by such a check on a runner whose local zone happens to
    // differ from UTC. On a CI runner provisioned with TZ=UTC (a common
    // Docker default) local and UTC coincide, the regressed implementation
    // would produce the same value as the correct one, and this test would
    // pass despite the bug. Pinning to an absolute epoch and additionally
    // asserting inequality against two independent non-UTC interpretations
    // makes the check meaningful regardless of the runner's zone. Do not
    // simplify this back to a single equality against a locally-built
    // Calendar.
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
