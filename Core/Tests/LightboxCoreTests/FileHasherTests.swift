import Testing
import Foundation
@testable import LightboxCore

/// A `struct` suite so swift-testing builds a fresh instance per test and
/// releases it afterwards, matching the other hashing suites.
struct FileHasherTests {
    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    private func mediaType(_ ext: String) throws -> MediaType {
        try #require(MediaType.forExtension(ext), "no MediaType for .\(ext)")
    }

    @Test func computesBothHashesForASupportedFormat() throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
        let hashes = try FileHasher().hashes(for: url, mediaType: mediaType("jpg"))

        #expect(hashes.contentHash == (try ContentHasher().hash(url)))
        #expect(hashes.imageHash?.count == 64)
        #expect(hashes.imageHashKind == JPEGImageHash.kind)
        #expect(hashes.imageHashKind == "jpeg-scan-v1")
    }

    @Test func computesBothHashesForPNG() throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.png"),
                                          format: .png)
        let hashes = try FileHasher().hashes(for: url, mediaType: mediaType("png"))

        #expect(hashes.contentHash == (try ContentHasher().hash(url)))
        let expected = try Data(contentsOf: url).withUnsafeBytes { bytes in
            try ImageDataDigest.digest(bytes, ranges: PNGImageHash.includedRanges(bytes))
        }
        #expect(hashes.imageHash == expected)
        #expect(hashes.imageHashKind == PNGImageHash.kind)
    }

    @Test func computesBothHashesForWebP() throws {
        let url = tree.root.appendingPathComponent("a.webp")
        try FileManager.default.copyItem(at: Fixtures.url("simple.webp"), to: url)
        let hashes = try FileHasher().hashes(for: url, mediaType: mediaType("webp"))

        #expect(hashes.contentHash == (try ContentHasher().hash(url)))
        let expected = try Data(contentsOf: url).withUnsafeBytes { bytes in
            try ImageDataDigest.digest(bytes, ranges: WebPImageHash.includedRanges(bytes))
        }
        #expect(hashes.imageHash == expected)
        #expect(hashes.imageHashKind == WebPImageHash.kind)
    }

    @Test(.enabled(if: exiftoolAvailable, "exiftool not installed"))
    func theWebPWarrantyHoldsThroughTheFacade() throws {
        // The end-to-end statement the indexer relies on: an EXIF edit changes
        // the content hash and leaves the image hash alone.
        let a = tree.root.appendingPathComponent("a.webp")
        let b = tree.root.appendingPathComponent("b.webp")
        try FileManager.default.copyItem(at: Fixtures.url("simple.webp"), to: a)
        try FileManager.default.copyItem(at: a, to: b)
        #expect(exiftool(["-q", "-overwrite_original",
                          "-DateTimeOriginal=2021:07:08 09:10:11", b.path]))

        let type = try mediaType("webp")
        let first = try FileHasher().hashes(for: a, mediaType: type)
        let second = try FileHasher().hashes(for: b, mediaType: type)

        #expect(first.imageHash != nil)
        #expect(first.imageHash == second.imageHash)
        #expect(first.contentHash != second.contentHash)
    }

    @Test func leavesImageHashNilForFormatsWithoutAStableRule() throws {
        for format in [Fixtures.Format.heic, .tiff] {
            let url = try Fixtures.writeImage(
                to: tree.root.appendingPathComponent("x.\(format.ext)"), format: format)
            let hashes = try FileHasher().hashes(for: url, mediaType: mediaType(format.ext))
            #expect(hashes.contentHash == (try ContentHasher().hash(url)),
                    "content hash for \(format.ext)")
            #expect(hashes.imageHash == nil, "image hash for \(format.ext)")
            #expect(hashes.imageHashKind == nil)
        }
    }

    @Test func stillReturnsAContentHashWhenTheImageParserFails() throws {
        // A file with a .jpg extension whose bytes are not a JPEG must not abort
        // the indexing pass; the content hash is still useful for exact dedupe.
        let url = tree.root.appendingPathComponent("lying.jpg")
        try Data("this is not a jpeg".utf8).write(to: url)
        let hashes = try FileHasher().hashes(for: url, mediaType: mediaType("jpg"))
        #expect(hashes.contentHash == (try ContentHasher().hash(url)))
        #expect(hashes.imageHash == nil)
        #expect(hashes.imageHashKind == nil)
    }

    @Test func aWebPExtensionOverAPNGStillYieldsAContentHash() throws {
        // The same rule for the format whose parser landed in this task, and
        // for the more realistic lie: a real image of the wrong format.
        let url = tree.root.appendingPathComponent("lying.webp")
        try Fixtures.writeImage(to: url, format: .png)
        let hashes = try FileHasher().hashes(for: url, mediaType: mediaType("webp"))
        #expect(hashes.contentHash == (try ContentHasher().hash(url)))
        #expect(hashes.imageHash == nil)
        #expect(hashes.imageHashKind == nil)
    }

    @Test func throwsUnreadableForAMissingFile() throws {
        #expect(throws: HashError.unreadable) {
            try FileHasher().hashes(for: tree.root.appendingPathComponent("gone.jpg"),
                                    mediaType: mediaType("jpg"))
        }
    }

    @Test func throwsUnreadableForAMissingFileOfAnUnhashableFormat() throws {
        // The size lookup fails for both branches; neither may swallow it.
        #expect(throws: HashError.unreadable) {
            try FileHasher().hashes(for: tree.root.appendingPathComponent("gone.psd"),
                                    mediaType: mediaType("psd"))
        }
    }

    @Test func throwsRatherThanCrashingOnADirectory() throws {
        // The reason this facade does not memory-map: every read failure has to
        // stay a catchable `HashError` rather than a signal.
        let dir = try tree.directory("a.jpg")
        #expect(throws: HashError.truncated) {
            try FileHasher().hashes(for: dir, mediaType: mediaType("jpg"))
        }
    }

    @Test func handlesAnEmptyFile() throws {
        let url = try tree.file("empty.jpg", bytes: 0)
        let hashes = try FileHasher().hashes(for: url, mediaType: mediaType("jpg"))
        #expect(hashes.contentHash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hashes.imageHash == nil)
        #expect(hashes.imageHashKind == nil)
    }

    @Test func aFileAboveTheInMemoryLimitIsStreamedAndGetsNoImageHash() throws {
        // Above the limit the file is streamed for its content hash alone,
        // rather than buffered whole. The limit is injected so the branch is
        // exercised without writing a quarter-gigabyte file on every test run.
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
        let size = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let hasher = FileHasher(inMemoryLimit: size - 1)

        let hashes = try hasher.hashes(for: url, mediaType: mediaType("jpg"))
        #expect(hashes.contentHash == (try ContentHasher().hash(url)))
        #expect(hashes.imageHash == nil)
        #expect(hashes.imageHashKind == nil)
    }

    @Test func aFileExactlyAtTheInMemoryLimitStillGetsAnImageHash() throws {
        // The comparison is `<=`; pin which side of the boundary is inclusive.
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
        let size = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let hasher = FileHasher(inMemoryLimit: size)

        let hashes = try hasher.hashes(for: url, mediaType: mediaType("jpg"))
        #expect(hashes.imageHash?.count == 64)
        #expect(hashes.imageHashKind == JPEGImageHash.kind)
    }

    @Test func theDefaultInMemoryLimitIs256MB() throws {
        #expect(FileHasher().inMemoryLimit == 256 << 20)
        #expect(FileHasher.defaultInMemoryLimit == 256 << 20)
    }

    @Test func theStreamedContentHashMatchesTheBufferedOne() throws {
        // The two branches compute the content hash by different routes; they
        // must not be able to disagree, or a large file and a small one would
        // be hashed under different rules.
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
        let size = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)

        let buffered = try FileHasher(inMemoryLimit: size).hashes(for: url,
                                                                 mediaType: mediaType("jpg"))
        let streamed = try FileHasher(inMemoryLimit: size - 1).hashes(for: url,
                                                                     mediaType: mediaType("jpg"))
        #expect(buffered.contentHash == streamed.contentHash)
    }

    @Test func readWholeFileAgreesWithTheStreamingHash() throws {
        // `readWholeFile` shares the streaming read loop rather than
        // reimplementing it, so the bytes it returns must hash to what
        // `hash(_:)` produces for the same file.
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
        let hasher = ContentHasher(bufferSize: 97)          // several partial reads
        let data = try hasher.readWholeFile(url, upTo: 1 << 20)

        #expect(data == (try Data(contentsOf: url)))
        #expect(try hasher.hash(url) == ContentHasher().hash(url))
    }

    @Test func readWholeFileReportsAMissingFileAsUnreadable() throws {
        #expect(throws: HashError.unreadable) {
            try ContentHasher().readWholeFile(tree.root.appendingPathComponent("gone.jpg"),
                                              upTo: 1 << 20)
        }
    }

    @Test func readWholeFileReportsADirectoryAsTruncated() throws {
        let dir = try tree.directory("d")
        #expect(throws: HashError.truncated) {
            try ContentHasher().readWholeFile(dir, upTo: 1 << 20)
        }
    }

    @Test func readWholeFileReturnsEmptyForAnEmptyFile() throws {
        let url = try tree.file("empty.bin", bytes: 0)
        #expect(try ContentHasher().readWholeFile(url, upTo: 1 << 20)?.isEmpty == true)
    }

    @Test func readWholeFileDeclinesAFileAboveItsOwnCap() throws {
        // The cap belongs to `readWholeFile`, not to its caller: the method is
        // public, and unbounded buffering is the one way to misuse it.
        let url = try tree.file("big.bin", bytes: 4096)
        #expect(try ContentHasher().readWholeFile(url, upTo: 4095) == nil)
        #expect(try ContentHasher().readWholeFile(url, upTo: 4096)?.count == 4096)
    }

    @Test func readWholeFileSizesTheLinkTargetNotTheLink() throws {
        // The bug this fix exists for, at the layer that now owns the cap.
        // `attributesOfItem(atPath:)` and `URL.resourceValues(forKeys:
        // [.fileSizeKey])` both report a symlink's own size — the length of the
        // path it holds — while `open(2)` follows it. Sizing must use the
        // descriptor, or a seven-byte link reads its multi-hundred-megabyte
        // target whole.
        let target = try tree.file("target.bin", bytes: 4096)
        let link = tree.root.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        // Pin the lie itself, so this test still means something if a future
        // edit reaches for a path-based size again.
        let linkSize = try #require(
            FileManager.default.attributesOfItem(atPath: link.path)[.size] as? Int)
        #expect(linkSize < 4096)

        #expect(try ContentHasher().readWholeFile(link, upTo: 4095) == nil)
        #expect(try ContentHasher().readWholeFile(link, upTo: 4096)?.count == 4096)
    }

    @Test func aSymlinkToAnOversizedTargetTakesTheStreamingBranch() throws {
        // `Walker.scan` with `followSymlinks` emits the *link* path after
        // resolving it with `stat`, so this is the shape the indexer actually
        // hands the hasher. Before the fix the link's own seven-byte size sailed
        // past the guard and the target was buffered whole, producing an image
        // hash and a resident set roughly twice the target's size.
        let target = try Fixtures.writeImage(to: tree.root.appendingPathComponent("target.jpg"))
        let targetSize = try #require(
            FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int)
        let link = tree.root.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let hasher = FileHasher(inMemoryLimit: targetSize - 1)
        let hashes = try hasher.hashes(for: link, mediaType: mediaType("jpg"))

        #expect(hashes.imageHash == nil)
        #expect(hashes.imageHashKind == nil)
        #expect(hashes.contentHash == (try ContentHasher().hash(target)))
    }

    @Test func aSymlinkUnderTheLimitStillGetsAnImageHash() throws {
        // The fix must not overshoot into refusing symlinks: a link to a file
        // that fits is still hashed both ways, identically to the target.
        let target = try Fixtures.writeImage(to: tree.root.appendingPathComponent("target.jpg"))
        let link = tree.root.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let type = try mediaType("jpg")
        #expect(try FileHasher().hashes(for: link, mediaType: type)
                == FileHasher().hashes(for: target, mediaType: type))
    }

    @Test func aDanglingSymlinkIsUnreadable() throws {
        let link = tree.root.appendingPathComponent("dangling.jpg")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: tree.root.appendingPathComponent("nowhere.jpg"))
        #expect(throws: HashError.unreadable) {
            try FileHasher().hashes(for: link, mediaType: mediaType("jpg"))
        }
    }

    @Test func hashesAreValueEqual() throws {
        // `FileHashes` is `Hashable` because the indexer diffs records; two
        // equal readings of the same file must compare equal.
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
        let type = try mediaType("jpg")
        #expect(try FileHasher().hashes(for: url, mediaType: type)
                == FileHasher().hashes(for: url, mediaType: type))
    }
}
