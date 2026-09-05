import Testing
import Foundation

/// Pins `Fixtures.writeImage`'s determinism as a permanent, committed
/// property, not just something verified once by hand and discarded.
///
/// Tasks 7, 8 and 9 build their central warranty test on this: "an exiftool
/// metadata edit leaves the image data byte-identical" is only meaningful if
/// two `writeImage` calls with identical parameters produce identical bytes
/// in the first place. That property is exactly the kind of thing that can
/// break silently under a future ImageIO update — an encoder that embeds a
/// timestamp, thread-count-dependent quantization, metadata key ordering —
/// so it needs its own coverage rather than living only in Task 7/8's
/// pass/fail results.
///
/// A `struct` suite so swift-testing builds a fresh instance per test and
/// releases it afterwards: teardown of `tree` is then the framework's
/// contract rather than an ARC ordering inferred from where it was last used.
struct FixturesTests {
    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    /// JPEG specifically, since Task 7's exiftool round-trip warranty test
    /// exercises JPEG. PNG, HEIC and TIFF are covered too since Tasks 8/9
    /// touch other formats and a future regression is as likely to be
    /// format-specific (e.g. an encoder change) as global.
    @Test(arguments: [Fixtures.Format.jpeg, .png, .heic, .tiff])
    func writeImageIsByteIdenticalAcrossTwoCallsWithIdenticalParameters(
        format: Fixtures.Format
    ) throws {
        let url1 = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("first.\(format.ext)"),
            format: format, width: 50, height: 40, seed: 7)
        let url2 = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("second.\(format.ext)"),
            format: format, width: 50, height: 40, seed: 7)

        let data1 = try Data(contentsOf: url1)
        let data2 = try Data(contentsOf: url2)

        #expect(!data1.isEmpty, "sanity check that a real file was written for \(format.ext)")
        #expect(data1 == data2, "two writeImage calls with identical parameters diverged for \(format.ext)")
    }

    /// Guards against a fixture that trivially looks deterministic because it
    /// ignores its parameters. A different seed must change the bytes, or the
    /// equality check above would still pass for a fixture that always wrote
    /// the same blank image regardless of input.
    @Test func writeImageProducesDifferentBytesForADifferentSeed() throws {
        let urlA = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("seedA.jpg"),
            format: .jpeg, width: 50, height: 40, seed: 7)
        let urlB = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("seedB.jpg"),
            format: .jpeg, width: 50, height: 40, seed: 99)

        let dataA = try Data(contentsOf: urlA)
        let dataB = try Data(contentsOf: urlB)
        #expect(dataA != dataB)
    }
}
