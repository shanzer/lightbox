import Testing
import Foundation
@testable import LightboxCore

/// A `struct` suite so swift-testing builds a fresh instance per test and
/// releases it afterwards: teardown of `tree` is then the framework's
/// contract rather than an ARC ordering inferred from where it was last used.
struct ThumbnailCacheTests {
    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    private var cacheDirectory: URL {
        tree.root.appendingPathComponent("cache", isDirectory: true)
    }

    @Test func generatesAndCachesAThumbnail() async throws {
        let image = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"),
                                            width: 400, height: 300)
        let cache = ThumbnailCache(directory: cacheDirectory)

        let first = try await cache.thumbnail(for: image, mtime: 1000, size: 256)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(try await cache.cachedCount() == 1)
        #expect(await cache.generationCount == 1)

        // Replacing the cached bytes with a sentinel makes the second request's
        // provenance observable: an equal count would also hold if the entry had
        // been regenerated in place, whereas surviving sentinel bytes prove the
        // cached file was served untouched.
        let sentinel = Data("cached-not-regenerated".utf8)
        try sentinel.write(to: first)

        let second = try await cache.thumbnail(for: image, mtime: 1000, size: 256)
        #expect(first == second)
        #expect(try await cache.cachedCount() == 1)
        #expect(try Data(contentsOf: second) == sentinel)
        #expect(await cache.generationCount == 1)
    }

    @Test func aChangedModificationTimeProducesADifferentCacheEntry() async throws {
        let image = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
        let cache = ThumbnailCache(directory: cacheDirectory)

        let before = try await cache.thumbnail(for: image, mtime: 1000, size: 256)
        let after = try await cache.thumbnail(for: image, mtime: 2000, size: 256)
        #expect(before != after)
        #expect(FileManager.default.fileExists(atPath: before.path))
        #expect(FileManager.default.fileExists(atPath: after.path))
        #expect(try await cache.cachedCount() == 2)
        #expect(await cache.generationCount == 2)
    }

    @Test func differentRequestedSizesAreCachedSeparately() async throws {
        let image = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
        let cache = ThumbnailCache(directory: cacheDirectory)

        let small = try await cache.thumbnail(for: image, mtime: 1000, size: 128)
        let large = try await cache.thumbnail(for: image, mtime: 1000, size: 512)
        #expect(small != large)
        #expect(try await cache.cachedCount() == 2)
    }

    @Test func differentPathsWithIdenticalContentAreCachedSeparately() async throws {
        let one = try Fixtures.writeImage(to: tree.root.appendingPathComponent("one.jpg"))
        let two = try Fixtures.writeImage(to: tree.root.appendingPathComponent("two.jpg"))
        let cache = ThumbnailCache(directory: cacheDirectory)

        let first = try await cache.thumbnail(for: one, mtime: 1000, size: 128)
        let second = try await cache.thumbnail(for: two, mtime: 1000, size: 128)
        #expect(first != second)
        #expect(try await cache.cachedCount() == 2)
    }

    @Test func concurrentRequestsForTheSameImageProduceOneEntry() async throws {
        let image = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
        let cache = ThumbnailCache(directory: cacheDirectory)

        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<8 {
                group.addTask { try await cache.thumbnail(for: image, mtime: 1000, size: 256) }
            }
            var seen: [URL] = []
            for try await url in group { seen.append(url) }
            return seen
        }
        #expect(urls.count == 8)
        #expect(Set(urls).count == 1)
        #expect(try await cache.cachedCount() == 1)
        // The point of coalescing: eight scroll events for one image must launch
        // one QuickLook request. A shared cache key alone would satisfy the two
        // assertions above even if all eight had generated independently.
        #expect(await cache.generationCount == 1)
        #expect(await cache.inFlightCount == 0)
    }

    @Test func throwsGenerationFailedForANonImage() async throws {
        let junk = tree.root.appendingPathComponent("junk.jpg")
        try Data("not an image".utf8).write(to: junk)
        let cache = ThumbnailCache(directory: cacheDirectory)

        await #expect(throws: ThumbnailError.generationFailed) {
            _ = try await cache.thumbnail(for: junk, mtime: 1000, size: 256)
        }
        // A failed generation must not leave a half-written entry behind: one
        // would be indistinguishable from a real thumbnail on the next request
        // and would be served as a corrupt image forever.
        #expect(try await cache.cachedCount() == 0)
        // Nor may it strand its key, which would wedge every later request for
        // the same image on a task that has already finished failing.
        #expect(await cache.inFlightCount == 0)
    }

    @Test func throwsGenerationFailedForAMissingFile() async throws {
        let missing = tree.root.appendingPathComponent("gone.jpg")
        let cache = ThumbnailCache(directory: cacheDirectory)

        await #expect(throws: ThumbnailError.generationFailed) {
            _ = try await cache.thumbnail(for: missing, mtime: 1000, size: 256)
        }
        #expect(try await cache.cachedCount() == 0)
        #expect(await cache.inFlightCount == 0)
    }

    @Test func concurrentFailuresAllSeeTheErrorRatherThanHanging() async throws {
        let junk = tree.root.appendingPathComponent("junk.jpg")
        try Data("not an image".utf8).write(to: junk)
        let cache = ThumbnailCache(directory: cacheDirectory)

        let results = await withTaskGroup(of: Result<URL, any Error>.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    await Result { try await cache.thumbnail(for: junk, mtime: 1000, size: 256) }
                }
            }
            var seen: [Result<URL, any Error>] = []
            for await result in group { seen.append(result) }
            return seen
        }

        #expect(results.count == 4)
        for result in results {
            switch result {
            case .success(let url):
                Issue.record("expected a failure, generated \(url.lastPathComponent)")
            case .failure(let error):
                #expect(error as? ThumbnailError == .generationFailed)
            }
        }
        #expect(await cache.inFlightCount == 0)
        #expect(try await cache.cachedCount() == 0)
    }

    @Test func aFailedGenerationDoesNotPoisonLaterRequests() async throws {
        let path = tree.root.appendingPathComponent("a.jpg")
        try Data("not an image".utf8).write(to: path)
        let cache = ThumbnailCache(directory: cacheDirectory)

        await #expect(throws: ThumbnailError.generationFailed) {
            _ = try await cache.thumbnail(for: path, mtime: 1000, size: 256)
        }

        // Same path, same key: once the file becomes a real image the cache must
        // retry rather than serve a stranded in-flight failure.
        try Fixtures.writeImage(to: path)
        let url = try await cache.thumbnail(for: path, mtime: 1000, size: 256)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try await cache.cachedCount() == 1)
    }

    @Test func thumbnailsAreShardedIntoSubdirectories() async throws {
        let image = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
        let cache = ThumbnailCache(directory: cacheDirectory)

        let url = try await cache.thumbnail(for: image, mtime: 1000, size: 128)
        let shard = url.deletingLastPathComponent()
        // Not written directly into the cache root: 50,000 files in one
        // directory is slow to enumerate.
        #expect(shard.standardizedFileURL != cacheDirectory.standardizedFileURL)
        #expect(shard.deletingLastPathComponent().standardizedFileURL
                == cacheDirectory.standardizedFileURL)
        #expect(url.deletingPathExtension().lastPathComponent
            .hasPrefix(shard.lastPathComponent))
    }

    @Test func evictionRemovesTheOldestEntriesUntilUnderBudget() async throws {
        let cache = ThumbnailCache(directory: cacheDirectory, budgetBytes: 1)
        for i in 0..<3 {
            let image = try Fixtures.writeImage(
                to: tree.root.appendingPathComponent("img\(i).jpg"), seed: i)
            _ = try await cache.thumbnail(for: image, mtime: Double(1000 + i), size: 128)
        }
        #expect(try await cache.cachedCount() == 3)
        try await cache.evictIfNeeded()
        // A budget of one byte cannot hold even a single thumbnail; the newest is
        // kept so the grid the user is looking at does not go blank.
        #expect(try await cache.cachedCount() == 1)
    }

    @Test func evictionKeepsTheMostRecentlyModifiedEntry() async throws {
        let cache = ThumbnailCache(directory: cacheDirectory, budgetBytes: 1)
        var written: [URL] = []
        for i in 0..<3 {
            let image = try Fixtures.writeImage(
                to: tree.root.appendingPathComponent("img\(i).jpg"), seed: i)
            written.append(try await cache.thumbnail(for: image, mtime: Double(1000 + i), size: 128))
        }

        // Stamp explicit, well-separated modification times so the survivor is
        // determined by the eviction order rather than by filesystem timestamp
        // resolution over three writes made microseconds apart.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for (offset, url) in written.enumerated() {
            try FileManager.default.setAttributes(
                [.modificationDate: base.addingTimeInterval(Double(offset) * 60)],
                ofItemAtPath: url.path)
        }

        try await cache.evictIfNeeded()
        #expect(try await cache.cachedCount() == 1)
        #expect(FileManager.default.fileExists(atPath: written[2].path))
        #expect(!FileManager.default.fileExists(atPath: written[0].path))
        #expect(!FileManager.default.fileExists(atPath: written[1].path))
    }

    @Test func evictionIsANoOpWhenUnderBudget() async throws {
        let cache = ThumbnailCache(directory: cacheDirectory, budgetBytes: 64 << 20)
        for i in 0..<3 {
            let image = try Fixtures.writeImage(
                to: tree.root.appendingPathComponent("img\(i).jpg"), seed: i)
            _ = try await cache.thumbnail(for: image, mtime: Double(1000 + i), size: 128)
        }
        try await cache.evictIfNeeded()
        #expect(try await cache.cachedCount() == 3)
    }

    @Test func countingAnUncreatedCacheDirectoryReportsZero() async throws {
        let cache = ThumbnailCache(directory: cacheDirectory)
        #expect(try await cache.cachedCount() == 0)
        // Eviction over a directory that was never created must not throw.
        try await cache.evictIfNeeded()
    }

    @Test func cacheKeysDifferOnEveryComponentAndAreUnambiguous() {
        let key = ThumbnailCache.cacheKey(path: "/a.jpg", mtime: 1000, size: 256)
        #expect(key.count == 64)
        #expect(key.allSatisfy { $0.isHexDigit })
        #expect(key == ThumbnailCache.cacheKey(path: "/a.jpg", mtime: 1000, size: 256))
        #expect(key != ThumbnailCache.cacheKey(path: "/b.jpg", mtime: 1000, size: 256))
        #expect(key != ThumbnailCache.cacheKey(path: "/a.jpg", mtime: 1001, size: 256))
        #expect(key != ThumbnailCache.cacheKey(path: "/a.jpg", mtime: 1000, size: 512))
        // Field boundaries must be unambiguous, or a path ending in the next
        // field's digits would collide with a different path/mtime pair.
        #expect(ThumbnailCache.cacheKey(path: "/a", mtime: 12, size: 3)
                != ThumbnailCache.cacheKey(path: "/a1", mtime: 2, size: 3))
    }
}

private extension Result where Failure == any Error {
    /// `Result(catching:)` has no async form; this supplies one so a task group
    /// can collect failures without unwinding the whole group.
    init(catching body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
