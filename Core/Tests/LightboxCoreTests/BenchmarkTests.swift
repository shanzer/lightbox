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
/// The duplicate-grouping benchmarks additionally require `-c release`; see
/// `isDebugBuild` below for why. They skip visibly without it.
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

// MARK: - Duplicate grouping

/// A deterministic 64-bit stream, so every run of the scaling measurement
/// below compares the same hashes and a change in the number is a change in
/// the code rather than in the data.
private struct Xorshift64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        // Split into named steps: Swift 6.3.3 times out type-checking dense
        // bit expressions written as one line.
        var x = state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        state = x
        return x
    }

    mutating func hex16() -> String { String(format: "%016llx", next()) }
    mutating func hex64() -> String { (0..<4).map { _ in hex16() }.joined() }
}

/// `rows` synthetic index rows: unique hashes throughout, plus a planted
/// exact group every hundred rows and one planted near-duplicate cluster.
///
/// Synthetic on purpose, and its limits are worth stating. Real perceptual
/// hashes of one person's photographs are not uniform over 64 bits — a library
/// full of one scene clusters, and clustering is what makes the near tier's
/// *result* large, though not what makes its *scan* slow. The scan is
/// unconditionally `n(n-1)/2` XOR + popcount whatever the data, so uniform
/// hashes measure the thing the ceiling is chosen against exactly; what they
/// under-state is the cost of assembling a large match set afterwards.
private func syntheticDuplicateStore(rows: Int, seed: UInt64 = 20_260_907) throws -> IndexStore {
    let store = try IndexStore.inMemory()
    var random = Xorshift64(seed: seed)

    // One cluster of twenty hashes within 12 bits of a base, so the near tier
    // has something real to find and to assemble.
    let clusterBase = random.next()
    var clusterMembers: [Int: UInt64] = [:]
    for member in 0..<20 {
        var bits = clusterBase
        for flip in 0..<(member % 12) { bits ^= UInt64(1) << UInt64(flip) }
        clusterMembers[member * (max(rows, 40) / 40)] = bits
    }

    var statements: [String] = []
    func flush() throws {
        guard !statements.isEmpty else { return }
        try store.testExecute(sql: "BEGIN;\n" + statements.joined(separator: "\n") + "\nCOMMIT;")
        statements.removeAll(keepingCapacity: true)
    }

    var previousImageHash = random.hex64()
    for i in 0..<rows {
        let content = random.hex64()
        // Every hundredth row repeats its predecessor's image hash: an exact
        // group of two, with a different content hash, which is the
        // metadata-edit shape the exact tier exists for.
        let image = i % 100 == 0 && i > 0 ? previousImageHash : random.hex64()
        if i % 100 != 0 { previousImageHash = image }
        let phash = clusterMembers[i].map { String(format: "%016llx", $0) } ?? random.hex16()
        // Every value here is generated above; nothing comes from outside.
        statements.append("""
            INSERT INTO files (path, parent_dir, name, ext, size, mtime, device, inode,
                               width, height, content_hash, image_hash, image_hash_kind,
                               phash, hashed_at, indexed_at)
            VALUES ('/synthetic/\(i).jpg', '/synthetic', '\(i).jpg', 'jpg', 1000, 1.0, 1, \(i + 1),
                    1920, 1080, '\(content)', '\(image)', 'jpeg-scan-v1', '\(phash)', 2.0, 1.0);
            """)
        if statements.count == 500 { try flush() }
    }
    try flush()
    return store
}

/// True when this bundle was built without optimization.
///
/// The near tier is a tight scalar loop, so the two build configurations are
/// not within a factor of each other: measured 4.0 s against 0.06 s for the
/// same 10,000 rows, a ratio of about 85. A timing assertion evaluated in a
/// debug build would be measuring bounds checks, and a *threshold* chosen from
/// one would be wrong by nearly two orders of magnitude — so the timed
/// benchmarks below refuse to run in one rather than reporting a number
/// somebody might act on. It also keeps the documented
/// `LIGHTBOX_BENCH=1 swift test --filter Benchmark` invocation to a visible
/// skip instead of a 40-minute debug-build scan.
private let isDebugBuild: Bool = {
    var debug = false
    assert({ debug = true; return true }())
    return debug
}()

private let releaseBenchmarkReason: Comment =
    "benchmark: set LIGHTBOX_BENCH=1 and run `swift test -c release`"

