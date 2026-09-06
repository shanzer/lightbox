import Testing
import Foundation
@testable import LightboxCore

/// The phase 1 performance measurement.
///
/// Disabled unless `LIGHTBOX_BENCH=1` is in the environment, so a normal
/// `swift test` never spends minutes here, and so re-running the measurement on
/// different hardware is a matter of setting a variable rather than editing the
/// traits and remembering to put them back:
///
/// ```
/// swift scripts/make-fixture-library.swift ~/lightbox-bench 50000
/// cd Core && LIGHTBOX_BENCH=1 swift test --filter Benchmark --no-parallel
/// ```
///
/// See `docs/superpowers/notes/2026-09-05-grid-measurement.md` for the
/// thresholds these numbers are judged against, and for the numbers themselves.
private let benchmarksEnabled = ProcessInfo.processInfo.environment["LIGHTBOX_BENCH"] == "1"

private let benchmarkRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("lightbox-bench")

@Test(.disabled(if: !benchmarksEnabled, "benchmark: set LIGHTBOX_BENCH=1 to run"))
func measureIndexingOfFiftyThousandImages() async throws {
    try #require(FileManager.default.fileExists(atPath: benchmarkRoot.path),
                 "run scripts/make-fixture-library.swift first")

    let result = try await Benchmark.indexingPass(root: benchmarkRoot)
    print("files:        \(result.fileCount)")
    print("rows:         \(result.rowCount)")
    print(String(format: "walk:         %.2fs", result.walkSeconds))
    print(String(format: "tier 0 cold:  %.2fs", result.tier0Seconds))
    print(String(format: "rescan warm:  %.2fs", result.rescanSeconds))
    print(String(format: "query w>=1920:%.3fs", result.querySeconds))
    print(String(format: "query all:    %.3fs", result.fullFolderQuerySeconds))
    print(String(format: "peak rss:     %.0f MB",
                 Double(result.peakResidentBytes) / 1_048_576))

    #expect(result.fileCount == 50_000)
    #expect(result.querySeconds < 0.1)
}

/// What "folder open to first thumbnails visible" costs below the view layer.
///
/// A screenful is taken as 40 cells requested at once, which is what the grid
/// does: `ThumbnailCell` starts its `.task` per visible cell, so the first
/// screenful is a burst of concurrent QuickLook renders rather than a serial
/// loop. The number this reports is therefore a floor for the on-screen
/// latency, not the whole of it — SwiftUI's first layout is on top, and only
/// the app can measure that.
///
/// Three batches, because one number would not say which cost is which:
/// the first screenful pays to bring up QuickLook's out-of-process generator,
/// the second is what a user scrolling into fresh images actually waits for,
/// and the third is a pure cache hit.
@Test(.disabled(if: !benchmarksEnabled, "benchmark: set LIGHTBOX_BENCH=1 to run"))
func measureFirstScreenOfThumbnails() async throws {
    try #require(FileManager.default.fileExists(atPath: benchmarkRoot.path),
                 "run scripts/make-fixture-library.swift first")

    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lightbox-bench-thumbs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try IndexStore.inMemory()
    let coordinator = IndexCoordinator(store: store)
    // One month's folder, not the whole tree: this measures thumbnail
    // generation, and indexing 50,000 files to get 80 rows would measure the
    // indexer instead.
    let folder = benchmarkRoot.appendingPathComponent("2019/01")
    _ = try await coordinator.indexTier0(root: folder, recursive: false, onProgress: nil)
    let rows = Array(try store.search(SearchQuery(scope: .folder(path: folder.path,
                                                                 recursive: false))).prefix(80))
    try #require(rows.count == 80)

    // 512 px is what a cell asks for at the default 256 pt thumbnail side on a
    // Retina display, after `ThumbnailCell`'s quantisation.
    let cache = ThumbnailCache(directory: directory)

    /// One screenful, requested the way the grid requests one: all at once.
    func screenful(_ batch: ArraySlice<FileRecord>) async throws -> Double {
        let start = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for row in batch {
                group.addTask {
                    _ = try await cache.thumbnail(for: URL(fileURLWithPath: row.path),
                                                  mtime: row.mtime, size: 512)
                }
            }
            try await group.waitForAll()
        }
        return Date().timeIntervalSince(start)
    }

    let firstScreen = try await screenful(rows[0..<40])
    let secondScreen = try await screenful(rows[40..<80])
    let cached = try await screenful(rows[0..<40])

    print(String(format: "screen 1 (QuickLook cold): %.3fs", firstScreen))
    print(String(format: "screen 2 (steady state):   %.3fs", secondScreen))
    print(String(format: "screen 1 again (cached):   %.3fs", cached))
}
