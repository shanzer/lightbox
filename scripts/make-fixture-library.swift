// Generates a synthetic library for performance measurement.
// Usage: swift scripts/make-fixture-library.swift <output-dir> <count>
//
// The images are synthetic, but not flat: a flat-filled JPEG compresses to a
// few kilobytes and decodes almost for free, which would make every downstream
// number — file size, QuickLook thumbnail cost, scroll smoothness — optimistic
// by an order of magnitude. Each image therefore gets a deterministic block
// mosaic, which lands 12 MP frames in the few-hundred-kilobyte range: still
// smaller than a real photo, but within the same order of magnitude rather
// than three below it.
//
// Generation is parallel because it is pure per-image work and 50,000 serial
// encodes is half an hour of wall clock that measures nothing. `concurrentPerform`
// bounds itself to the machine's cores, and the process is short-lived.
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3, let count = Int(arguments[2]) else {
    print("usage: make-fixture-library.swift <output-dir> <count>")
    exit(1)
}
let root = URL(fileURLWithPath: arguments[1])

// Varied dimensions and dates, so search and sort are exercised too, and
// nested folders so the recursive walk is realistic rather than one flat list.
let sizes = [(640, 480), (1920, 1080), (4032, 3024), (200, 200), (3000, 2000)]

// Create every folder up front: `createDirectory` from many threads at once is
// a race the workers should not have to think about.
for month in 1...12 {
    let folder = root.appendingPathComponent("2019/\(String(format: "%02d", month))", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
}

func makeImage(index: Int) {
    let folder = root.appendingPathComponent("2019/\(String(format: "%02d", index % 12 + 1))",
                                             isDirectory: true)
    let (width, height) = sizes[index % sizes.count]

    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    context.setFillColor(red: Double(index % 255) / 255.0, green: 0.4, blue: 0.7, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(red: 0.1, green: Double((index * 7) % 255) / 255.0, blue: 0.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))

    // Deterministic block mosaic: a cheap stand-in for photographic detail, so
    // the JPEG has something to spend bits on.
    // `bitPattern:`, not `UInt64(_:)` — the multiply is deliberately allowed to
    // wrap, so the intermediate is negative for most indices.
    var state = UInt64(bitPattern: Int64(index) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407)
    func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state % 1000) / 1000.0
    }
    let blocks = 40
    let blockWidth = max(1, width / blocks), blockHeight = max(1, height / blocks)
    for row in 0..<blocks {
        for column in 0..<blocks {
            context.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
            context.fill(CGRect(x: column * blockWidth, y: row * blockHeight,
                                width: blockWidth, height: blockHeight))
        }
    }

    let url = folder.appendingPathComponent("img\(index).jpg")
    guard let cgImage = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { return }
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.6,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2019:\(String(format: "%02d", index % 12 + 1)):15 12:00:00",
        ] as [CFString: Any],
    ]
    CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
    _ = CGImageDestinationFinalize(destination)
}

// One chunk per worker slot, so progress prints stay coarse and ordered enough
// to read while the run is in flight.
let chunkSize = 500
let chunks = (count + chunkSize - 1) / chunkSize
let done = NSLock()
nonisolated(unsafe) var finished = 0
let start = Date()

DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
    let lower = chunk * chunkSize
    let upper = min(count, lower + chunkSize)
    for index in lower..<upper { makeImage(index: index) }
    done.lock()
    finished += upper - lower
    let tally = finished
    done.unlock()
    if tally % 5000 < chunkSize {
        print(String(format: "%d/%d  %.0fs", tally, count, Date().timeIntervalSince(start)))
        fflush(stdout)
    }
}
print("done: \(count) images in \(root.path) in \(String(format: "%.0fs", Date().timeIntervalSince(start)))")
