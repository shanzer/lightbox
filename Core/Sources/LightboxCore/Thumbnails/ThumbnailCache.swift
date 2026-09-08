import Foundation
import CryptoKit
import QuickLookThumbnailing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ThumbnailError: Error, Equatable {
    case generationFailed
}

/// Generates thumbnails with QuickLook and caches them on disk as PNG.
///
/// QuickLook rather than ImageIO: it renders RAW, HEIC, PSD, and anything else
/// the system has a generator for, which is exactly the set of formats a photo
/// library contains and ImageIO alone would half-cover.
public actor ThumbnailCache {
    /// This actor's body runs on a dispatch queue of its own, not on the
    /// cooperative pool (#30).
    ///
    /// Nothing here forks a subprocess, but three things here block on the
    /// filesystem and one of them blocks for a long time: `evictIfNeeded()` and
    /// `cachedCount()` enumerate a directory holding one PNG per thumbnail the
    /// user has ever scrolled past — tens of thousands after a session — and
    /// `stat` every one of them, and `thumbnail(for:mtime:size:)` stats the
    /// destination on every request. On the external drive this app exists for,
    /// a directory walk that wide is seconds, not milliseconds. See
    /// `BlockingWork` for why seconds on a cooperative thread is the whole bug.
    private let queue = BlockingWork.serialQueue(BlockingWork.thumbnailCacheLabel)

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Test seam for #30: the queue this actor's body actually ran on.
    func currentQueueLabel() -> String { BlockingWork.currentQueueLabel }

    private let directory: URL
    private let budgetBytes: Int64
    /// In-flight generations, so eight scroll events for one image do not
    /// launch eight QuickLook requests.
    private var inFlight: [String: Task<URL, any Error>] = [:]

    /// Extension for a generation that has not yet been moved into place.
    /// A file bearing it is work in progress, never a cache entry.
    static let temporaryExtension = "tmp"

    /// Number of QuickLook generations started. Internal rather than private so
    /// tests can prove coalescing actually coalesces — a shared cache key alone
    /// makes eight independent generations look identical from the outside.
    private(set) var generationCount = 0

    /// Keys currently generating, so tests can prove no exit path strands one.
    var inFlightCount: Int { inFlight.count }

    public init(directory: URL, budgetBytes: Int64 = 2 << 30) {
        self.directory = directory
        self.budgetBytes = budgetBytes
    }

    /// Returns a cached thumbnail for `url`, generating one if it is absent.
    ///
    /// Concurrent requests for the same key share one generation, so a burst of
    /// scroll events over a single cell costs one QuickLook request.
    ///
    /// - Precondition: `url` must already be standardized. The cache key is
    ///   built from `url.path` verbatim, so `/a/b.jpg`, `/a/./b.jpg` and
    ///   `/a/sub/../b.jpg` are three distinct keys for one file and cost three
    ///   generations. Normalizing here would diverge from callers that key
    ///   their own state on the path they passed in; the caller owns the
    ///   canonical form.
    public func thumbnail(for url: URL, mtime: Double, size: Int) async throws -> URL {
        let key = Self.cacheKey(path: url.path, mtime: mtime, size: size)
        let destination = location(for: key)

        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        if let existing = inFlight[key] { return try await existing.value }

        generationCount += 1
        let task = Task<URL, any Error> {
            try await Self.generate(from: url, to: destination, size: size)
        }

        // Installed and cleared in the same scope. `defer` runs on the throwing
        // path too, so a failed generation cannot strand its key and wedge every
        // later request for the same image on an already-finished task. Only the
        // caller that installed the key removes it, and it does so immediately
        // on resuming from `task.value`; callers that merely await an existing
        // task never touch the dictionary.
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// Deletes least-recently-modified entries until the cache fits its budget.
    /// At least one entry is always kept, so a pathologically small budget
    /// cannot blank the grid the user is currently looking at.
    public func evictIfNeeded() throws {
        var entries = allEntries()
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > budgetBytes else { return }

        entries.sort { $0.modified < $1.modified }
        while total > budgetBytes, entries.count > 1 {
            let victim = entries.removeFirst()
            try? FileManager.default.removeItem(at: victim.url)
            total -= victim.size
        }
    }

    public func cachedCount() throws -> Int {
        allEntries().count
    }

    // MARK: - Internals

    /// The blocking half of a generation: encode `image` as PNG and leave it at
    /// the given destination.
    ///
    /// A closure rather than a direct call so `CooperativePoolTests` can assert
    /// which queue the encode ran on, exactly as `FileOperator`'s injected
    /// `copier` does for the filesystem half of a batch. Production always
    /// passes `install(_:at:)`.
    typealias PNGInstalling = @Sendable (CGImage, URL) throws -> Void

    /// Renders `url` and writes the PNG to `destination`.
    ///
    /// `nonisolated` because nothing here touches actor state: a slow RAW decode
    /// must not serialise behind, or in front of, every other request.
    ///
    /// `@concurrent` is load-bearing, not decoration. Under
    /// `NonisolatedNonsendingByDefault` (SE-0461 — one stray `swiftSettings`
    /// line today, the language default in Swift 7) a plain `nonisolated async`
    /// function runs on its *caller's* executor, which here is the
    /// `ThumbnailCache` actor. That would silently re-serialise every decode and
    /// encode onto the actor — the exact cost this function was hoisted out of
    /// the actor to avoid — and it would surface as a sluggish grid rather than
    /// as a test failure. The attribute pins the off-actor execution under both
    /// modes.
    ///
    /// **Only the QuickLook render stays here.** `@concurrent` means "on the
    /// cooperative pool", which is the right home for an `await` that parks
    /// nothing and the wrong home for `install`, which parks a thread in
    /// ImageIO and `rename(2)`. So the render runs here and the encode hops
    /// through `BlockingWork.run` (#30).
    ///
    /// **Fan-out.** The grid starts one `.task` per visible cell, and a
    /// full-screen window of small tiles is 200-odd cells. `BlockingWork.run`
    /// admits 64 concurrently-blocked closures and queues the surplus, so 200
    /// simultaneous encodes would not deadlock but would push everything else
    /// that shares that queue — the hashing pass, file operations — behind
    /// them. Measured rather than assumed: 200 simultaneous `generate` calls
    /// peak at **at most 10** concurrent installs — 6 to 7 in an ordinary full
    /// test run, 10 with the cooperative pool narrowed to one thread — because
    /// QuickLook's render is milliseconds and the encode is 0.6 ms, so the
    /// requests arrive at the hop spread out rather than together.
    /// `theEncodeFanOutStaysWellUnderTheBlockingWorkCeiling` guards it at half
    /// the ceiling (`< 32`), the margin absorbing other suites' use of the same
    /// queue, and
    /// `theBlockingWorkQueueAdmitsExactlySixtyFourBlockedEncodes` pins the
    /// ceiling itself by holding every encode until 64 are in flight, so the
    /// number depends on the queue's width rather than on how fast anything
    /// runs — the margin is two assertions, not a remembered scratch run.
    ///
    /// Not the *only* caller that scales with the window, though it is the only
    /// measured one: `FolderTreeView.loadWithLookahead` fans out with sidebar
    /// height and holds each slot far longer. The table on
    /// `BlockingWork.queue` carries both.
    ///
    /// Internal rather than private so tests can drive the cleanup branches
    /// below directly; their failure conditions are not reachable through
    /// `thumbnail(for:mtime:size:)` on demand.
    @concurrent
    nonisolated static func generate(
        from url: URL, to destination: URL, size: Int,
        install: @escaping PNGInstalling = ThumbnailCache.install
    ) async throws -> URL {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: 1.0,
            representationTypes: .thumbnail)
        let image: CGImage
        do {
            image = try await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request).cgImage
        } catch {
            throw ThumbnailError.generationFailed
        }

        // The QuickLook call above is genuinely asynchronous and parks no
        // thread, so it stays where `@concurrent` puts it. Everything in
        // `install` blocks, so it does not (#30).
        try await BlockingWork.run { try install(image, destination) }
        return destination
    }

    /// Writes `image` to `destination` as a PNG.
    ///
    /// Every line here blocks the calling thread — `mkdir(2)`, an ImageIO
    /// encode, `rename(2)`, and up to two `stat`s — so it is only ever reached
    /// through the `BlockingWork.run` hop in `generate`.
    ///
    /// Encoded to a unique temporary name and moved into place rather than
    /// written straight to `destination`. This is hardening, not a fix for an
    /// observed defect: ImageIO on this platform publishes nothing at the
    /// destination path until the encode completes, and a failed or abandoned
    /// `CGImageDestinationFinalize` leaves no file at all rather than a
    /// truncated one. What the rename does buy is the window ImageIO cannot
    /// cover — `kill -9`, power loss, or ENOSPC partway through — where a
    /// partial file sitting at `destination` would be indistinguishable from
    /// a finished thumbnail to the existence check in
    /// `thumbnail(for:mtime:size:)`, and the mtime-keyed name means nothing
    /// would ever invalidate it. It also makes the multi-writer case below
    /// explicit rather than accidental.
    nonisolated static func install(_ image: CGImage, at destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(
                "\(destination.lastPathComponent).\(UUID().uuidString).\(temporaryExtension)")
        guard let sink = CGImageDestinationCreateWithURL(
            temporary as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ThumbnailError.generationFailed
        }
        CGImageDestinationAddImage(sink, image, nil)
        guard CGImageDestinationFinalize(sink) else {
            try? FileManager.default.removeItem(at: temporary)
            throw ThumbnailError.generationFailed
        }

        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            // Another process holding the same cache directory may have won the
            // race. Its entry is keyed identically, so it is equivalent, and the
            // request is satisfied. Only a genuinely absent destination is a
            // failure.
            guard FileManager.default.fileExists(atPath: destination.path) else {
                throw ThumbnailError.generationFailed
            }
        }
    }

    private struct Entry {
        let url: URL
        let size: Int64
        let modified: Date
    }

    /// Every finished cache entry on disk. Never throws: see the two `continue`
    /// cases below.
    private func allEntries() -> [Entry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys) else { return [] }

        var entries: [Entry] = []
        for case let url as URL in walker {
            // An in-progress generation is not a cache entry. Counting one would
            // let `evictIfNeeded()` delete a temporary out from under the encode
            // that is still writing it, and would let the keep-at-least-one
            // guard preserve a stray temporary in place of a real thumbnail.
            guard url.pathExtension != Self.temporaryExtension else { continue }
            // A file that vanished or became unreadable between the enumerator
            // listing it and this lookup is not grounds for failing the whole
            // walk: another process clearing the shared cache directory would
            // otherwise make both `cachedCount()` and `evictIfNeeded()` throw.
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            entries.append(Entry(url: url,
                                 size: Int64(values.fileSize ?? 0),
                                 modified: values.contentModificationDate ?? .distantPast))
        }
        return entries
    }

    private func location(for key: String) -> URL {
        directory
            .appendingPathComponent(String(key.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(key).png")
    }

    /// Keyed on modification time as well as path, so a file edited in place —
    /// which is exactly what phase 2's EXIF editor does — invalidates its own
    /// thumbnail without anything having to remember to.
    static func cacheKey(path: String, mtime: Double, size: Int) -> String {
        var digest = SHA256()
        digest.update(data: Data("\(path)\u{0}\(mtime)\u{0}\(size)".utf8))
        return digest.finalize().hexEncoded
    }
}
