import Testing
import Foundation
import CryptoKit
import Synchronization
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
        // HEIC left this list in issue #12: the exiftool round-trip experiment
        // showed the primary item's extents survive, so it now has a rule.
        for format in [Fixtures.Format.tiff] {
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

/// Counts SIGUSR1 deliveries.
///
/// A global because a C signal handler cannot capture context, and an atomic
/// because the test now reads it *while* the handler is still running: the
/// per-window assertion below compares readings taken either side of a signal
/// burst, so a torn or reordered read would be an assertion on nothing.
/// `wrappingAdd` on an `Int` is lock-free, which is what makes it legal in a
/// handler; anything taking a lock would not be.
private let signalDeliveries = Atomic<Int>(0)

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
/// inside `read` until the writer produces bytes. The hash runs on a dedicated
/// `Thread` rather than directly in the test body because swift-testing runs
/// the body on a Swift Concurrency executor thread, where the signal did not
/// reach the blocked read — an earlier version of this test passed with the
/// EINTR retry deleted, i.e. proved nothing.
///
/// **The signals are fired in bounded windows, never continuously.** An earlier
/// version ran a thread spraying `pthread_kill` every 100µs from before the
/// FIFO was open until the hash returned, and hung roughly one run in twelve on
/// a loaded machine — `done.wait(timeout:)` timing out after thirty seconds. It
/// hung because a FIFO's `open` is itself interruptible: the reader and the
/// writer have to be in `open` at the same instant to rendezvous, and a reader
/// being kicked out with EINTR every 100µs can miss that rendezvous
/// indefinitely, leaving the writer blocked in `open` with nothing to pair
/// with. Signalling into a state the test has not established yet is the bug;
/// the protocol below establishes each state first and only then signals.
///
/// Separated into its own suite because it installs a process-wide signal
/// handler; `.serialized` keeps that from overlapping other tests.
@Suite(.serialized)
struct ContentHasherSignalTests {
    /// The hasher's read buffer, and the size of each chunk fed to it.
    private static let chunkSize = 4096
    /// How many deliveries each burst waits for, and how often it fires while
    /// waiting. The burst ends on the count, never on a stopwatch — see
    /// `signalWindow()`.
    private static let requiredDeliveries = 2
    private static let signalInterval: UInt32 = 2_000
    /// How many chunks get a burst before the rest of the payload is written at
    /// full speed. More than one so the retry is exercised part-way through the
    /// stream as well as on the very first read, where nothing has been
    /// transferred yet and preserving the file offset is trivially correct.
    private static let windowCount = 4
    /// Every wait in the test. Generous enough never to fire on a loaded
    /// machine, finite so a genuine wedge is a failed expectation rather than a
    /// hung suite.
    private static let patience = 15.0

    @Test func aSignalArrivingMidReadIsRetriedRatherThanReportedAsTruncated() throws {
        let tree = try TempTree()
        let fifo = tree.root.appendingPathComponent("pipe")
        try #require(mkfifo(fifo.path, 0o600) == 0, "mkfifo failed: errno \(errno)")

        // The test's end of the FIFO, opened `O_RDWR` before any reader exists.
        // Two properties come out of that and both are load-bearing. It cannot
        // block — `O_WRONLY` alone blocks until a reader arrives, which is the
        // rendezvous the old version deadlocked in — so the hashing thread's
        // own `open` returns immediately and the test never waits here. And
        // because this descriptor is also a read end, `poll` on it reports
        // precisely whether the pipe still holds bytes the hasher has not taken,
        // which is how the protocol below knows where the hasher is without
        // guessing with a sleep.
        let writeFD = fifo.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDWR | O_NONBLOCK)
        }
        try #require(writeFD >= 0, "could not open the FIFO: errno \(errno)")
        var writeClosed = false
        defer { if !writeClosed { close(writeFD) } }
        // Belt and braces. Holding a read end here already makes EPIPE
        // unreachable, but a regression that closes the hasher's end early must
        // fail an expectation, never take the whole run down with signal 13.
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)

        // A handler without SA_RESTART, so a delivered signal makes the
        // in-flight `read` return -1/EINTR instead of being restarted for us.
        signalDeliveries.store(0, ordering: .relaxed)
        var installed = sigaction()
        var previous = sigaction()
        installed.__sigaction_u.__sa_handler = { _ in
            signalDeliveries.wrappingAdd(1, ordering: .relaxed)
        }
        installed.sa_flags = 0
        sigemptyset(&installed.sa_mask)
        try #require(sigaction(SIGUSR1, &installed, &previous) == 0)
        defer { sigaction(SIGUSR1, &previous, nil) }

        // Larger than the buffer, so the hasher makes many reads and the retry
        // has to preserve the file offset across more than one of them.
        let payload = [UInt8]((0..<(64 << 10)).map { UInt8($0 % 251) })

        let box = SignalTestBox()
        let ready = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        /// Holds the hashing thread alive until the test is finished with it.
        ///
        /// The test signals that thread by `pthread_t`, and a `Thread`'s pthread
        /// is detached: once it exits, the id is free to be recycled, and a
        /// `pthread_kill` racing the exit either fails or lands on an unrelated
        /// thread. Parking after the result is published costs nothing and
        /// makes the id valid for as long as the test can still use it.
        let teardown = DispatchSemaphore(value: 0)

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
            // Publishes `box.thread`; nothing signals this thread before the
            // test has waited on it.
            ready.signal()
            // Without the EINTR retry this throws `.truncated`, or — far worse
            // — treats the interrupted read as end-of-file and returns the
            // hash of a prefix of the payload.
            box.result = Result { try ContentHasher(bufferSize: Self.chunkSize).hash(fifo) }
            done.signal()
            teardown.wait()
        }

        /// Feeds `range` of the payload into the pipe without ever blocking, so
        /// a hasher that has stopped draining ends the test with a failed
        /// expectation instead of wedging it.
        func push(_ range: Range<Int>) -> Bool {
            var offset = range.lowerBound
            let deadline = Date().addingTimeInterval(Self.patience)
            while offset < range.upperBound {
                guard Date() < deadline else { return false }
                let written = payload.withUnsafeBufferPointer { buffer in
                    write(writeFD, buffer.baseAddress! + offset, range.upperBound - offset)
                }
                if written > 0 { offset += written; continue }
                guard written < 0, errno == EAGAIN || errno == EINTR else { return false }
                usleep(200)
            }
            return true
        }

        /// Whether the hashing thread has already returned. Consuming `done`
        /// here is why the flag exists: it must not then be waited on twice.
        var finishedEarly = false
        func hasherFinished() -> Bool {
            if !finishedEarly, done.wait(timeout: .now()) == .success { finishedEarly = true }
            return finishedEarly
        }

        /// Waits until the pipe is empty again.
        ///
        /// Nothing but the hasher can consume from this FIFO, so an empty pipe
        /// means the hasher has taken every byte written so far. From there its
        /// only remaining move is another `read`, on a pipe the test is not
        /// writing to — which blocks. That is the state the burst below needs,
        /// established rather than assumed.
        ///
        /// `.hasherFinished` is the regression's shape, not an internal error:
        /// a hasher that reports an interrupted read as a failure returns
        /// part-way through the payload and never drains the rest. Detecting it
        /// here turns that into the error assertion at the end of the test
        /// rather than into `patience` seconds of waiting for a thread that has
        /// already gone.
        enum DrainOutcome { case drained, hasherFinished, timedOut }
        func drain() -> DrainOutcome {
            let deadline = Date().addingTimeInterval(Self.patience)
            while Date() < deadline {
                var watched = pollfd(fd: writeFD, events: Int16(POLLIN), revents: 0)
                let signalled = poll(&watched, 1, 0)
                if signalled == 0 { return .drained }
                if hasherFinished() { return .hasherFinished }
                guard signalled > 0 || errno == EINTR else { return .timedOut }
                usleep(200)
            }
            return .timedOut
        }

        /// Fires SIGUSR1 at the hashing thread until the handler has taken
        /// `requiredDeliveries` of them, and reports how many it took.
        ///
        /// **Bounded by progress, not by wall clock, and that distinction is
        /// the whole fix.** A previous version fired for a fixed 60ms and then
        /// demanded two deliveries — which is not a statement about the hasher
        /// at all, it is a statement about how often the scheduler runs the
        /// hashing thread inside 60ms. On a loaded machine it sometimes does
        /// not run it twice, and the test failed on correct code roughly twice
        /// in 130 runs. Waiting for the deliveries instead removes the
        /// assumption rather than trading one timing guess for another, and
        /// costs nothing on an idle machine, where two arrive in ~4ms.
        ///
        /// The cap is `patience`, and a hasher that has already returned ends
        /// the loop early. That is precisely the regression's shape — a hasher
        /// that reports the interrupted read as a failure stops taking signals
        /// — and the short count it leaves behind is what fails the
        /// expectation below.
        func signalWindow() -> Int {
            let before = signalDeliveries.load(ordering: .relaxed)
            let deadline = Date().addingTimeInterval(Self.patience)
            var delivered = 0
            while delivered < Self.requiredDeliveries {
                // Checked before the kill, not after: a hasher that has
                // returned will never take another signal, so there is nothing
                // left to wait for.
                if hasherFinished() { break }
                guard Date() < deadline else { break }
                if let thread = box.thread { pthread_kill(thread, SIGUSR1) }
                usleep(Self.signalInterval)
                delivered = signalDeliveries.load(ordering: .relaxed) - before
            }
            return delivered
        }

        hashing.start()
        defer { teardown.signal() }
        try #require(ready.wait(timeout: .now() + Self.patience) == .success,
                     "the hashing thread never started")

        windows: for window in 0..<Self.windowCount {
            let chunk = (window * Self.chunkSize)..<((window + 1) * Self.chunkSize)
            try #require(push(chunk), "could not write chunk \(window): errno \(errno)")
            switch drain() {
            case .drained:
                break
            case .hasherFinished:
                break windows
            case .timedOut:
                Issue.record("the hasher stopped draining chunk \(window)")
                break windows
            }

            // Two deliveries, not one, and that is the whole proof. With the
            // pipe verifiably empty the hasher can only be finishing the digest
            // of the chunk it just took — microseconds — or already blocked in
            // `read`. If the first delivery caught it in the digest, it then
            // enters `read` and the second, at least one `signalInterval`
            // later, interrupts it there; if the first caught it in `read`, so
            // did the second. Either way a blocked `read` was interrupted. One
            // delivery would leave the vacuous case — caught before it ever
            // reached `read` — open.
            //
            // Reaching this line short is therefore only possible if the hasher
            // stopped taking signals within `patience`, which is the
            // regression, not a scheduling accident: `signalWindow()` waits for
            // the count rather than for a stopwatch.
            let delivered = signalWindow()
            #expect(delivered >= Self.requiredDeliveries, """
                window \(window): \(delivered) SIGUSR1 delivered, too few to prove a \
                blocked read was interrupted
                """)
        }

        if !finishedEarly {
            try #require(push((Self.windowCount * Self.chunkSize)..<payload.count),
                         "could not write the tail of the payload: errno \(errno)")
        }
        // Drops the last reference to both ends, so the hasher's next read sees
        // a clean end-of-file.
        close(writeFD)
        writeClosed = true
        if !finishedEarly {
            try #require(done.wait(timeout: .now() + Self.patience) == .success,
                         "the hash never returned")
        }

        var expected = SHA256()
        expected.update(data: Data(payload))
        switch try #require(box.result, "the hashing thread recorded no result") {
        case .success(let hash):
            #expect(hash == expected.finalize().hexEncoded)
        case .failure(let error):
            Issue.record("""
                hashing threw \(error); a signal delivered into a blocked read must be \
                retried, not reported as a failure
                """)
        }
    }
}
