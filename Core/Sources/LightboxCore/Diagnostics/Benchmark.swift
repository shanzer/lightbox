import Foundation
import Darwin

/// Timings for one indexing pass, for the phase 1 performance measurement.
///
/// Every field is a stage a user actually waits on, which is why there are
/// more of them than "how long does indexing take". A folder open is two
/// separate waits — the query that fills the grid, and the rescan that finds
/// what changed — and they have very different costs on a cold index than on
/// a warm one. Reporting only the cold total would hide the number the 1.5 s
/// folder-open threshold is actually about.
public struct BenchmarkResult: Sendable {
    /// Images the walk found, which is the count the thresholds are stated per.
    public let fileCount: Int
    /// Rows the index ended up holding. Equal to `fileCount` unless something
    /// was skipped, in which case the difference is the interesting part.
    public let rowCount: Int
    public let walkSeconds: Double
    /// Cold: an empty database, so every file is read and inserted.
    public let tier0Seconds: Double
    /// Warm: the same tree rescanned with nothing changed, so every file is
    /// walked, stat-compared, and skipped. This is what re-opening an already
    /// indexed folder costs.
    public let rescanSeconds: Double
    /// `width >= 1920` across the whole tree.
    public let querySeconds: Double
    /// Every row in the tree, sorted by name — what the grid asks for when a
    /// folder is opened with subfolders included.
    public let fullFolderQuerySeconds: Double
    /// High-water mark of the benchmark process's resident size, from
    /// `MACH_TASK_BASIC_INFO`. Covers indexing only: the grid's memory is a
    /// property of the app process, not this one.
    public let peakResidentBytes: UInt64
}

public enum Benchmark {
    /// Indexes `root` from an empty database and reports how long each stage
    /// took. Uses a temporary index so a run never disturbs the real one.
    public static func indexingPass(root: URL) async throws -> BenchmarkResult {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lightbox-bench-\(UUID().uuidString)/index.sqlite")
        defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }

        let store = try IndexStore(url: temporary)
        let coordinator = IndexCoordinator(store: store)

        var entries = 0
        let walkStart = Date()
        Walker().scan(root: root, options: WalkOptions(includeSubdirectories: true)) { event in
            if case .entry = event { entries += 1 }
        }
        let walkSeconds = Date().timeIntervalSince(walkStart)

        let indexStart = Date()
        _ = try await coordinator.indexTier0(root: root, recursive: true, onProgress: nil)
        let tier0Seconds = Date().timeIntervalSince(indexStart)

        let queryStart = Date()
        _ = try store.search(SearchQuery(scope: .folder(path: root.path, recursive: true),
                                         predicate: .width(.atLeast(1920))))
        let querySeconds = Date().timeIntervalSince(queryStart)

        let fullStart = Date()
        let rows = try store.search(SearchQuery(scope: .folder(path: root.path, recursive: true)))
        let fullFolderQuerySeconds = Date().timeIntervalSince(fullStart)

        // Second pass over an unchanged tree, measured last so it cannot warm
        // the caches the cold number is supposed to pay for.
        let rescanStart = Date()
        _ = try await coordinator.indexTier0(root: root, recursive: true, onProgress: nil)
        let rescanSeconds = Date().timeIntervalSince(rescanStart)

        return BenchmarkResult(fileCount: entries, rowCount: rows.count,
                               walkSeconds: walkSeconds, tier0Seconds: tier0Seconds,
                               rescanSeconds: rescanSeconds, querySeconds: querySeconds,
                               fullFolderQuerySeconds: fullFolderQuerySeconds,
                               peakResidentBytes: peakResidentBytes())
    }

    /// The current process's peak resident size in bytes, or 0 if the kernel
    /// declines to say.
    ///
    /// `resident_size_max` rather than `resident_size`: the question is whether
    /// anything ever held two gigabytes, not whether it still does when the
    /// measurement happens to be taken.
    public static func peakResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
                                           / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size_max : 0
    }
}
