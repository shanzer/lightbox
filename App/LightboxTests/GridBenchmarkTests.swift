import Testing
import Foundation
import AppKit
import SwiftUI
import LightboxCore
@testable import Lightbox

/// The half of the Task 18 measurement that lives above `Core`: what
/// `LazyVGrid` costs when it is handed 50,000 records.
///
/// Disabled unless `LIGHTBOX_BENCH=1`, for the same reason as the `Core`
/// benchmarks — see `docs/superpowers/notes/2026-09-05-grid-measurement.md`.
///
/// **What this does and does not measure.** It hosts the real `PhotoGridView`
/// in a real window and forces a real layout, then walks the scroll offset down
/// the whole content height, timing each step. That is the grid's structural
/// cost: `ForEach` identity over 50,000 elements, cell realisation, and layout.
/// It is *not* a frame time — nothing here presents to a display, and the
/// thumbnails resolve asynchronously so the cells are mostly placeholders. A
/// step that takes longer than 16.7 ms could not have been a 60 Hz frame, so
/// the numbers are a lower bound on frame cost and an upper bound on how well
/// the grid does. Real frame times need the `--measure-frames` overlay and a
/// human scrolling, which is recorded in the note.
private let benchmarksEnabled = ProcessInfo.processInfo.environment["LIGHTBOX_BENCH"] == "1"

private let benchmarkRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("lightbox-bench")

/// Records for every image under `benchmarkRoot`, built straight from the
/// filesystem.
///
/// Deliberately not indexed first: the grid does not care where its rows came
/// from, and paying three minutes of tier 0 per run would only measure the
/// indexer again.
private func fixtureRecords(limit: Int) -> [FileRecord] {
    guard let enumerator = FileManager.default.enumerator(
        at: benchmarkRoot, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
    else { return [] }

    var records: [FileRecord] = []
    records.reserveCapacity(limit)
    for case let url as URL in enumerator where url.pathExtension == "jpg" {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let index = Int64(records.count)
        records.append(FileRecord(
            id: index + 1, path: url.path, parentDir: url.deletingLastPathComponent().path,
            name: url.lastPathComponent, ext: "jpg",
            size: Int64(values?.fileSize ?? 0),
            mtime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
            device: 1, inode: index + 1, width: nil, height: nil,
            captureTime: nil, captureOffset: nil, cameraMake: nil, cameraModel: nil,
            orientation: nil, contentHash: nil, imageHash: nil, imageHashKind: nil,
            phash: nil, hashedAt: nil, indexedAt: 0))
        if records.count == limit { break }
    }
    return records
}

/// The `NSScrollView` backing a hosted SwiftUI `ScrollView`, if there is one.
///
/// Found by search rather than asserted, because it is an implementation
/// detail of SwiftUI: if a future macOS stops backing `ScrollView` this way the
/// benchmark must report that it could not scroll, not fail as though the grid
/// were broken.
@MainActor
private func findScrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView { return scrollView }
    for subview in view.subviews {
        if let found = findScrollView(in: subview) { return found }
    }
    return nil
}

@MainActor
struct GridBenchmarkTests {
    @Test(.disabled(if: !benchmarksEnabled, "benchmark: set LIGHTBOX_BENCH=1 to run"))
    func measureGridAtFiftyThousandRecords() async throws {
        try #require(FileManager.default.fileExists(atPath: benchmarkRoot.path),
                     "run scripts/make-fixture-library.swift first")

        let buildStart = Date()
        let records = fixtureRecords(limit: 50_000)
        let order = records.compactMap(\.id)
        let buildSeconds = Date().timeIntervalSince(buildStart)
        try #require(records.count == 50_000)

        let cacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lightbox-grid-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ThumbnailCache(directory: cacheDirectory)

        var selection = SelectionModel()
        let binding = Binding(get: { selection }, set: { selection = $0 })
        let grid = PhotoGridView(records: records, order: order, cache: cache,
                                 selection: binding, thumbnailSide: 128)

        // A window the size of a real one, so the number of realised cells per
        // screen is the number a user would have.
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: grid)
        hosting.frame = frame
        window.contentView = hosting
        window.orderBack(nil)

        let firstLayoutStart = Date()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let firstLayoutSeconds = Date().timeIntervalSince(firstLayoutStart)

        guard let scrollView = findScrollView(in: hosting) else {
            print("no NSScrollView found; scroll cost not measured")
            print(String(format: "records built: %.2fs   first layout: %.3fs",
                         buildSeconds, firstLayoutSeconds))
            return
        }

        // Step by roughly one row at a time down the whole document, which is
        // the worst case for cell realisation: every step brings a new row in.
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let step: CGFloat = 152          // 128 pt cell + 12 pt spacing, plus label
        var offset: CGFloat = 0
        var stepSeconds: [Double] = []
        let scrollStart = Date()
        while offset + frame.height < documentHeight {
            offset += step
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            let start = Date()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            stepSeconds.append(Date().timeIntervalSince(start))
            // Yield periodically so the cells' thumbnail tasks actually run.
            // Without this the loop never suspends, no thumbnail is ever
            // loaded, and the memory figure would describe an empty grid. The
            // pause is outside the timed section, so it does not flatter the
            // step times.
            if stepSeconds.count % 100 == 0 { try await Task.sleep(for: .milliseconds(50)) }
            // Bounded two ways: 3,000 steps is several screens' worth at every
            // depth of the document, and the wall-clock cap keeps a pathological
            // result from turning the benchmark into an unbounded run.
            if stepSeconds.count >= 3_000 || Date().timeIntervalSince(scrollStart) > 180 { break }
        }

        let sorted = stepSeconds.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2] * 1000
        let p99 = sorted.isEmpty ? 0
            : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))] * 1000
        let worst = (sorted.last ?? 0) * 1000

        print("records:        \(records.count)")
        print(String(format: "records built:  %.2fs", buildSeconds))
        print(String(format: "document:       %.0f pt", documentHeight))
        print(String(format: "first layout:   %.3fs", firstLayoutSeconds))
        print("scroll steps:   \(stepSeconds.count)")
        print(String(format: "step median:    %.2f ms", median))
        print(String(format: "step p99:       %.2f ms", p99))
        print(String(format: "step max:       %.2f ms", worst))
        print(String(format: "peak rss:       %.0f MB",
                     Double(Benchmark.peakResidentBytes()) / 1_048_576))

        window.contentView = nil
    }
}
