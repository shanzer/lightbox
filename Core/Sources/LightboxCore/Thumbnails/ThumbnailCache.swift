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
    /// Internal rather than private so tests can drive the cleanup branches
    /// below directly; their failure conditions are not reachable through
    /// `thumbnail(for:mtime:size:)` on demand.
    @concurrent
    nonisolated static func generate(
        from url: URL, to destination: URL, size: Int
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

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

        // Encoded to a unique temporary name and moved into place rather than
        // written straight to `destination`. This is hardening, not a fix for an
        // observed defect: ImageIO on this platform publishes nothing at the
        // destination path until the encode completes, and a failed or abandoned
        // `CGImageDestinationFinalize` leaves no file at all rather than a
        // truncated one. What the rename does buy is the window ImageIO cannot
        // cover — `kill -9`, power loss, or ENOSPC partway through — where a
        // partial file sitting at `destination` would be indistinguishable from
        // a finished thumbnail to the existence check in
        // `thumbnail(for:mtime:size:)`, and the mtime-keyed name means nothing
        // would ever invalidate it. It also makes the multi-writer case below
        // explicit rather than accidental.
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
        return destination
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