/// Whether the 50k fixture library is on this machine.
///
/// Consulted as a `.disabled(if:)` trait rather than a `#require` inside the
/// test body: `#require(fileExists)` *fails* the test, it does not skip it, so
/// a missing library reads as a broken build rather than as absent local data.
/// Same path `benchmarkRoot` gives the code under test.
private let benchmarkLibraryPresent =
    FileManager.default.fileExists(atPath: benchmarkRoot.path)

private let missingLibraryReason: Comment =
    "benchmark: run scripts/make-fixture-library.swift ~/lightbox-bench 50000 first"

/// How the two duplicate tiers scale, and the measurement
/// `DuplicateFinder.nearTierCeiling` is chosen from.
///
/// Synthetic rather than over `~/lightbox-bench`: the near tier compares every
/// pair of 64-bit hashes whatever the pictures were, so its cost is a function
/// of the row count alone and can be measured without the 14 GB of JPEGs — and
/// it needs sizes the fixture library does not have. What synthetic rows do
/// *not* stand in for is either tier over real hashes, which is why
/// `measureDuplicateGroupingOverTheFixtureLibrary` below still exists and is
/// still owed. Numbers recorded in
/// `docs/superpowers/notes/2026-09-07-duplicate-grouping.md`.
@Test(.disabled(if: !benchmarksEnabled || isDebugBuild, releaseBenchmarkReason))
func measureDuplicateGroupingScaling() throws {
    for rows in [10_000, 25_000, 50_000, 100_000, 200_000] {
        let store = try syntheticDuplicateStore(rows: rows)
        // The ceiling is lifted so the largest sizes report the cost the
        // ceiling exists to refuse, rather than reporting the refusal.
        let result = try Benchmark.duplicateGrouping(in: store,
                                                     query: SearchQuery(scope: .everywhere),
                                                     nearTierCeiling: Int.max)
        print(String(format: "rows %7d  exact %6.3fs (%d groups)  near %6.3fs (%d groups)",
                     result.scopeRows, result.exactSeconds, result.exactGroups,
                     result.nearSeconds, result.nearGroups))
        #expect(result.perceptualRows == rows)
        // The planted exact groups, so a run that measured an empty store
        // cannot report a fast time and pass.
        #expect(result.exactGroups == rows / 100 - 1)
        // The issue's budgets, at and inside the ceiling.
        if rows <= 100_000 {
            #expect(result.exactSeconds < 0.5)
            #expect(result.nearSeconds < 5.0)
        }
    }
}

/// The real thing: duplicate grouping over the 50,000-image fixture library,
/// against the issue's budgets of 500 ms for the exact tier and 5 s for the
/// near tier.
///
/// Costs a full tier 0 and tier 1 pass over 14 GB first, because the tiers can
/// only be measured on rows that have real hashes in them.
///
/// Release-only for the same reason as the scaling run above: the budgets are
/// about the shipped app.
@Test(.disabled(if: !benchmarksEnabled || isDebugBuild, releaseBenchmarkReason),
      .disabled(if: !benchmarkLibraryPresent, missingLibraryReason))
func measureDuplicateGroupingOverTheFixtureLibrary() async throws {
    let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lightbox-bench-dupes-\(UUID().uuidString)/index.sqlite")
    defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }

    let store = try IndexStore(url: temporary)
    let coordinator = IndexCoordinator(store: store)
    _ = try await coordinator.indexTier0(root: benchmarkRoot, recursive: true, onProgress: nil)
    let hashing = try await coordinator.runHashingPass(root: benchmarkRoot, onProgress: nil)
    print("hashed:       \(hashing.completed) (\(hashing.failed) failed)")

    let query = SearchQuery(scope: .folder(path: benchmarkRoot.path, recursive: true))
    let result = try Benchmark.duplicateGrouping(in: store, query: query)
    print("rows:         \(result.scopeRows)")
    print("with phash:   \(result.perceptualRows)")
    print(String(format: "exact tier:   %.3fs (%d groups)", result.exactSeconds, result.exactGroups))
    print(String(format: "near tier:    %.3fs (%d groups)", result.nearSeconds, result.nearGroups))

    #expect(result.nearTierSkipped == nil)
    #expect(result.exactSeconds < 0.5)
    #expect(result.nearSeconds < 5.0)
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
