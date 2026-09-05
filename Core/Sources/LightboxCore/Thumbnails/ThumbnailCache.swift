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
        var entries = try allEntries()
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
        try allEntries().count
    }

    // MARK: - Internals

    /// Renders `url` and writes the PNG to `destination`.
    ///
    /// `nonisolated static` because nothing here touches actor state: the
    /// generation runs off the actor and cannot serialise other requests behind
    /// a slow RAW decode.
    private nonisolated static func generate(
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

        // Rendered to a unique temporary name and moved into place, never
        // written to `destination` directly: a crash or an encoder failure
        // partway through would otherwise leave a truncated PNG that the
        // existence check above treats as a valid entry from then on, and the
        // grid would show a corrupt tile forever.
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent("\(destination.lastPathComponent).\(UUID().uuidString).tmp")
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

    private func allEntries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys) else { return [] }

        var entries: [Entry] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
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
