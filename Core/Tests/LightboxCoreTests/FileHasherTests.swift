import Testing
import Foundation
import CryptoKit
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

/// Counts SIGUSR1 deliveries. A global because a C signal handler cannot
/// capture context; safe because `ContentHasherSignalTests` is `.serialized`
/// and is the only thing that installs the handler.
nonisolated(unsafe) private var signalsDelivered = 0

/// Carries a `pthread_t` and the hashing thread's result across threads.
/// `pthread_t` is an opaque pointer and not `Sendable`; each field is written
/// on one thread and read on another only after a semaphore orders the two.
private final class SignalTestBox: @unchecked Sendable {
    var thread: pthread_t?
    var result: Result<String, any Error>?
}

/// The EINTR contract, which needs a read that actually blocks.
///
/// A regular file on a local disk effectively never leaves `read(2)` blocked
/// long enough for a signal to land, so this uses a FIFO: the reader blocks
/// inside `read` until the writer produces bytes, which is a wide and
/// repeatable window. The hash runs on a dedicated `Thread` rather than
/// directly in the test body because swift-testing runs the body on a Swift
/// Concurrency executor thread, where the signal did not reach the blocked
/// read — an earlier version of this test passed with the EINTR retry deleted,
/// i.e. proved nothing.
///
/// Separated into its own suite because it installs a process-wide signal
/// handler; `.serialized` keeps that from overlapping other tests.
@Suite(.serialized)
struct ContentHasherSignalTests {
    @Test func aSignalArrivingMidReadIsRetriedRatherThanReportedAsTruncated() throws {
        let tree = try TempTree()
        let fifo = tree.root.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)

        // A handler without SA_RESTART, so a delivered signal makes the
        // in-flight `read` return -1/EINTR instead of being restarted for us.
        signalsDelivered = 0
        var installed = sigaction()
        var previous = sigaction()
        installed.__sigaction_u.__sa_handler = { _ in signalsDelivered += 1 }
        installed.sa_flags = 0
        sigemptyset(&installed.sa_mask)
        #expect(sigaction(SIGUSR1, &installed, &previous) == 0)
        defer { sigaction(SIGUSR1, &previous, nil) }

        // Larger than the buffer and written in small pieces, so the reader
        // makes many blocking reads for the signals to land inside.
        let payload = Data((0..<(64 << 10)).map { UInt8($0 % 251) })

        let box = SignalTestBox()
        let done = DispatchSemaphore(value: 0)

        let hashing = Thread {
            // The test host blocks SIGUSR1, and a new `Thread` inherits the
            // creating thread's signal mask, so without this the signal stays
            // pending, the read is never interrupted, and the test silently
            // proves nothing.
            var unblock = sigset_t()
            sigemptyset(&unblock)
            sigaddset(&unblock, SIGUSR1)
            pthread_sigmask(SIG_UNBLOCK, &unblock, nil)

            box.thread = pthread_self()
            // Without the EINTR retry this throws `.truncated`, or — far worse
            // — treats the interrupted read as end-of-file and returns the
            // hash of a prefix of the payload.
            box.result = Result { try ContentHasher(bufferSize: 4096).hash(fifo) }
            done.signal()
        }

        nonisolated(unsafe) var signalling = true
        let signaller = Thread {
            while signalling {
                if let t = box.thread { pthread_kill(t, SIGUSR1) }
                usleep(100)
            }
        }

        let writer = Thread {
            let fd = open(fifo.path, O_WRONLY)
            guard fd >= 0 else { return }
            // If the hasher gives up early — which is exactly what a regression
            // here looks like — the read end closes and this thread writes to a
            // pipe with no reader. Without this the process takes SIGPIPE and
            // the whole test run dies with signal 13 instead of reporting a
            // failed expectation.
            fcntl(fd, F_SETNOSIGPIPE, 1)
            payload.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let n = write(fd, bytes.baseAddress! + written,
                                  min(4096, bytes.count - written))
                    if n > 0 { written += n } else if errno != EINTR { break }
                    usleep(300)
                }
            }
            close(fd)
        }

        hashing.start()
        signaller.start()
        writer.start()
        #expect(done.wait(timeout: .now() + 30) == .success)
        signalling = false

        // Without this the test could quietly go vacuous: if signals stopped
        // reaching the hashing thread, the hash would match for the boring
        // reason that nothing ever interrupted it.
        #expect(signalsDelivered > 0, "no SIGUSR1 reached the hashing thread")

        var expected = SHA256()
        expected.update(data: payload)
        #expect(try box.result?.get() == expected.finalize().hexEncoded)
    }
}
