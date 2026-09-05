# Lightbox Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS app that browses any directory tree as a thumbnail grid, optionally recursively, and searches it by structural metadata — with every file indexed, hashed three ways, and stored in a persistent SQLite index.

**Architecture:** All logic lives in a Swift package, `Core/`, built and tested headless with `swift test`. A thin Xcode app target consumes it. The indexer is a two-tier pipeline: tier 0 (stat, ImageIO metadata, thumbnail, perceptual hash) runs on folder open; tier 1 (SHA-256 content and image-data hashes) is an explicitly started, resumable background pass. Search is a `SearchQuery` value type compiled to parameterized SQL.

**Tech Stack:** Swift 6.3, SwiftUI, GRDB 7.11.1 (SQLite + FTS5), CryptoKit, ImageIO, QuickLookThumbnailing, swift-testing.

**Spec:** `docs/superpowers/specs/2026-09-05-lightbox-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- `swift-tools-version: 6.2` in `Package.swift`. **This is required, not stylistic:** `.macOS(.v26)` is unavailable under tools-version 6.0, which fails the manifest with `'v26' is unavailable`.
- Platform floor: `.macOS(.v26)`. Swift 6 language mode, strict concurrency.
- Target architecture is arm64. Development happens on the M4 Mac mini. Intel is not a support target.
- GRDB pinned `.upToNextMajor(from: "7.11.1")`, product `GRDB` from package `GRDB.swift`.
- Tests use `import Testing` (swift-testing), never XCTest. Tests make no network calls.
- Hashes are SHA-256 via CryptoKit, rendered lowercase hex. No MD5, and no byte-for-byte re-comparison — that ritual exists in `photolib` only to compensate for MD5 being collision-broken.
- Perceptual hash identifier is exactly `phash-dct-64-nodc`, 32x32 grid, Rec. 709 weights.
- `image_hash_kind` values are exactly `jpeg-scan-v1`, `png-idat-v1`, `webp-chunk-v1`, or NULL.
- Index lives at `~/Library/Application Support/Lightbox/index.sqlite`.
- The type is named `FileHasher`, never `Hasher` — `Hasher` collides with the Swift standard library.
- Commit at the end of every task. Never commit a red test.

## Out of scope for phase 1

These belong to later phases and must not be built here: `FileOperator` and the undo journal, `MetadataWriter` and EXIF editing, the duplicate-detection view, the FSEvents watcher, pause-and-resume on volume unmount, `VisionAnalyzer`, `EmbeddingAnalyzer`, OCR, and semantic search. Phase 1 handles an unmounted volume only to the extent that `Walker` reports the directory unreadable and the pass continues instead of crashing. Phase 1 creates the `analysis`, `saved_searches`, and `op_journal` tables in migration v1 so later phases need no migration, but writes to none of them.

## File Structure

```
lightbox/
  Core/
    Package.swift
    Sources/LightboxCore/
      MediaType.swift             supported extensions, format families
      Walker.swift                directory enumeration
      Index/
        FileRecord.swift          the row type
        IndexStore.swift          GRDB wrapper: migrations, upsert, staleness, search
      Metadata/
        ImageMetadata.swift       value type
        MetadataReader.swift      ImageIO reads
      Hashing/
        ContentHasher.swift       streaming SHA-256 of whole file
        JPEGImageHash.swift       segment scanner + denylist
        PNGImageHash.swift        chunk scanner + denylist
        WebPImageHash.swift       chunk scanner + allowlist
        FileHasher.swift          facade: both hashes in one mapped read
        GrayscaleRenderer.swift   32x32 Rec.709 luminance grid
        PerceptualHash.swift      DCT-II phash, ported from photolib
      Thumbnails/
        ThumbnailCache.swift      QuickLook + disk cache + LRU
      Search/
        SearchQuery.swift         predicate model, Codable
        FTS5Query.swift           tokenizer and quoter for user text
        QueryCompiler.swift       SearchQuery -> SQL + arguments
      Coordinator/
        IndexProgress.swift       progress value type
        IndexCoordinator.swift    tier 0 and tier 1 pipelines
    Tests/LightboxCoreTests/
      Support/Fixtures.swift      generates JPEG/PNG/HEIC/TIFF fixtures with ImageIO
      Support/TempTree.swift      builds and tears down temp directory trees
      Fixtures/simple.webp        checked-in binary; ImageIO cannot write WebP
      (one test file per source file, same base name)
  App/
    Lightbox.xcodeproj
    Lightbox/                     file-system-synchronized group
      LightboxApp.swift
      BrowserModel.swift
      Views/BrowserView.swift
      Views/FolderTreeView.swift
      Views/PathBarView.swift
      Views/PhotoGridView.swift
      Views/ThumbnailCell.swift
      Views/FilterPanelView.swift
      Views/InspectorView.swift
  docs/superpowers/{specs,plans}/
```

Files that change together live together. `Hashing/` holds six small focused files rather than one large `Hasher.swift`, because each format parser is independently reviewable and independently wrong.

---

### Task 1: Package scaffolding

**Files:**
- Create: `Core/Package.swift`
- Create: `Core/Sources/LightboxCore/LightboxCore.swift`
- Test: `Core/Tests/LightboxCoreTests/SmokeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a buildable `LightboxCore` library target and a runnable `swift test` harness. Every later task adds files under `Core/Sources/LightboxCore/` and `Core/Tests/LightboxCoreTests/`.

- [ ] **Step 1: Write the failing test**

`Core/Tests/LightboxCoreTests/SmokeTests.swift`:

```swift
import Testing
import Foundation
import GRDB
@testable import LightboxCore

@Test func packageBuildsAndFTS5IsAvailable() throws {
    let dbq = try DatabaseQueue()
    try dbq.write { db in
        try db.execute(sql: "CREATE VIRTUAL TABLE probe USING fts5(body)")
        try db.execute(sql: "INSERT INTO probe (body) VALUES (?)", arguments: ["quarterly invoice"])
    }
    let hits = try dbq.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM probe WHERE probe MATCH ?", arguments: ["invoice"])
    }
    #expect(hits == 1)
    #expect(LightboxCore.version == "0.1.0")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test`
Expected: FAIL — no `Package.swift` yet, so the build cannot even start.

- [ ] **Step 3: Write the package manifest and the minimal source**

`Core/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LightboxCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LightboxCore", targets: ["LightboxCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.11.1"))
    ],
    targets: [
        .target(
            name: "LightboxCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "LightboxCoreTests",
            dependencies: ["LightboxCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

`Core/Sources/LightboxCore/LightboxCore.swift`:

```swift
/// Namespace for package-wide constants.
public enum LightboxCore {
    public static let version = "0.1.0"
}
```

Create `Core/Tests/LightboxCoreTests/Fixtures/.gitkeep` so the declared resource directory exists. Task 9 replaces it with `simple.webp`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Core && swift test`
Expected: PASS. Confirm `Package.resolved` pins `grdb.swift` at `7.11.1` or later 7.x.

- [ ] **Step 5: Commit**

```bash
git add Core docs
git commit -m "feat: scaffold LightboxCore package with GRDB and swift-testing"
```

---

### Task 2: MediaType

**Files:**
- Create: `Core/Sources/LightboxCore/MediaType.swift`
- Test: `Core/Tests/LightboxCoreTests/MediaTypeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum MediaKind: String, Sendable, Codable, CaseIterable { case jpeg, png, webp, gif, heic, tiff, raw, psd }`
  - `public struct MediaType: Sendable, Hashable { public let kind: MediaKind; public let ext: String }`
  - `public static func MediaType.forExtension(_ ext: String) -> MediaType?`
  - `public var MediaType.imageHashKind: String?` — the `image_hash_kind` string, or nil when unsupported.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import LightboxCore

@Test func recognizesExtensionsCaseInsensitively() {
    #expect(MediaType.forExtension("JPG")?.kind == .jpeg)
    #expect(MediaType.forExtension("jpeg")?.kind == .jpeg)
    #expect(MediaType.forExtension(".PNG")?.kind == .png)
    #expect(MediaType.forExtension("HEIC")?.kind == .heic)
    #expect(MediaType.forExtension("cr2")?.kind == .raw)
    #expect(MediaType.forExtension("nef")?.kind == .raw)
    #expect(MediaType.forExtension("arw")?.kind == .raw)
    #expect(MediaType.forExtension("dng")?.kind == .raw)
}

@Test func rejectsUnsupportedExtensions() {
    #expect(MediaType.forExtension("txt") == nil)
    #expect(MediaType.forExtension("") == nil)
    #expect(MediaType.forExtension("mov") == nil)   // video is out of scope
}

@Test func reportsImageHashSupportPerFormat() {
    #expect(MediaType.forExtension("jpg")?.imageHashKind == "jpeg-scan-v1")
    #expect(MediaType.forExtension("png")?.imageHashKind == "png-idat-v1")
    #expect(MediaType.forExtension("webp")?.imageHashKind == "webp-chunk-v1")
    // NULL in v1: see the spec's hashing section for why each is excluded.
    #expect(MediaType.forExtension("gif")?.imageHashKind == nil)
    #expect(MediaType.forExtension("heic")?.imageHashKind == nil)
    #expect(MediaType.forExtension("tif")?.imageHashKind == nil)
    #expect(MediaType.forExtension("cr2")?.imageHashKind == nil)
    #expect(MediaType.forExtension("psd")?.imageHashKind == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter MediaType`
Expected: FAIL — `cannot find 'MediaType' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

public enum MediaKind: String, Sendable, Codable, CaseIterable {
    case jpeg, png, webp, gif, heic, tiff, raw, psd
}

/// A supported still-image type, identified by file extension.
///
/// Extension-based rather than content-sniffed: the walker must decide whether
/// to index a file without opening it, and at 50k files the difference between
/// a string comparison and a read is the difference between instant and slow.
public struct MediaType: Sendable, Hashable {
    public let kind: MediaKind
    public let ext: String

    private static let table: [String: MediaKind] = [
        "jpg": .jpeg, "jpeg": .jpeg, "jpe": .jpeg,
        "png": .png,
        "webp": .webp,
        "gif": .gif,
        "heic": .heic, "heif": .heic,
        "tif": .tiff, "tiff": .tiff,
        "psd": .psd,
        "cr2": .raw, "cr3": .raw, "nef": .raw, "nrw": .raw, "arw": .raw,
        "srf": .raw, "sr2": .raw, "raf": .raw, "orf": .raw, "rw2": .raw,
        "pef": .raw, "dng": .raw, "raw": .raw, "3fr": .raw, "erf": .raw,
    ]

    public static func forExtension(_ ext: String) -> MediaType? {
        let key = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        let normalized = key.lowercased()
        guard let kind = table[normalized] else { return nil }
        return MediaType(kind: kind, ext: normalized)
    }

    /// The `image_hash_kind` recorded alongside a computed image hash, or nil
    /// when this format has no stable image-data hash in version 1.
    public var imageHashKind: String? {
        switch kind {
        case .jpeg: "jpeg-scan-v1"
        case .png: "png-idat-v1"
        case .webp: "webp-chunk-v1"
        case .gif, .heic, .tiff, .raw, .psd: nil
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Core && swift test --filter MediaType`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/LightboxCore/MediaType.swift Core/Tests/LightboxCoreTests/MediaTypeTests.swift
git commit -m "feat: add MediaType extension registry"
```

---

### Task 3: Walker

**Files:**
- Create: `Core/Sources/LightboxCore/Walker.swift`
- Create: `Core/Tests/LightboxCoreTests/Support/TempTree.swift`
- Test: `Core/Tests/LightboxCoreTests/WalkerTests.swift`

**Interfaces:**
- Consumes: `MediaType.forExtension(_:)` from Task 2.
- Produces:
  - `public struct WalkEntry: Sendable, Hashable { public let url: URL; public let size: Int64; public let mtime: Date; public let inode: Int64; public let mediaType: MediaType }`
  - `public enum SkipReason: String, Sendable { case unreadable, symlinkLoop }`
  - `public enum WalkEvent: Sendable { case entry(WalkEntry); case skipped(url: URL, reason: SkipReason) }`
  - `public struct WalkOptions: Sendable { public var includeSubdirectories: Bool; public var followSymlinks: Bool; public init(includeSubdirectories: Bool = true, followSymlinks: Bool = false) }`
  - `public struct Walker: Sendable { public init(); public func scan(root: URL, options: WalkOptions, onEvent: (WalkEvent) -> Void); public func stream(root: URL, options: WalkOptions) -> AsyncStream<WalkEvent> }`

`scan` is synchronous so tests need no concurrency; `stream` wraps it for the coordinator.

- [ ] **Step 1: Write the test helper**

`Core/Tests/LightboxCoreTests/Support/TempTree.swift`:

```swift
import Foundation

/// A throwaway directory tree, removed when the instance is released.
final class TempTree {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lightbox-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func file(_ relativePath: String, bytes: Int = 8) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates `link` as a symlink pointing at `target`, both relative to root.
    func symlink(_ link: String, to target: String) throws {
        let linkURL = root.appendingPathComponent(link)
        try FileManager.default.createDirectory(
            at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkURL, withDestinationURL: root.appendingPathComponent(target))
    }
}
```

- [ ] **Step 2: Write the failing test**

`Core/Tests/LightboxCoreTests/WalkerTests.swift`:

```swift
import Testing
import Foundation
@testable import LightboxCore

private func collect(_ root: URL, _ options: WalkOptions) -> (names: Set<String>, skipped: [SkipReason]) {
    var names = Set<String>()
    var skipped: [SkipReason] = []
    Walker().scan(root: root, options: options) { event in
        switch event {
        case .entry(let e): names.insert(e.url.lastPathComponent)
        case .skipped(_, let reason): skipped.append(reason)
        }
    }
    return (names, skipped)
}

@Test func findsImagesRecursivelyAndIgnoresOtherFiles() throws {
    let tree = try TempTree()
    try tree.file("a.jpg")
    try tree.file("notes.txt")
    try tree.file("sub/b.PNG")
    try tree.file("sub/deeper/c.heic")
    let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
    #expect(result.names == ["a.jpg", "b.PNG", "c.heic"])
}

@Test func honoursIncludeSubdirectoriesFalse() throws {
    let tree = try TempTree()
    try tree.file("a.jpg")
    try tree.file("sub/b.jpg")
    let result = collect(tree.root, WalkOptions(includeSubdirectories: false))
    #expect(result.names == ["a.jpg"])
}

@Test func skipsJunkAndHiddenAndAppleDouble() throws {
    let tree = try TempTree()
    try tree.file("a.jpg")
    try tree.file(".DS_Store")
    try tree.file("._a.jpg")
    try tree.file(".hidden/b.jpg")
    let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
    #expect(result.names == ["a.jpg"])
}

@Test func doesNotDescendIntoLibraryBundles() throws {
    let tree = try TempTree()
    try tree.file("a.jpg")
    try tree.file("Old.photoslibrary/resources/b.jpg")
    try tree.file("Thing.app/Contents/c.jpg")
    let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
    #expect(result.names == ["a.jpg"])
}

@Test func handlesUnusualFilenames() throws {
    let tree = try TempTree()
    try tree.file("emoji \u{1F602}.jpg")
    try tree.file("new\nline.jpg")
    try tree.file("-leading-dash.jpg")
    let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
    #expect(result.names.count == 3)
}

@Test func doesNotFollowSymlinkedDirectoriesByDefault() throws {
    let tree = try TempTree()
    try tree.file("real/a.jpg")
    try tree.symlink("link", to: "real")
    let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
    #expect(result.names == ["a.jpg"])   // seen once, through the real path only
}

@Test func detectsSymlinkLoopWhenFollowing() throws {
    let tree = try TempTree()
    try tree.file("real/a.jpg")
    try tree.symlink("real/loop", to: "real")
    let result = collect(tree.root, WalkOptions(includeSubdirectories: true, followSymlinks: true))
    #expect(result.names == ["a.jpg"])
    #expect(result.skipped.contains(.symlinkLoop))
}

@Test func reportsUnreadableDirectoryWithoutAborting() throws {
    let tree = try TempTree()
    try tree.file("a.jpg")
    let locked = try tree.directory("locked")
    try tree.file("locked/b.jpg")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    let result = collect(tree.root, WalkOptions(includeSubdirectories: true))
    #expect(result.names == ["a.jpg"])
    #expect(result.skipped.contains(.unreadable))
}

@Test func reportsSizeAndModificationTime() throws {
    let tree = try TempTree()
    try tree.file("a.jpg", bytes: 1234)
    var entries: [WalkEntry] = []
    Walker().scan(root: tree.root, options: WalkOptions()) { event in
        if case .entry(let e) = event { entries.append(e) }
    }
    #expect(entries.count == 1)
    #expect(entries[0].size == 1234)
    #expect(entries[0].inode > 0)
    #expect(abs(entries[0].mtime.timeIntervalSinceNow) < 60)
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd Core && swift test --filter Walker`
Expected: FAIL — `cannot find 'Walker' in scope`.

- [ ] **Step 4: Write the implementation**

`Core/Sources/LightboxCore/Walker.swift`:

```swift
import Foundation

public struct WalkEntry: Sendable, Hashable {
    public let url: URL
    public let size: Int64
    public let mtime: Date
    public let inode: Int64
    public let mediaType: MediaType
}

public enum SkipReason: String, Sendable, Hashable {
    case unreadable, symlinkLoop
}

public enum WalkEvent: Sendable {
    case entry(WalkEntry)
    case skipped(url: URL, reason: SkipReason)
}

public struct WalkOptions: Sendable {
    public var includeSubdirectories: Bool
    public var followSymlinks: Bool

    public init(includeSubdirectories: Bool = true, followSymlinks: Bool = false) {
        self.includeSubdirectories = includeSubdirectories
        self.followSymlinks = followSymlinks
    }
}

/// Enumerates a directory tree, emitting one event per supported image found
/// and one per directory that could not be read.
///
/// Iterative rather than recursive: a deep tree must not risk the stack, and an
/// explicit stack makes the symlink-loop guard trivial to reason about.
public struct Walker: Sendable {
    /// Directories whose contents are implementation detail of an application
    /// or library, never a user's photos. Descending into a `.photoslibrary`
    /// yields tens of thousands of derivative files and no useful originals.
    private static let opaqueBundleExtensions: Set<String> = [
        "photoslibrary", "aplibrary", "migratedaplibrary", "lrdata", "lrcat",
        "app", "bundle", "framework", "photolibrary", "pkg",
    ]

    public init() {}

    public func scan(root: URL, options: WalkOptions, onEvent: (WalkEvent) -> Void) {
        var stack: [URL] = [root]
        var visited = Set<DirectoryIdentity>()

        while let dir = stack.popLast() {
            guard let identity = DirectoryIdentity(path: dir.path, followSymlink: true) else {
                onEvent(.skipped(url: dir, reason: .unreadable))
                continue
            }
            guard visited.insert(identity).inserted else {
                onEvent(.skipped(url: dir, reason: .symlinkLoop))
                continue
            }

            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            } catch {
                onEvent(.skipped(url: dir, reason: .unreadable))
                continue
            }

            for name in names {
                if Self.isJunk(name) { continue }
                let child = dir.appendingPathComponent(name)

                var st = stat()
                guard lstat(child.path, &st) == 0 else { continue }

                if st.st_mode & S_IFMT == S_IFLNK {
                    guard options.followSymlinks else { continue }
                    var resolved = stat()
                    guard stat(child.path, &resolved) == 0 else { continue }
                    st = resolved
                }

                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    guard options.includeSubdirectories else { continue }
                    let ext = child.pathExtension.lowercased()
                    guard !Self.opaqueBundleExtensions.contains(ext) else { continue }
                    stack.append(child)
                case S_IFREG:
                    guard let mediaType = MediaType.forExtension(child.pathExtension) else { continue }
                    onEvent(.entry(WalkEntry(
                        url: child,
                        size: Int64(st.st_size),
                        mtime: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                                    + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000),
                        inode: Int64(bitPattern: UInt64(st.st_ino)),
                        mediaType: mediaType)))
                default:
                    continue
                }
            }
        }
    }

    public func stream(root: URL, options: WalkOptions = WalkOptions()) -> AsyncStream<WalkEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                scan(root: root, options: options) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Names that are never user content: Finder metadata, AppleDouble
    /// resource forks, and anything hidden.
    static func isJunk(_ name: String) -> Bool {
        name.hasPrefix(".") || name.hasPrefix("._") || name == "Icon\r"
    }
}

/// A directory's identity on disk, so a symlink cannot make the walker revisit
/// a tree it has already descended.
private struct DirectoryIdentity: Hashable {
    let device: Int64
    let inode: Int64

    init?(path: String, followSymlink: Bool) {
        var st = stat()
        let ok = followSymlink ? stat(path, &st) == 0 : lstat(path, &st) == 0
        guard ok, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        device = Int64(st.st_dev)
        inode = Int64(bitPattern: UInt64(st.st_ino))
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Core && swift test --filter Walker`
Expected: PASS, 9 tests.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/LightboxCore/Walker.swift Core/Tests/LightboxCoreTests/
git commit -m "feat: add Walker with symlink-loop, junk, and bundle handling"
```

---

### Task 4: IndexStore — schema, migrations, upsert, staleness

**Files:**
- Create: `Core/Sources/LightboxCore/Index/FileRecord.swift`
- Create: `Core/Sources/LightboxCore/Index/IndexStore.swift`
- Test: `Core/Tests/LightboxCoreTests/IndexStoreTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public struct FileRecord: Codable, Sendable, Hashable, FetchableRecord, MutablePersistableRecord` with fields `id: Int64?`, `path: String`, `parentDir: String`, `name: String`, `ext: String`, `size: Int64`, `mtime: Double`, `inode: Int64`, `width: Int?`, `height: Int?`, `captureTime: Double?`, `captureOffset: String?`, `cameraMake: String?`, `cameraModel: String?`, `orientation: Int?`, `contentHash: String?`, `imageHash: String?`, `imageHashKind: String?`, `phash: String?`, `hashedAt: Double?`, `indexedAt: Double`
  - `public final class IndexStore: Sendable` with `init(url: URL) throws`, `static func inMemory() throws -> IndexStore`, `upsert(_:) throws -> Int64`, `record(atPath:) throws -> FileRecord?`, `needsReindex(path:size:mtime:) throws -> Bool`, `setHashes(fileID:content:image:imageKind:phash:hashedAt:) throws` (`content` is optional), `filesMissingHashes(under:limit:) throws -> [FileRecord]`, `deleteRows(under:keeping:) throws -> Int`, `count() throws -> Int`
  - `public static let IndexStore.defaultURL: URL`

`upsert` preserves the row id across updates, and clears `content_hash`, `image_hash`, `image_hash_kind`, `phash`, and `hashed_at` **only** when `size` or `mtime` changed — a changed file's hashes are stale, and clearing `hashed_at` is what re-enqueues it for Task 15's pass. An unchanged file keeps hashes the tier 1 pass already paid for.

**Timestamps are stored as `Double` epoch seconds, not as GRDB's default `Date` text.** `mtime` is compared for exact equality to decide staleness, and a millisecond-rounded text timestamp would report a file stale on every scan. All timestamp columns use the same representation for consistency.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import GRDB
@testable import LightboxCore

private func sampleRecord(path: String, size: Int64 = 100, mtime: Double = 1_700_000_000) -> FileRecord {
    FileRecord(
        id: nil, path: path,
        parentDir: (path as NSString).deletingLastPathComponent,
        name: (path as NSString).lastPathComponent,
        ext: (path as NSString).pathExtension.lowercased(),
        size: size, mtime: mtime, inode: 42,
        width: 200, height: 200,
        captureTime: nil, captureOffset: nil,
        cameraMake: nil, cameraModel: nil, orientation: 1,
        contentHash: nil, imageHash: nil, imageHashKind: nil,
        phash: nil, hashedAt: nil, indexedAt: 1_700_000_000)
}

@Test func migrationCreatesEveryTable() throws {
    let store = try IndexStore.inMemory()
    let tables = try store.tableNames()
    #expect(tables.contains("files"))
    #expect(tables.contains("files_fts"))
    #expect(tables.contains("analysis"))
    #expect(tables.contains("saved_searches"))
    #expect(tables.contains("op_journal"))
}

@Test func upsertInsertsThenUpdatesKeepingTheSameRowID() throws {
    let store = try IndexStore.inMemory()
    let first = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100))
    var changed = sampleRecord(path: "/a/b.jpg", size: 999)
    changed.width = 4000
    let second = try store.upsert(changed)
    #expect(first == second)
    #expect(try store.count() == 1)
    let row = try #require(try store.record(atPath: "/a/b.jpg"))
    #expect(row.size == 999)
    #expect(row.width == 4000)
}

@Test func needsReindexTracksSizeAndModificationTime() throws {
    let store = try IndexStore.inMemory()
    _ = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000))
    #expect(try store.needsReindex(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000) == false)
    #expect(try store.needsReindex(path: "/a/b.jpg", size: 101, mtime: 1_700_000_000) == true)
    #expect(try store.needsReindex(path: "/a/b.jpg", size: 100, mtime: 1_700_000_001) == true)
    #expect(try store.needsReindex(path: "/nope.jpg", size: 100, mtime: 1_700_000_000) == true)
}

@Test func upsertMirrorsTheFilenameIntoTheSearchIndex() throws {
    let store = try IndexStore.inMemory()
    _ = try store.upsert(sampleRecord(path: "/a/holiday-invoice.jpg"))
    #expect(try store.ftsRowCount() == 1)
    _ = try store.upsert(sampleRecord(path: "/a/holiday-invoice.jpg"))
    #expect(try store.ftsRowCount() == 1)   // updated, not duplicated
}

@Test func setHashesStoresAllThreeAndTheKind() throws {
    let store = try IndexStore.inMemory()
    let id = try store.upsert(sampleRecord(path: "/a/b.jpg"))
    try store.setHashes(fileID: id, content: "aa", image: "bb", imageKind: "jpeg-scan-v1",
                        phash: "0123456789abcdef", hashedAt: 1_700_000_500)
    let row = try #require(try store.record(atPath: "/a/b.jpg"))
    #expect(row.contentHash == "aa")
    #expect(row.imageHash == "bb")
    #expect(row.imageHashKind == "jpeg-scan-v1")
    #expect(row.phash == "0123456789abcdef")
    #expect(row.hashedAt == 1_700_000_500)
}

@Test func filesMissingHashesReturnsOnlyUnhashedRowsUnderThePrefix() throws {
    let store = try IndexStore.inMemory()
    let a = try store.upsert(sampleRecord(path: "/lib/a.jpg"))
    _ = try store.upsert(sampleRecord(path: "/lib/b.jpg"))
    _ = try store.upsert(sampleRecord(path: "/other/c.jpg"))
    try store.setHashes(fileID: a, content: "aa", image: nil, imageKind: nil,
                        phash: nil, hashedAt: 1)
    let pending = try store.filesMissingHashes(under: "/lib", limit: 10)
    #expect(pending.map(\.name) == ["b.jpg"])
}

@Test func upsertClearsHashesOnlyWhenTheFileActuallyChanged() throws {
    let store = try IndexStore.inMemory()
    let id = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000))
    try store.setHashes(fileID: id, content: "cc", image: "ii", imageKind: "jpeg-scan-v1",
                        phash: "0123456789abcdef", hashedAt: 500)

    // Re-indexing an unchanged file must not throw away work the tier 1 pass
    // already paid for.
    _ = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000))
    var row = try #require(try store.record(atPath: "/a/b.jpg"))
    #expect(row.contentHash == "cc")
    #expect(row.hashedAt == 500)

    // A changed file's hashes are lies; clearing hashed_at re-enqueues it.
    _ = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 101, mtime: 1_700_000_000))
    row = try #require(try store.record(atPath: "/a/b.jpg"))
    #expect(row.contentHash == nil)
    #expect(row.imageHash == nil)
    #expect(row.imageHashKind == nil)
    #expect(row.phash == nil)
    #expect(row.hashedAt == nil)
}

@Test func deleteRowsRemovesVanishedFilesAndTheirSearchRows() throws {
    let store = try IndexStore.inMemory()
    _ = try store.upsert(sampleRecord(path: "/lib/a.jpg"))
    _ = try store.upsert(sampleRecord(path: "/lib/b.jpg"))
    _ = try store.upsert(sampleRecord(path: "/other/c.jpg"))
    let removed = try store.deleteRows(under: "/lib", keeping: ["/lib/a.jpg"])
    #expect(removed == 1)
    #expect(try store.count() == 2)          // /lib/a.jpg and /other/c.jpg
    #expect(try store.ftsRowCount() == 2)
}

@Test func migrationIsIdempotentAcrossReopens() throws {
    let tree = try TempTree()
    let url = tree.root.appendingPathComponent("index.sqlite")
    _ = try IndexStore(url: url).upsert(sampleRecord(path: "/a/b.jpg"))
    let reopened = try IndexStore(url: url)
    #expect(try reopened.count() == 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter IndexStore`
Expected: FAIL — `cannot find 'IndexStore' in scope`.

- [ ] **Step 3: Write FileRecord**

`Core/Sources/LightboxCore/Index/FileRecord.swift`:

```swift
import Foundation
import GRDB

/// One indexed image. Timestamps are epoch seconds as `Double` rather than
/// `Date`: `mtime` is compared for exact equality to decide whether a file
/// needs re-reading, and GRDB's default millisecond-rounded text timestamps
/// would report every file stale on every scan.
public struct FileRecord: Codable, Sendable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "files"

    public var id: Int64?
    public var path: String
    public var parentDir: String
    public var name: String
    public var ext: String
    public var size: Int64
    public var mtime: Double
    public var inode: Int64
    public var width: Int?
    public var height: Int?
    public var captureTime: Double?
    public var captureOffset: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var orientation: Int?
    public var contentHash: String?
    public var imageHash: String?
    public var imageHashKind: String?
    public var phash: String?
    public var hashedAt: Double?
    public var indexedAt: Double

    public enum CodingKeys: String, CodingKey {
        case id, path, name, ext, size, mtime, inode, width, height, orientation, phash
        case parentDir = "parent_dir"
        case captureTime = "capture_time"
        case captureOffset = "capture_offset"
        case cameraMake = "camera_make"
        case cameraModel = "camera_model"
        case contentHash = "content_hash"
        case imageHash = "image_hash"
        case imageHashKind = "image_hash_kind"
        case hashedAt = "hashed_at"
        case indexedAt = "indexed_at"
    }

    public var modifiedDate: Date { Date(timeIntervalSince1970: mtime) }
    public var captureDate: Date? { captureTime.map(Date.init(timeIntervalSince1970:)) }

    /// The record for a freshly walked file, before metadata or hashes are read.
    public init(entry: WalkEntry, indexedAt: Double) {
        self.id = nil
        self.path = entry.url.path
        self.parentDir = entry.url.deletingLastPathComponent().path
        self.name = entry.url.lastPathComponent
        self.ext = entry.mediaType.ext
        self.size = entry.size
        self.mtime = entry.mtime.timeIntervalSince1970
        self.inode = entry.inode
        self.indexedAt = indexedAt
    }

    public init(id: Int64?, path: String, parentDir: String, name: String, ext: String,
                size: Int64, mtime: Double, inode: Int64, width: Int?, height: Int?,
                captureTime: Double?, captureOffset: String?, cameraMake: String?,
                cameraModel: String?, orientation: Int?, contentHash: String?,
                imageHash: String?, imageHashKind: String?, phash: String?,
                hashedAt: Double?, indexedAt: Double) {
        self.id = id; self.path = path; self.parentDir = parentDir; self.name = name
        self.ext = ext; self.size = size; self.mtime = mtime; self.inode = inode
        self.width = width; self.height = height; self.captureTime = captureTime
        self.captureOffset = captureOffset; self.cameraMake = cameraMake
        self.cameraModel = cameraModel; self.orientation = orientation
        self.contentHash = contentHash; self.imageHash = imageHash
        self.imageHashKind = imageHashKind; self.phash = phash
        self.hashedAt = hashedAt; self.indexedAt = indexedAt
    }
}
```

- [ ] **Step 4: Write IndexStore**

`Core/Sources/LightboxCore/Index/IndexStore.swift`:

```swift
import Foundation
import GRDB

public final class IndexStore: Sendable {
    private let dbq: DatabaseQueue

    public static var defaultURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lightbox", isDirectory: true)
            .appendingPathComponent("index.sqlite")
    }

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbq = try DatabaseQueue(path: url.path, configuration: config)
        try Self.migrator.migrate(dbq)
    }

    private init(inMemory: Bool) throws {
        dbq = try DatabaseQueue()
        try Self.migrator.migrate(dbq)
    }

    public static func inMemory() throws -> IndexStore { try IndexStore(inMemory: true) }

    // MARK: - Schema

    private static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE files (
                    id INTEGER PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE,
                    parent_dir TEXT NOT NULL,
                    name TEXT NOT NULL,
                    ext TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    mtime REAL NOT NULL,
                    inode INTEGER NOT NULL,
                    width INTEGER,
                    height INTEGER,
                    capture_time REAL,
                    capture_offset TEXT,
                    camera_make TEXT,
                    camera_model TEXT,
                    orientation INTEGER,
                    content_hash TEXT,
                    image_hash TEXT,
                    image_hash_kind TEXT,
                    phash TEXT,
                    hashed_at REAL,
                    indexed_at REAL NOT NULL
                );
                CREATE INDEX files_on_parent_dir ON files(parent_dir);
                CREATE INDEX files_on_capture_time ON files(capture_time);
                CREATE INDEX files_on_size ON files(size);
                CREATE INDEX files_on_dimensions ON files(width, height);
                CREATE INDEX files_on_content_hash ON files(content_hash);
                CREATE INDEX files_on_image_hash ON files(image_hash);
                CREATE INDEX files_on_hashed_at ON files(hashed_at);

                CREATE VIRTUAL TABLE files_fts USING fts5(name, ocr_text);

                CREATE TABLE analysis (
                    file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                    ocr_text TEXT,
                    text_coverage REAL,
                    top_labels TEXT,
                    has_faces INTEGER,
                    feature_print BLOB,
                    clip_embedding BLOB,
                    analyzer_versions TEXT,
                    analyzed_at REAL
                );

                CREATE TABLE saved_searches (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE,
                    query TEXT NOT NULL,
                    is_builtin INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE op_journal (
                    op_id INTEGER PRIMARY KEY,
                    batch_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    src TEXT NOT NULL,
                    dst TEXT,
                    trash_url TEXT,
                    timestamp REAL NOT NULL,
                    state TEXT NOT NULL
                );
                CREATE INDEX op_journal_on_batch ON op_journal(batch_id);
                """)
        }
        return m
    }()

    // MARK: - Writes

    /// Inserts the record, or updates the existing row with the same path.
    /// The row id is preserved across updates so that `analysis` rows written
    /// by later phases survive a re-scan.
    @discardableResult
    public func upsert(_ record: FileRecord) throws -> Int64 {
        try dbq.write { db in
            let id = try Int64.fetchOne(db, sql: """
                INSERT INTO files
                    (path, parent_dir, name, ext, size, mtime, inode, width, height,
                     capture_time, capture_offset, camera_make, camera_model, orientation,
                     content_hash, image_hash, image_hash_kind, phash, hashed_at, indexed_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(path) DO UPDATE SET
                    parent_dir=excluded.parent_dir, name=excluded.name, ext=excluded.ext,
                    size=excluded.size, mtime=excluded.mtime, inode=excluded.inode,
                    width=excluded.width, height=excluded.height,
                    capture_time=excluded.capture_time, capture_offset=excluded.capture_offset,
                    camera_make=excluded.camera_make, camera_model=excluded.camera_model,
                    orientation=excluded.orientation, indexed_at=excluded.indexed_at,
                    -- A changed size or mtime means the bytes changed, so every
                    -- hash on this row is now a lie. Clearing hashed_at also
                    -- re-enqueues the file for the tier 1 pass.
                    content_hash = CASE WHEN files.size <> excluded.size
                                          OR files.mtime <> excluded.mtime
                                     THEN NULL ELSE files.content_hash END,
                    image_hash = CASE WHEN files.size <> excluded.size
                                        OR files.mtime <> excluded.mtime
                                   THEN NULL ELSE files.image_hash END,
                    image_hash_kind = CASE WHEN files.size <> excluded.size
                                             OR files.mtime <> excluded.mtime
                                        THEN NULL ELSE files.image_hash_kind END,
                    phash = CASE WHEN files.size <> excluded.size
                                   OR files.mtime <> excluded.mtime
                              THEN NULL ELSE files.phash END,
                    hashed_at = CASE WHEN files.size <> excluded.size
                                       OR files.mtime <> excluded.mtime
                                  THEN NULL ELSE files.hashed_at END
                RETURNING id
                """, arguments: [
                    record.path, record.parentDir, record.name, record.ext,
                    record.size, record.mtime, record.inode, record.width, record.height,
                    record.captureTime, record.captureOffset, record.cameraMake,
                    record.cameraModel, record.orientation, record.contentHash,
                    record.imageHash, record.imageHashKind, record.phash,
                    record.hashedAt, record.indexedAt,
                ])!
            try db.execute(sql: "DELETE FROM files_fts WHERE rowid = ?", arguments: [id])
            try db.execute(sql: "INSERT INTO files_fts (rowid, name, ocr_text) VALUES (?, ?, NULL)",
                           arguments: [id, record.name])
            return id
        }
    }

    /// `content` is optional because `hashed_at` records that hashing was
    /// *attempted*. A file that cannot be read must still be marked, or the
    /// tier 1 pass retries it on every run forever.
    public func setHashes(fileID: Int64, content: String?, image: String?,
                          imageKind: String?, phash: String?, hashedAt: Double) throws {
        try dbq.write { db in
            try db.execute(sql: """
                UPDATE files SET content_hash = ?, image_hash = ?, image_hash_kind = ?,
                                 phash = ?, hashed_at = ?
                WHERE id = ?
                """, arguments: [content, image, imageKind, phash, hashedAt, fileID])
        }
    }

    /// Removes rows under `prefix` whose paths are not in `keeping`.
    @discardableResult
    public func deleteRows(under prefix: String, keeping: Set<String>) throws -> Int {
        try dbq.write { db in
            let stale = try String.fetchAll(db, sql: """
                SELECT path FROM files WHERE path = ? OR path LIKE ? ESCAPE '\\'
                """, arguments: [prefix, Self.likePrefix(prefix)])
                .filter { !keeping.contains($0) }
            for path in stale {
                if let id = try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                                               arguments: [path]) {
                    try db.execute(sql: "DELETE FROM files_fts WHERE rowid = ?", arguments: [id])
                    try db.execute(sql: "DELETE FROM files WHERE id = ?", arguments: [id])
                }
            }
            return stale.count
        }
    }

    // MARK: - Reads

    public func record(atPath path: String) throws -> FileRecord? {
        try dbq.read { db in
            try FileRecord.fetchOne(db, sql: "SELECT * FROM files WHERE path = ?", arguments: [path])
        }
    }

    public func needsReindex(path: String, size: Int64, mtime: Double) throws -> Bool {
        guard let row = try record(atPath: path) else { return true }
        return row.size != size || row.mtime != mtime
    }

    public func filesMissingHashes(under prefix: String, limit: Int) throws -> [FileRecord] {
        try dbq.read { db in
            try FileRecord.fetchAll(db, sql: """
                SELECT * FROM files
                WHERE hashed_at IS NULL AND (path = ? OR path LIKE ? ESCAPE '\\')
                ORDER BY id LIMIT ?
                """, arguments: [prefix, Self.likePrefix(prefix), limit])
        }
    }

    public func count() throws -> Int {
        try dbq.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM files")! }
    }

    // MARK: - Test support

    func tableNames() throws -> Set<String> {
        try dbq.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table')"))
        }
    }

    func ftsRowCount() throws -> Int {
        try dbq.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM files_fts")! }
    }

    /// Escapes a path for use as a `LIKE` prefix so that a directory containing
    /// `%` or `_` cannot match sibling directories.
    static func likePrefix(_ prefix: String) -> String {
        let escaped = prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return escaped.hasSuffix("/") ? escaped + "%" : escaped + "/%"
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Core && swift test --filter IndexStore`
Expected: PASS, 9 tests.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/LightboxCore/Index Core/Tests/LightboxCoreTests/IndexStoreTests.swift
git commit -m "feat: add IndexStore with v1 schema, upsert, and staleness tracking"
```

---

### Task 5: MetadataReader

**Files:**
- Create: `Core/Sources/LightboxCore/Metadata/ImageMetadata.swift`
- Create: `Core/Sources/LightboxCore/Metadata/MetadataReader.swift`
- Create: `Core/Tests/LightboxCoreTests/Support/Fixtures.swift`
- Test: `Core/Tests/LightboxCoreTests/MetadataReaderTests.swift`

**Interfaces:**
- Consumes: `TempTree` from Task 3.
- Produces:
  - `public struct ImageMetadata: Sendable, Hashable { public var width: Int; public var height: Int; public var captureTime: Date?; public var captureOffset: String?; public var cameraMake: String?; public var cameraModel: String?; public var orientation: Int }`
  - `public enum MetadataError: Error, Equatable { case unreadable, notAnImage }`
  - `public protocol MetadataReading: Sendable { func read(_ url: URL) throws -> ImageMetadata }`
  - `public struct MetadataReader: MetadataReading { public init() }`
  - Test helper `Fixtures.writeImage(to:format:width:height:captureTime:offset:make:model:) throws -> URL`

`MetadataReading` exists so Task 14's coordinator tests can inject a fake instead of touching disk.

- [ ] **Step 1: Write the fixture helper**

`Core/Tests/LightboxCoreTests/Support/Fixtures.swift`:

```swift
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum Fixtures {
    enum Format {
        case jpeg, png, heic, tiff
        var utType: UTType {
            switch self {
            case .jpeg: .jpeg
            case .png: .png
            case .heic: .heic
            case .tiff: .tiff
            }
        }
        var ext: String {
            switch self {
            case .jpeg: "jpg"
            case .png: "png"
            case .heic: "heic"
            case .tiff: "tiff"
            }
        }
    }

    /// A deterministic gradient, so two calls with the same size produce
    /// byte-identical pixels and hash tests are stable.
    static func image(width: Int, height: Int, seed: Int = 0) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            for x in 0..<width {
                ctx.setFillColor(red: Double((x &+ seed) % 256) / 255.0,
                                 green: Double((y &+ seed) % 256) / 255.0,
                                 blue: Double((x &* y &+ seed) % 256) / 255.0,
                                 alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }

    @discardableResult
    static func writeImage(to url: URL, format: Format = .jpeg,
                           width: Int = 64, height: Int = 48, seed: Int = 0,
                           captureTime: String? = "2019:03:04 10:11:12",
                           offset: String? = "-05:00",
                           make: String? = "TestCam", model: String? = "T1",
                           orientation: Int = 1) throws -> URL {
        var exif: [CFString: Any] = [:]
        if let captureTime { exif[kCGImagePropertyExifDateTimeOriginal] = captureTime }
        if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
        var tiff: [CFString: Any] = [:]
        if let make { tiff[kCGImagePropertyTIFFMake] = make }
        if let model { tiff[kCGImagePropertyTIFFModel] = model }

        var props: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if !exif.isEmpty { props[kCGImagePropertyExifDictionary] = exif }
        if !tiff.isEmpty { props[kCGImagePropertyTIFFDictionary] = tiff }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image(width: width, height: height, seed: seed),
                                   props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}
```

**Note for the implementer:** ImageIO on macOS 26 can write JPEG, PNG, HEIC, and TIFF but **cannot write WebP** — `CGImageDestinationCreateWithURL` returns nil for `org.webmproject.webp`. Task 9 uses a checked-in fixture for WebP instead. This was verified on the target machine; do not spend time trying to make ImageIO encode WebP.

- [ ] **Step 2: Write the failing test**

```swift
import Testing
import Foundation
@testable import LightboxCore

@Test func readsDimensionsAndCameraAndCaptureTime() throws {
    let tree = try TempTree()
    let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"),
                                      width: 200, height: 120)
    let md = try MetadataReader().read(url)
    #expect(md.width == 200)
    #expect(md.height == 120)
    #expect(md.cameraMake == "TestCam")
    #expect(md.cameraModel == "T1")
    #expect(md.captureOffset == "-05:00")
    #expect(md.orientation == 1)

    var components = DateComponents()
    components.year = 2019; components.month = 3; components.day = 4
    components.hour = 10; components.minute = 11; components.second = 12
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!
    #expect(md.captureTime == calendar.date(from: components))
}

@Test func treatsCaptureTimeAsUTCWhenNoOffsetIsPresent() throws {
    let tree = try TempTree()
    let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("b.jpg"), offset: nil)
    let md = try MetadataReader().read(url)
    var components = DateComponents()
    components.year = 2019; components.month = 3; components.day = 4
    components.hour = 10; components.minute = 11; components.second = 12
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    #expect(md.captureTime == calendar.date(from: components))
    #expect(md.captureOffset == nil)
}

@Test func readsPNGAndHEICAndTIFF() throws {
    let tree = try TempTree()
    for format in [Fixtures.Format.png, .heic, .tiff] {
        let url = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("x.\(format.ext)"),
            format: format, width: 40, height: 30)
        let md = try MetadataReader().read(url)
        #expect(md.width == 40, "width for \(format.ext)")
        #expect(md.height == 30, "height for \(format.ext)")
    }
}

@Test func returnsNilCaptureTimeWhenTheImageHasNoEXIF() throws {
    let tree = try TempTree()
    let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("c.png"),
                                      format: .png, captureTime: nil, offset: nil,
                                      make: nil, model: nil)
    let md = try MetadataReader().read(url)
    #expect(md.captureTime == nil)
    #expect(md.cameraMake == nil)
}

@Test func throwsNotAnImageForGarbageContent() throws {
    let tree = try TempTree()
    let url = tree.root.appendingPathComponent("junk.jpg")
    try Data("this is not an image".utf8).write(to: url)
    #expect(throws: MetadataError.notAnImage) { try MetadataReader().read(url) }
}

@Test func throwsNotAnImageForAnEmptyFile() throws {
    let tree = try TempTree()
    let url = try tree.file("empty.jpg", bytes: 0)
    #expect(throws: MetadataError.notAnImage) { try MetadataReader().read(url) }
}

@Test func throwsUnreadableForAMissingFile() throws {
    let tree = try TempTree()
    let url = tree.root.appendingPathComponent("absent.jpg")
    #expect(throws: MetadataError.unreadable) { try MetadataReader().read(url) }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd Core && swift test --filter MetadataReader`
Expected: FAIL — `cannot find 'MetadataReader' in scope`.

- [ ] **Step 4: Write the implementation**

`Core/Sources/LightboxCore/Metadata/ImageMetadata.swift`:

```swift
import Foundation

public struct ImageMetadata: Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var captureTime: Date?
    /// The EXIF `OffsetTimeOriginal` string, e.g. `-05:00`, when present.
    /// `DateTimeOriginal` carries no zone, so without this the capture time is
    /// only meaningful relative to an assumed zone.
    public var captureOffset: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var orientation: Int

    public init(width: Int, height: Int, captureTime: Date? = nil, captureOffset: String? = nil,
                cameraMake: String? = nil, cameraModel: String? = nil, orientation: Int = 1) {
        self.width = width; self.height = height
        self.captureTime = captureTime; self.captureOffset = captureOffset
        self.cameraMake = cameraMake; self.cameraModel = cameraModel
        self.orientation = orientation
    }
}

public enum MetadataError: Error, Equatable {
    case unreadable
    case notAnImage
}

public protocol MetadataReading: Sendable {
    func read(_ url: URL) throws -> ImageMetadata
}
```

`Core/Sources/LightboxCore/Metadata/MetadataReader.swift`:

```swift
import Foundation
import ImageIO

/// Reads image metadata with ImageIO, in-process.
///
/// ImageIO rather than exiftool: indexing 50k files must not fork 50k
/// subprocesses, and ImageIO covers every format this app indexes for reading.
/// exiftool appears only on the write path, in phase 2.
public struct MetadataReader: MetadataReading {
    public init() {}

    public func read(_ url: URL) throws -> ImageMetadata {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw MetadataError.unreadable
        }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, options as CFDictionary)
                  as? [CFString: Any],
              let width = raw[kCGImagePropertyPixelWidth] as? Int,
              let height = raw[kCGImagePropertyPixelHeight] as? Int
        else {
            throw MetadataError.notAnImage
        }

        let exif = raw[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = raw[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            ?? exif[kCGImagePropertyExifOffsetTimeDigitized] as? String

        let stamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String
            ?? tiff[kCGImagePropertyTIFFDateTime] as? String

        return ImageMetadata(
            width: width,
            height: height,
            captureTime: stamp.flatMap { Self.parseEXIFDate($0, offset: offset) },
            captureOffset: offset,
            cameraMake: (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmed,
            cameraModel: (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmed,
            orientation: raw[kCGImagePropertyOrientation] as? Int ?? 1)
    }

    /// Parses EXIF's `yyyy:MM:dd HH:mm:ss`.
    ///
    /// The format carries no zone. When `OffsetTimeOriginal` is present it is
    /// authoritative; otherwise the timestamp is interpreted as UTC. UTC rather
    /// than the machine's local zone deliberately: the local zone would make
    /// the same file sort differently depending on where it was indexed, which
    /// is a silent, invisible bug. Phase 2's editor makes the zone explicit.
    static func parseEXIFDate(_ text: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = offset.flatMap(Self.timeZone(fromOffset:)) ?? TimeZone(secondsFromGMT: 0)
        return formatter.date(from: text)
    }

    /// Converts an EXIF offset string such as `-05:00` into a time zone.
    static func timeZone(fromOffset text: String) -> TimeZone? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 6 else { return nil }
        let sign: Int
        switch trimmed.first {
        case "+": sign = 1
        case "-": sign = -1
        default: return nil
        }
        let body = trimmed.dropFirst().split(separator: ":")
        guard body.count == 2, let hours = Int(body[0]), let minutes = Int(body[1]) else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }
}

private extension String {
    /// EXIF strings are frequently space- or NUL-padded by the writing device.
    var trimmed: String? {
        let cleaned = trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\0")))
        return cleaned.isEmpty ? nil : cleaned
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Core && swift test --filter MetadataReader`
Expected: PASS, 7 tests.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/LightboxCore/Metadata Core/Tests/LightboxCoreTests/
git commit -m "feat: add MetadataReader over ImageIO with explicit EXIF zone handling"
```

---

### Task 6: ContentHasher

**Files:**
- Create: `Core/Sources/LightboxCore/Hashing/ContentHasher.swift`
- Test: `Core/Tests/LightboxCoreTests/ContentHasherTests.swift`

**Interfaces:**
- Consumes: `TempTree` from Task 3.
- Produces:
  - `public enum HashError: Error, Equatable { case unreadable, truncated, malformed(String) }`
  - `public struct ContentHasher: Sendable { public init(bufferSize: Int = 1 << 20); public func hash(_ url: URL) throws -> String }`
  - `extension Digest { var hexEncoded: String }` (internal, used by every hasher)

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import CryptoKit
@testable import LightboxCore

@Test func matchesKnownSHA256Vectors() throws {
    let tree = try TempTree()
    let empty = tree.root.appendingPathComponent("empty.bin")
    try Data().write(to: empty)
    #expect(try ContentHasher().hash(empty)
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

    let abc = tree.root.appendingPathComponent("abc.bin")
    try Data("abc".utf8).write(to: abc)
    #expect(try ContentHasher().hash(abc)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func streamingAcrossManyBuffersMatchesASingleShot() throws {
    let tree = try TempTree()
    let url = tree.root.appendingPathComponent("big.bin")
    var payload = Data()
    for i in 0..<200_000 { payload.append(UInt8(i % 251)) }
    try payload.write(to: url)

    let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    // A tiny buffer forces hundreds of read iterations.
    #expect(try ContentHasher(bufferSize: 997).hash(url) == expected)
    #expect(try ContentHasher(bufferSize: 1 << 20).hash(url) == expected)
}

@Test func throwsUnreadableForAMissingFile() throws {
    let tree = try TempTree()
    #expect(throws: HashError.unreadable) {
        try ContentHasher().hash(tree.root.appendingPathComponent("nope.bin"))
    }
}

@Test func hexIsLowercaseAndSixtyFourCharacters() throws {
    let tree = try TempTree()
    let url = try tree.file("a.bin", bytes: 10)
    let hex = try ContentHasher().hash(url)
    #expect(hex.count == 64)
    #expect(hex == hex.lowercased())
    #expect(hex.allSatisfy { $0.isHexDigit })
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter ContentHasher`
Expected: FAIL — `cannot find 'ContentHasher' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import CryptoKit

public enum HashError: Error, Equatable {
    case unreadable
    case truncated
    case malformed(String)
}

/// SHA-256 of a file's entire contents.
///
/// Streamed in fixed buffers rather than read whole: a library contains
/// multi-hundred-megabyte PSD and RAW files, and the indexer hashes several
/// files concurrently.
public struct ContentHasher: Sendable {
    public let bufferSize: Int

    public init(bufferSize: Int = 1 << 20) {
        precondition(bufferSize > 0, "bufferSize must be positive")
        self.bufferSize = bufferSize
    }

    public func hash(_ url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw HashError.unreadable
        }
        defer { try? handle.close() }

        var digest = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: bufferSize), !chunk.isEmpty else { break }
            digest.update(data: chunk)
        }
        return digest.finalize().hexEncoded
    }
}

extension Digest {
    /// Lowercase hex, built by table lookup. `String(format:)` is called once
    /// per byte and shows up in a profile when hashing 50k files.
    var hexEncoded: String {
        let alphabet = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(Self.byteCount * 2)
        for byte in makeIterator() {
            out.append(alphabet[Int(byte >> 4)])
            out.append(alphabet[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Core && swift test --filter ContentHasher`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/LightboxCore/Hashing/ContentHasher.swift Core/Tests/LightboxCoreTests/ContentHasherTests.swift
git commit -m "feat: add streaming ContentHasher"
```

---

### Task 7: JPEG image hash

**Files:**
- Create: `Core/Sources/LightboxCore/Hashing/JPEGImageHash.swift`
- Test: `Core/Tests/LightboxCoreTests/JPEGImageHashTests.swift`

**Interfaces:**
- Consumes: `HashError` from Task 6, `Fixtures`/`TempTree` from Tasks 3 and 5.
- Produces:
  - `enum JPEGImageHash { static let kind: String; static func includedRanges(_ bytes: UnsafeRawBufferPointer) throws -> [Range<Int>] }`

The parser returns byte ranges rather than a digest so Task 9's `FileHasher` can feed one SHA-256 from a single memory mapping, and so tests can assert on structure directly.

**The segment rule, and why each marker is where it is.** Excluded: `APP0` (0xE0, JFIF density and thumbnail), `APP1` (0xE1, EXIF and XMP), `APP13` (0xED, Photoshop/IPTC), `COM` (0xFE). **Retained, deliberately:** `APP2` (0xE2) carries the ICC profile and `APP14` (0xEE) carries Adobe's colour-transform marker, which determines whether the scan data is YCbCr or YCCK — excluding either would make two genuinely different images hash identically. `DRI` (0xDD) restart intervals, `DQT`, `DHT`, and `SOF` all affect decoding and are retained.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import LightboxCore

/// Runs exiftool if it is installed; returns false when it is not, so the
/// suite stays green on a machine without it.
@discardableResult
func exiftool(_ args: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["exiftool"] + args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

var exiftoolAvailable: Bool { exiftool(["-ver"]) }

private func jpegHash(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return try data.withUnsafeBytes { bytes in
        try ImageDataDigest.digest(bytes, ranges: JPEGImageHash.includedRanges(bytes))
    }
}

@Test func imageHashSurvivesAnEXIFEditWhileContentHashDoesNot() throws {
    try #require(exiftoolAvailable, "exiftool not installed")
    let tree = try TempTree()
    let a = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
    let b = tree.root.appendingPathComponent("b.jpg")
    try FileManager.default.copyItem(at: a, to: b)
    #expect(exiftool(["-q", "-overwrite_original",
                      "-DateTimeOriginal=2021:07:08 09:10:11", b.path]))

    #expect(try jpegHash(a) == jpegHash(b))                       // the warranty
    #expect(try ContentHasher().hash(a) != ContentHasher().hash(b))
}

@Test func excludesOnlyTheMetadataSegments() throws {
    let tree = try TempTree()
    let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
    let data = try Data(contentsOf: url)
    let markers: [UInt8] = try data.withUnsafeBytes { bytes in
        try JPEGImageHash.includedRanges(bytes).map { bytes.load(fromByteOffset: $0.lowerBound + 1, as: UInt8.self) }
    }
    #expect(!markers.contains(0xE0))
    #expect(!markers.contains(0xE1))
    #expect(!markers.contains(0xED))
    #expect(!markers.contains(0xFE))
    #expect(markers.contains(0xC0) || markers.contains(0xC2))   // SOF
    #expect(markers.contains(0xDA))                             // SOS
    #expect(markers.contains(0xD9))                             // EOI
}

@Test func aDifferenceInAPP14ChangesTheHash() throws {
    // APP14 decides YCbCr vs YCCK, so it is image data, not metadata.
    let base = try Data(contentsOf: Fixtures.writeImage(
        to: try TempTree().root.appendingPathComponent("a.jpg")))
    var withAPP14 = Data(base.prefix(2))                        // SOI
    withAPP14.append(contentsOf: [0xFF, 0xEE, 0x00, 0x0E])      // APP14, length 14
    withAPP14.append(contentsOf: Array("Adobe".utf8))
    withAPP14.append(contentsOf: [0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x02])
    withAPP14.append(base.dropFirst(2))

    let one = try base.withUnsafeBytes { try ImageDataDigest.digest($0, ranges: JPEGImageHash.includedRanges($0)) }
    let two = try withAPP14.withUnsafeBytes { try ImageDataDigest.digest($0, ranges: JPEGImageHash.includedRanges($0)) }
    #expect(one != two)
}

@Test func rejectsFilesThatAreNotJPEG() throws {
    let junk = Data("not a jpeg at all".utf8)
    #expect(throws: (any Error).self) {
        try junk.withUnsafeBytes { try JPEGImageHash.includedRanges($0) }
    }
}

@Test func rejectsATruncatedJPEG() throws {
    let tree = try TempTree()
    let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
    let truncated = try Data(contentsOf: url).prefix(20)
    #expect(throws: (any Error).self) {
        try truncated.withUnsafeBytes { try JPEGImageHash.includedRanges($0) }
    }
}

@Test func rejectsAnEmptyBuffer() throws {
    let empty = Data()
    #expect(throws: (any Error).self) {
        try empty.withUnsafeBytes { try JPEGImageHash.includedRanges($0) }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter JPEGImageHash`
Expected: FAIL — `cannot find 'JPEGImageHash' in scope`.

- [ ] **Step 3: Write the shared digest helper and the parser**

`Core/Sources/LightboxCore/Hashing/JPEGImageHash.swift`:

```swift
import Foundation
import CryptoKit

/// Hashes a set of byte ranges from one buffer. Shared by every format parser
/// so that all of them agree on digest construction.
enum ImageDataDigest {
    static func digest(_ bytes: UnsafeRawBufferPointer, ranges: [Range<Int>]) throws -> String {
        var sha = SHA256()
        for range in ranges {
            guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
                throw HashError.malformed("range \(range) outside buffer of \(bytes.count)")
            }
            if range.isEmpty { continue }
            sha.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[range]))
        }
        return sha.finalize().hexEncoded
    }
}

/// The byte ranges of a JPEG that constitute image data.
///
/// A denylist, not an allowlist: markers this parser has never heard of are
/// hashed. Guessing wrong in that direction changes a hash; guessing wrong the
/// other way would silently call two different images identical.
enum JPEGImageHash {
    static let kind = "jpeg-scan-v1"

    /// APP0 (JFIF), APP1 (EXIF/XMP), APP13 (Photoshop/IPTC), COM.
    ///
    /// APP2 (ICC profile) and APP14 (Adobe colour transform) are deliberately
    /// absent: both change how the scan data decodes into pixels.
    static let excludedMarkers: Set<UInt8> = [0xE0, 0xE1, 0xED, 0xFE]

    static func includedRanges(_ bytes: UnsafeRawBufferPointer) throws -> [Range<Int>] {
        guard bytes.count >= 4 else { throw HashError.truncated }
        guard bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw HashError.malformed("missing JPEG SOI marker")
        }

        var ranges: [Range<Int>] = []
        var i = 2

        while i < bytes.count {
            guard bytes[i] == 0xFF else { throw HashError.malformed("expected a marker at \(i)") }
            // Fill bytes: a run of 0xFF before the marker identifier is legal.
            var markerIndex = i + 1
            while markerIndex < bytes.count, bytes[markerIndex] == 0xFF { markerIndex += 1 }
            guard markerIndex < bytes.count else { throw HashError.truncated }
            let marker = bytes[markerIndex]

            switch marker {
            case 0xD9:                                   // EOI
                ranges.append(i..<min(markerIndex + 1, bytes.count))
                return ranges

            case 0x01, 0xD0...0xD7:                      // standalone, no payload
                i = markerIndex + 1

            case 0xDA:                                   // SOS: header, then entropy data
                guard markerIndex + 3 < bytes.count else { throw HashError.truncated }
                let headerLength = Int(bytes[markerIndex + 1]) << 8 | Int(bytes[markerIndex + 2])
                var scan = markerIndex + 1 + headerLength
                guard scan <= bytes.count else { throw HashError.truncated }
                // Entropy-coded data runs until a marker that is neither a
                // stuffed 0xFF00 nor a restart marker.
                while scan + 1 < bytes.count {
                    if bytes[scan] == 0xFF {
                        let next = bytes[scan + 1]
                        if next != 0x00, !(0xD0...0xD7).contains(next) { break }
                    }
                    scan += 1
                }
                if scan + 1 >= bytes.count { scan = bytes.count }
                ranges.append(i..<scan)
                i = scan

            default:                                     // length-prefixed segment
                guard markerIndex + 3 < bytes.count else { throw HashError.truncated }
                let length = Int(bytes[markerIndex + 1]) << 8 | Int(bytes[markerIndex + 2])
                guard length >= 2 else { throw HashError.malformed("segment length \(length) at \(i)") }
                let end = markerIndex + 1 + length
                guard end <= bytes.count else { throw HashError.truncated }
                if !excludedMarkers.contains(marker) { ranges.append(i..<end) }
                i = end
            }
        }

        // Reaching here means the scan ran off the end without an EOI.
        throw HashError.truncated
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Core && swift test --filter JPEGImageHash`
Expected: PASS, 7 tests. If exiftool is absent the warranty test reports as skipped, not failed.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/LightboxCore/Hashing/JPEGImageHash.swift Core/Tests/LightboxCoreTests/JPEGImageHashTests.swift
git commit -m "feat: add JPEG image-data hash that survives EXIF edits"
```

---

### Task 8: PNG image hash

**Files:**
- Create: `Core/Sources/LightboxCore/Hashing/PNGImageHash.swift`
- Test: `Core/Tests/LightboxCoreTests/PNGImageHashTests.swift`

**Interfaces:**
- Consumes: `HashError`, `ImageDataDigest` from Tasks 6 and 7.
- Produces: `enum PNGImageHash { static let kind: String; static func includedRanges(_ bytes: UnsafeRawBufferPointer) throws -> [Range<Int>] }`

**The chunk rule.** Excluded: `tEXt`, `zTXt`, `iTXt`, `eXIf`, `tIME`, `pHYs`. Retained: `IHDR`, `PLTE`, `tRNS`, `IDAT`, `IEND`, and the colour chunks `gAMA`, `cHRM`, `iCCP`, `sRGB` — all of which change the decoded result. A denylist works for PNG because writing metadata rewrites existing chunks in place rather than restructuring the file; this was verified against an exiftool round-trip.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import LightboxCore

private func pngHash(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return try data.withUnsafeBytes { try ImageDataDigest.digest($0, ranges: PNGImageHash.includedRanges($0)) }
}

@Test(.enabled(if: exiftoolAvailable, "exiftool not installed"))
func pngImageHashSurvivesAnEXIFEdit() throws {
    let tree = try TempTree()
    let a = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.png"), format: .png)
    let b = tree.root.appendingPathComponent("b.png")
    try FileManager.default.copyItem(at: a, to: b)
    #expect(exiftool(["-q", "-overwrite_original",
                      "-DateTimeOriginal=2021:07:08 09:10:11", b.path]))

    #expect(try pngHash(a) == pngHash(b))
    #expect(try ContentHasher().hash(a) != ContentHasher().hash(b))
}

@Test func pngExcludesTextAndTimeAndPhysicalChunks() throws {
    let tree = try TempTree()
    let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.png"), format: .png)
    let data = try Data(contentsOf: url)
    let types: [String] = try data.withUnsafeBytes { bytes in
        try PNGImageHash.includedRanges(bytes).map { range in
            String(decoding: (0..<4).map { bytes[range.lowerBound + 4 + $0] }, as: UTF8.self)
        }
    }
    #expect(types.contains("IHDR"))
    #expect(types.contains("IDAT"))
    #expect(types.contains("IEND"))
    #expect(!types.contains("eXIf"))
    #expect(!types.contains("iTXt"))
    #expect(!types.contains("tEXt"))
    #expect(!types.contains("pHYs"))
}

@Test func pngWithDifferentPixelsHashesDifferently() throws {
    let tree = try TempTree()
    let a = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.png"),
                                    format: .png, seed: 0)
    let b = try Fixtures.writeImage(to: tree.root.appendingPathComponent("b.png"),
                                    format: .png, seed: 7)
    #expect(try pngHash(a) != pngHash(b))
}

@Test func pngRejectsABadSignature() throws {
    let junk = Data(repeating: 0x00, count: 64)
    #expect(throws: (any Error).self) {
        try junk.withUnsafeBytes { try PNGImageHash.includedRanges($0) }
    }
}

@Test func pngRejectsATruncatedChunk() throws {
    let tree = try TempTree()
    let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.png"), format: .png)
    let truncated = try Data(contentsOf: url).prefix(30)
    #expect(throws: (any Error).self) {
        try truncated.withUnsafeBytes { try PNGImageHash.includedRanges($0) }
    }
}

@Test func pngRejectsAnAbsurdChunkLength() throws {
    var forged = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    forged.append(contentsOf: [0x7F, 0xFF, 0xFF, 0xFF])          // length ~2GB
    forged.append(contentsOf: Array("IHDR".utf8))
    forged.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
    #expect(throws: (any Error).self) {
        try forged.withUnsafeBytes { try PNGImageHash.includedRanges($0) }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter PNGImageHash`
Expected: FAIL — `cannot find 'PNGImageHash' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// The byte ranges of a PNG that constitute image data.
///
/// A denylist: unknown ancillary chunks are hashed, because a chunk this
/// parser does not recognise may well affect rendering.
enum PNGImageHash {
    static let kind = "png-idat-v1"

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Text, timestamps, EXIF, and physical pixel dimensions. `pHYs` is print
    /// density, not pixels, and exiftool rewrites it.
    static let excludedTypes: Set<String> = ["tEXt", "zTXt", "iTXt", "eXIf", "tIME", "pHYs"]

    static func includedRanges(_ bytes: UnsafeRawBufferPointer) throws -> [Range<Int>] {
        guard bytes.count >= signature.count else { throw HashError.truncated }
        for (offset, expected) in signature.enumerated() where bytes[offset] != expected {
            throw HashError.malformed("bad PNG signature")
        }

        var ranges: [Range<Int>] = []
        var i = signature.count

        while i + 8 <= bytes.count {
            let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16
                       | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            // The PNG spec caps a chunk at 2^31 - 1, and it must also fit.
            guard length >= 0, i + 12 + length <= bytes.count else { throw HashError.truncated }

            let type = String(decoding: (0..<4).map { bytes[i + 4 + $0] }, as: UTF8.self)
            let end = i + 12 + length                      // length + type + data + CRC
            if !excludedTypes.contains(type) { ranges.append(i..<end) }
            i = end
            if type == "IEND" { return ranges }
        }

        throw HashError.truncated                          // no IEND
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Core && swift test --filter PNGImageHash`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/LightboxCore/Hashing/PNGImageHash.swift Core/Tests/LightboxCoreTests/PNGImageHashTests.swift
git commit -m "feat: add PNG image-data hash"
```

---

### Task 9: WebP image hash and the FileHasher facade

**Files:**
- Create: `Core/Sources/LightboxCore/Hashing/WebPImageHash.swift`
- Create: `Core/Sources/LightboxCore/Hashing/FileHasher.swift`
- Create: `Core/Tests/LightboxCoreTests/Fixtures/simple.webp` (from the base64 below)
- Test: `Core/Tests/LightboxCoreTests/WebPImageHashTests.swift`
- Test: `Core/Tests/LightboxCoreTests/FileHasherTests.swift`

**Interfaces:**
- Consumes: `MediaType` (Task 2), `HashError`/`ContentHasher` (Task 6), `ImageDataDigest`/`JPEGImageHash` (Task 7), `PNGImageHash` (Task 8).
- Also requires adding to `ContentHasher` (Task 6's file): `func readWholeFile(_ url: URL) throws -> Data`, which reads via the same buffered, error-checked loop as `hash(_:)` and returns the bytes. It exists so `FileHasher` can get one catchable read without memory-mapping; do not reimplement the read loop.

**No memory mapping on this path — this is a correction to the original plan text.** `Data(contentsOf:, .mappedIfSafe)` converts a mid-read `EIO` on a failing external volume into `SIGBUS`, which cannot be caught and cannot be mapped to `HashError.truncated`. That would silently bypass the error handling Task 6 exists to provide, on precisely the large files that motivated it. Add a test that a file larger than `inMemoryLimit` still yields a content hash and a nil image hash.
- Produces:
  - `enum WebPImageHash { static let kind: String; static func includedRanges(_ bytes: UnsafeRawBufferPointer) throws -> [Range<Int>] }`
  - `public struct FileHashes: Sendable, Hashable { public let contentHash: String; public let imageHash: String?; public let imageHashKind: String? }`
  - `public protocol FileHashing: Sendable { func hashes(for url: URL, mediaType: MediaType) throws -> FileHashes }`
  - `public struct FileHasher: FileHashing { public init() }`

**WebP uses an allowlist, and this is not a stylistic choice.** Writing EXIF to a *simple-format* WebP promotes it to *extended format*: exiftool inserts a `VP8X` header chunk that did not previously exist. A denylist of `EXIF`/`XMP ` therefore sees a brand-new chunk and produces a different hash — verified failing on the target machine. The allowlist is `VP8 `, `VP8L`, `ALPH`, `ANIM`, `ANMF`, `ICCP`: the chunks that carry image data or affect its decoding. `VP8X` is excluded because it is a container header whose canvas dimensions merely restate what the image data already says.

- [ ] **Step 1: Create the WebP fixture**

ImageIO cannot encode WebP, so the fixture is checked in. Recreate it exactly:

```bash
cd Core/Tests/LightboxCoreTests/Fixtures
rm -f .gitkeep
base64 -d > simple.webp <<'B64'
UklGRvAAAABXRUJQVlA4TOQAAAAvF8ADALkyRPQ/dhHR/5C4iiTJitIF/rXuLiCBv3sWzAJUAQBI
R6/Ntm3bVtzSlmwlNq9bZ9vtmrLvvigm4BI4ewMAOvsUYCeAnTA5AqWoTSDseyJRBbJiexciIlXw
ol3BKvYWH2IV9OgUmOK0mj2vCg2luqJfSACxFZDJiJl2oadeqOM+5HE9QCFR/7tiHLS4CF281FBB
p1SECxOjYMZzcbCaE2ArPCzDwTQsA1hqwaMTesYR4DCiPAGPdxjxj3IDAJqDoR6mO+K8wGEYIa6A
AeJ7ApJ2BY1RRHlBzDSyfGBgvwA=
B64
# Verify: 248 bytes, a simple-format lossless WebP carrying a single VP8L chunk.
[ "$(wc -c < simple.webp | tr -d ' ')" = "248" ] && echo "fixture ok"
```

- [ ] **Step 2: Write the failing WebP test**

```swift
import Testing
import Foundation
@testable import LightboxCore

private func fixtureURL(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
                 ?? Bundle.module.url(forResource: name, withExtension: nil),
                 "fixture \(name) missing from the test bundle")
}

private func webpHash(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return try data.withUnsafeBytes { try ImageDataDigest.digest($0, ranges: WebPImageHash.includedRanges($0)) }
}

@Test(.enabled(if: exiftoolAvailable, "exiftool not installed"))
func webpImageHashSurvivesPromotionToExtendedFormat() throws {
    let tree = try TempTree()
    let a = tree.root.appendingPathComponent("a.webp")
    let b = tree.root.appendingPathComponent("b.webp")
    try FileManager.default.copyItem(at: try fixtureURL("simple.webp"), to: a)
    try FileManager.default.copyItem(at: a, to: b)
    // This inserts a VP8X chunk as well as an EXIF chunk.
    #expect(exiftool(["-q", "-overwrite_original",
                      "-DateTimeOriginal=2021:07:08 09:10:11", b.path]))

    #expect(try webpHash(a) == webpHash(b))
    #expect(try ContentHasher().hash(a) != ContentHasher().hash(b))
}

@Test func webpHashesOnlyTheAllowlistedChunks() throws {
    let url = try fixtureURL("simple.webp")
    let data = try Data(contentsOf: url)
    let names: [String] = try data.withUnsafeBytes { bytes in
        try WebPImageHash.includedRanges(bytes).map { range in
            String(decoding: (0..<4).map { bytes[range.lowerBound + $0] }, as: UTF8.self)
        }
    }
    #expect(names == ["VP8L"])
}

@Test func webpRejectsANonRIFFBuffer() throws {
    let junk = Data("RIFFnope not webp at all!!".utf8)
    #expect(throws: (any Error).self) {
        try junk.withUnsafeBytes { try WebPImageHash.includedRanges($0) }
    }
}

@Test func webpRejectsAChunkLengthPastTheEnd() throws {
    var forged = Data("RIFF".utf8)
    forged.append(contentsOf: [0x20, 0x00, 0x00, 0x00])
    forged.append(contentsOf: Array("WEBP".utf8))
    forged.append(contentsOf: Array("VP8L".utf8))
    forged.append(contentsOf: [0xFF, 0xFF, 0xFF, 0x7F])          // enormous length
    #expect(throws: (any Error).self) {
        try forged.withUnsafeBytes { try WebPImageHash.includedRanges($0) }
    }
}
```

- [ ] **Step 3: Write the failing FileHasher test**

```swift
import Testing
import Foundation
@testable import LightboxCore

@Test func computesBothHashesForASupportedFormat() throws {
    let tree = try TempTree()
    let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
    let type = try #require(MediaType.forExtension("jpg"))
    let hashes = try FileHasher().hashes(for: url, mediaType: type)

    #expect(hashes.contentHash == (try ContentHasher().hash(url)))
    #expect(hashes.imageHash?.count == 64)
    #expect(hashes.imageHashKind == "jpeg-scan-v1")
}

@Test func leavesImageHashNilForFormatsWithoutAStableRule() throws {
    let tree = try TempTree()
    for format in [Fixtures.Format.heic, .tiff] {
        let url = try Fixtures.writeImage(
            to: tree.root.appendingPathComponent("x.\(format.ext)"), format: format)
        let type = try #require(MediaType.forExtension(format.ext))
        let hashes = try FileHasher().hashes(for: url, mediaType: type)
        #expect(hashes.contentHash.count == 64, "content hash for \(format.ext)")
        #expect(hashes.imageHash == nil, "image hash for \(format.ext)")
        #expect(hashes.imageHashKind == nil)
    }
}

@Test func stillReturnsAContentHashWhenTheImageParserFails() throws {
    // A file with a .jpg extension whose bytes are not a JPEG must not abort
    // the indexing pass; the content hash is still useful for exact dedupe.
    let tree = try TempTree()
    let url = tree.root.appendingPathComponent("lying.jpg")
    try Data("this is not a jpeg".utf8).write(to: url)
    let type = try #require(MediaType.forExtension("jpg"))
    let hashes = try FileHasher().hashes(for: url, mediaType: type)
    #expect(hashes.contentHash.count == 64)
    #expect(hashes.imageHash == nil)
    #expect(hashes.imageHashKind == nil)
}

@Test func throwsUnreadableForAMissingFile() throws {
    let tree = try TempTree()
    let type = try #require(MediaType.forExtension("jpg"))
    #expect(throws: HashError.unreadable) {
        try FileHasher().hashes(for: tree.root.appendingPathComponent("gone.jpg"), mediaType: type)
    }
}

@Test func handlesAnEmptyFile() throws {
    let tree = try TempTree()
    let url = try tree.file("empty.jpg", bytes: 0)
    let type = try #require(MediaType.forExtension("jpg"))
    let hashes = try FileHasher().hashes(for: url, mediaType: type)
    #expect(hashes.contentHash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(hashes.imageHash == nil)
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `cd Core && swift test --filter "WebPImageHash|FileHasher"`
Expected: FAIL — `cannot find 'WebPImageHash' in scope`.

- [ ] **Step 5: Write WebPImageHash**

```swift
import Foundation

/// The byte ranges of a WebP that constitute image data.
///
/// An allowlist, unlike JPEG and PNG. Writing EXIF to a simple-format WebP
/// promotes it to extended format and inserts a `VP8X` header chunk that was
/// not there before, so a denylist sees a new chunk and hashes differently.
/// `VP8X` is excluded because its canvas dimensions only restate what the
/// image-data chunks already encode.
enum WebPImageHash {
    static let kind = "webp-chunk-v1"

    static let includedChunks: Set<String> = ["VP8 ", "VP8L", "ALPH", "ANIM", "ANMF", "ICCP"]

    static func includedRanges(_ bytes: UnsafeRawBufferPointer) throws -> [Range<Int>] {
        guard bytes.count >= 12 else { throw HashError.truncated }
        func fourCC(at offset: Int) -> String {
            String(decoding: (0..<4).map { bytes[offset + $0] }, as: UTF8.self)
        }
        guard fourCC(at: 0) == "RIFF", fourCC(at: 8) == "WEBP" else {
            throw HashError.malformed("not a RIFF/WEBP container")
        }

        var ranges: [Range<Int>] = []
        var i = 12

        while i + 8 <= bytes.count {
            let name = fourCC(at: i)
            let length = Int(bytes[i + 4]) | Int(bytes[i + 5]) << 8
                       | Int(bytes[i + 6]) << 16 | Int(bytes[i + 7]) << 24
            guard length >= 0 else { throw HashError.malformed("negative chunk length at \(i)") }
            // RIFF pads odd-length chunk payloads to an even boundary.
            let padded = length + (length & 1)
            let end = i + 8 + padded
            guard end <= bytes.count else { throw HashError.truncated }

            if includedChunks.contains(name) { ranges.append(i..<end) }
            i = end
        }

        guard !ranges.isEmpty else { throw HashError.malformed("no image chunks found") }
        return ranges
    }
}
```

- [ ] **Step 6: Write FileHasher**

```swift
import Foundation
import CryptoKit

public struct FileHashes: Sendable, Hashable {
    public let contentHash: String
    public let imageHash: String?
    public let imageHashKind: String?

    public init(contentHash: String, imageHash: String?, imageHashKind: String?) {
        self.contentHash = contentHash
        self.imageHash = imageHash
        self.imageHashKind = imageHashKind
    }
}

public protocol FileHashing: Sendable {
    func hashes(for url: URL, mediaType: MediaType) throws -> FileHashes
}

/// Computes the whole-file and image-data hashes in a single read per file.
///
/// Deliberately NOT memory-mapped. `Data(contentsOf:, .mappedIfSafe)` would turn
/// a mid-read I/O error on a flaky external volume into `SIGBUS` — an
/// uncatchable fault rather than a `HashError` — on exactly the
/// multi-hundred-megabyte RAW and PSD files that motivated streaming in the
/// first place, silently bypassing `ContentHasher`'s error handling.
///
/// So the file is read once, by whichever of two routes fits its format:
/// a format WITH an image-hash rule (JPEG, PNG, WebP) is read fully into memory
/// and both hashes are computed from that buffer; a format WITHOUT one (RAW,
/// PSD, HEIC, TIFF, GIF — which are the large ones) is streamed by
/// `ContentHasher` and gets no image hash. Every failure stays catchable, and
/// in-memory buffering is bounded to the formats that are small in practice.
public struct FileHasher: FileHashing {
    /// Above this size an image-hashable file is streamed for its content hash
    /// only, and `imageHash` is left nil rather than buffering it whole.
    public static let inMemoryLimit = 256 << 20

    public init() {}

    public func hashes(for url: URL, mediaType: MediaType) throws -> FileHashes {
        let streamed = ContentHasher()

        guard mediaType.imageHashKind != nil,
              let size = try? FileManager.default
                  .attributesOfItem(atPath: url.path)[.size] as? Int,
              size <= Self.inMemoryLimit
        else {
            return FileHashes(contentHash: try streamed.hash(url),
                              imageHash: nil, imageHashKind: nil)
        }

        let data = try streamed.readWholeFile(url)

        return data.withUnsafeBytes { bytes -> FileHashes in
            var content = SHA256()
            if bytes.count > 0 { content.update(bufferPointer: bytes) }
            let contentHash = content.finalize().hexEncoded

            // A parse failure is not an indexing failure. A file whose
            // extension lies about its contents still deserves a content hash,
            // and the image hash is simply unavailable for it.
            guard let kind = mediaType.imageHashKind,
                  let ranges = try? Self.ranges(bytes, kind: mediaType.kind),
                  let imageHash = try? ImageDataDigest.digest(bytes, ranges: ranges)
            else {
                return FileHashes(contentHash: contentHash, imageHash: nil, imageHashKind: nil)
            }
            return FileHashes(contentHash: contentHash, imageHash: imageHash, imageHashKind: kind)
        }
    }

    private static func ranges(_ bytes: UnsafeRawBufferPointer, kind: MediaKind) throws -> [Range<Int>] {
        switch kind {
        case .jpeg: try JPEGImageHash.includedRanges(bytes)
        case .png: try PNGImageHash.includedRanges(bytes)
        case .webp: try WebPImageHash.includedRanges(bytes)
        case .gif, .heic, .tiff, .raw, .psd: throw HashError.malformed("no image-hash rule for \(kind)")
        }
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd Core && swift test --filter "WebPImageHash|FileHasher"`
Expected: PASS, 9 tests.

- [ ] **Step 8: Commit**

```bash
git add Core/Sources/LightboxCore/Hashing Core/Tests/LightboxCoreTests/
git commit -m "feat: add WebP image-data hash and the FileHasher facade"
```

---

### Task 10: GrayscaleRenderer and PerceptualHash

**Files:**
- Create: `Core/Sources/LightboxCore/Hashing/GrayscaleRenderer.swift`
- Create: `Core/Sources/LightboxCore/Hashing/PerceptualHash.swift`
- Test: `Core/Tests/LightboxCoreTests/PerceptualHashTests.swift`

**Interfaces:**
- Consumes: `MetadataError` (Task 5), `Fixtures`/`TempTree` (Tasks 3 and 5).
- Produces:
  - `public protocol GrayscaleRendering: Sendable { func gray32(from url: URL) throws -> [UInt8] }`
  - `public struct GrayscaleRenderer: GrayscaleRendering { public static let size: Int; public init() }`
  - `public struct PerceptualHash: Sendable, Hashable { public static let identifier: String; public static let gridSize: Int; public let value: UInt64; public var hex: String; public init(gray: [UInt8]) throws; public init(hex: String) throws; public func distance(to: PerceptualHash) -> Int }`

**This is a port of `photolib`'s `lib/phash.js`, and every constant is load-bearing.** 32x32 luminance grid; Rec. 709 weights (0.2126 / 0.7152 / 0.0722) rounded to integers; separable orthonormal DCT-II; the 8x8 low-frequency block with the DC term dropped and `F(0,8)` — the coefficient at `u = 8, v = 0` — substituted in its place to keep 64 informative bits; coefficients quantized to six decimal places; median of the 64 picked values as the threshold; bit `63 - i` set when picked value `i` exceeds the median.

The six-decimal quantization is a determinism guard, not a tuning knob. A structurally flat region has coefficients that are mathematically zero but land a few ULPs either side of zero after floating-point summation, and ranked against a near-zero median that residue — not signal — decides the bit. `photolib` measured a solid frame hashing 10 bits apart from itself without it.

The golden vectors below were generated by running `photolib`'s actual implementation, so a passing test proves the port is faithful to the original rather than merely self-consistent.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import LightboxCore

/// The same 32-bit LCG used to generate the golden vector from photolib:
/// s = (s * 1664525 + 1013904223) mod 2^32, sample = s >> 24.
private func lcgGrid(seed: UInt32) -> [UInt8] {
    var s = seed
    return (0..<1024).map { _ in
        s = s &* 1_664_525 &+ 1_013_904_223
        return UInt8(truncatingIfNeeded: s >> 24)
    }
}

private func rampGrid() -> [UInt8] {
    (0..<1024).map { i in UInt8(((i % 32) * 7 + (i / 32) * 13) % 256) }
}

@Test func matchesPhotolibGoldenVectors() throws {
    // Generated by photolib's lib/phash.js. If these change, the two tools no
    // longer agree and every cached hash in either is invalidated.
    #expect(try PerceptualHash(gray: lcgGrid(seed: 12345)).hex == "9f32a3b705ae1b18")
    #expect(try PerceptualHash(gray: rampGrid()).hex == "1b6b0a6ed5c45ab4")
}

@Test func theLCGGridMatchesTheGeneratorUsedForTheGoldenVector() {
    #expect(Array(lcgGrid(seed: 12345).prefix(8)) == [5, 4, 139, 162, 232, 28, 126, 140])
}

@Test func aFlatGridHashesToZero() throws {
    // Degenerate but correct: every retained coefficient is zero, so none
    // exceeds the median. Documented so a future reader does not "fix" it.
    #expect(try PerceptualHash(gray: [UInt8](repeating: 128, count: 1024)).hex
            == "0000000000000000")
}

@Test func identifierAndGridSizeAreLockedToPhotolib() {
    #expect(PerceptualHash.identifier == "phash-dct-64-nodc")
    #expect(PerceptualHash.gridSize == 32)
}

@Test func rejectsAGridOfTheWrongSize() {
    #expect(throws: (any Error).self) { try PerceptualHash(gray: [UInt8](repeating: 0, count: 100)) }
    #expect(throws: (any Error).self) { try PerceptualHash(gray: []) }
}

@Test func hexRoundTripsAndDistanceIsSymmetric() throws {
    let a = try PerceptualHash(gray: lcgGrid(seed: 12345))
    let b = try PerceptualHash(hex: a.hex)
    #expect(a == b)
    #expect(a.distance(to: b) == 0)

    let c = try PerceptualHash(gray: rampGrid())
    #expect(a.distance(to: c) == c.distance(to: a))
    #expect(a.distance(to: c) == 28)      // measured against photolib
}

@Test func rejectsMalformedHex() {
    #expect(throws: (any Error).self) { try PerceptualHash(hex: "nothex") }
    #expect(throws: (any Error).self) { try PerceptualHash(hex: "abc") }
    #expect(throws: (any Error).self) { try PerceptualHash(hex: "0123456789abcdef00") }
}

@Test func rendererProducesAGridOfExactlyTheRightSize() throws {
    let tree = try TempTree()
    let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"),
                                      width: 400, height: 130)
    let gray = try GrayscaleRenderer().gray32(from: url)
    #expect(gray.count == 1024)
}

@Test func rendererIsDeterministicForTheSameFile() throws {
    let tree = try TempTree()
    let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
    #expect(try GrayscaleRenderer().gray32(from: url) == GrayscaleRenderer().gray32(from: url))
}

@Test func rendererThrowsForANonImage() throws {
    let tree = try TempTree()
    let url = tree.root.appendingPathComponent("junk.jpg")
    try Data("not an image".utf8).write(to: url)
    #expect(throws: (any Error).self) { try GrayscaleRenderer().gray32(from: url) }
}

@Test func differentImagesProduceDistantHashes() throws {
    let tree = try TempTree()
    let a = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"), seed: 0)
    let b = try Fixtures.writeImage(to: tree.root.appendingPathComponent("b.jpg"), seed: 128)
    let ha = try PerceptualHash(gray: GrayscaleRenderer().gray32(from: a))
    let hb = try PerceptualHash(gray: GrayscaleRenderer().gray32(from: b))
    #expect(ha.distance(to: hb) > 8)
}

@Test func aRecompressedCopyStaysClose() throws {
    let tree = try TempTree()
    let original = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.png"),
                                           format: .png, width: 320, height: 240)
    // sips is always present on macOS; re-encode as a low-quality JPEG.
    let recompressed = tree.root.appendingPathComponent("a-lowq.jpg")
    let sips = Process()
    sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    sips.arguments = ["-s", "format", "jpeg", "-s", "formatOptions", "30",
                      original.path, "--out", recompressed.path]
    sips.standardOutput = FileHandle.nullDevice
    sips.standardError = FileHandle.nullDevice
    try sips.run(); sips.waitUntilExit()
    try #require(sips.terminationStatus == 0)

    let a = try PerceptualHash(gray: GrayscaleRenderer().gray32(from: original))
    let b = try PerceptualHash(gray: GrayscaleRenderer().gray32(from: recompressed))
    // The whole point of a perceptual hash: quality loss must not move it far.
    #expect(a.distance(to: b) <= 8)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter PerceptualHash`
Expected: FAIL — `cannot find 'PerceptualHash' in scope`.

- [ ] **Step 3: Write GrayscaleRenderer**

```swift
import Foundation
import CoreGraphics
import ImageIO

public protocol GrayscaleRendering: Sendable {
    func gray32(from url: URL) throws -> [UInt8]
}

/// Reduces an image to the 32x32 luminance grid the perceptual hash consumes.
///
/// Not derived from the QuickLook thumbnail: QuickLook fits to aspect and may
/// pad, and for RAW it can return the camera's embedded preview rather than a
/// render of the image data. Either would make the hash describe QuickLook's
/// behaviour instead of the image.
public struct GrayscaleRenderer: GrayscaleRendering {
    public static let size = 32

    /// An intermediate downsample. Going straight from a 48-megapixel original
    /// to 32x32 in one step is both slow and aliased; ImageIO produces this
    /// step cheaply from the embedded preview when one exists.
    private static let intermediateMaxPixels = 256

    public init() {}

    public func gray32(from url: URL) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MetadataError.notAnImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.intermediateMaxPixels,
            // Apply the EXIF orientation: the hash should describe the image as
            // displayed, so a photo and its correctly-rotated export match.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MetadataError.notAnImage
        }

        let size = Self.size
        let bytesPerRow = size * 4
        var raster = [UInt8](repeating: 0, count: bytesPerRow * size)

        try raster.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw MetadataError.notAnImage }
            context.interpolationQuality = .high
            // Squashed to a square, aspect deliberately not preserved: this
            // matches photolib's `sips -z 32 32`, so a 16:9 and a 4:3 crop of
            // the same scene remain comparable.
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        }

        var gray = [UInt8](repeating: 0, count: size * size)
        for i in 0..<(size * size) {
            let at = i * 4
            let luminance = 0.2126 * Double(raster[at])
                          + 0.7152 * Double(raster[at + 1])
                          + 0.0722 * Double(raster[at + 2])
            gray[i] = UInt8(min(255, max(0, luminance.rounded())))
        }
        return gray
    }
}
```

- [ ] **Step 4: Write PerceptualHash**

```swift
import Foundation

/// A DCT perceptual hash, ported from photolib's `lib/phash.js`.
///
/// Every constant here is part of the hash's definition. Changing any of them
/// silently invalidates every hash either tool has ever stored, which is why
/// the identifier is recorded alongside the value.
public struct PerceptualHash: Sendable, Hashable {
    public static let identifier = "phash-dct-64-nodc"
    public static let gridSize = 32

    private static let block = 8
    /// Six decimal places: far above the ~1e-10 floating-point noise floor at
    /// these coefficient magnitudes, far below any real difference between
    /// distinct images. A determinism guard, not a tuning knob.
    private static let quantum = 1_000_000.0

    /// Basis functions, indexed `[u * gridSize + x]`.
    private static let cosineTable: [Double] = {
        let n = gridSize
        var table = [Double](repeating: 0, count: n * n)
        for u in 0..<n {
            let scale = u == 0 ? (1.0 / Double(n)).squareRoot() : (2.0 / Double(n)).squareRoot()
            for x in 0..<n {
                table[u * n + x] = scale * cos((2 * Double(x) + 1) * Double(u) * .pi / (2 * Double(n)))
            }
        }
        return table
    }()

    public let value: UInt64

    public var hex: String {
        let alphabet = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(16)
        for shift in stride(from: 60, through: 0, by: -4) {
            out.append(alphabet[Int((value >> UInt64(shift)) & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public init(gray: [UInt8]) throws {
        let n = Self.gridSize
        guard gray.count == n * n else {
            throw HashError.malformed("phash expects a \(n)x\(n) grid, got \(gray.count) samples")
        }

        let coefficients = Self.dct2(gray)

        var picked = [Double](repeating: 0, count: 64)
        var index = 0
        for v in 0..<Self.block {
            for u in 0..<Self.block {
                if v == 0 && u == 0 { continue }        // DC: overall brightness only
                picked[index] = (coefficients[v * n + u] * Self.quantum).rounded() / Self.quantum
                index += 1
            }
        }
        // F(0,8), replacing the discarded DC term to keep 64 informative bits.
        picked[index] = (coefficients[Self.block] * Self.quantum).rounded() / Self.quantum

        let sorted = picked.sorted()
        let median = (sorted[31] + sorted[32]) / 2

        var bits: UInt64 = 0
        for i in 0..<64 where picked[i] > median {
            bits |= UInt64(1) << UInt64(63 - i)
        }
        value = bits
    }

    public init(hex: String) throws {
        guard hex.count == 16, hex.allSatisfy({ $0.isHexDigit }),
              let parsed = UInt64(hex, radix: 16) else {
            throw HashError.malformed("not a 64-bit hash: \(hex)")
        }
        value = parsed
    }

    public init(value: UInt64) { self.value = value }

    public func distance(to other: PerceptualHash) -> Int {
        (value ^ other.value).nonzeroBitCount
    }

    /// Separable two-dimensional DCT-II, coefficients indexed `[v * n + u]`.
    private static func dct2(_ gray: [UInt8]) -> [Double] {
        let n = gridSize
        var intermediate = [Double](repeating: 0, count: n * n)
        for y in 0..<n {
            for u in 0..<n {
                var sum = 0.0
                for x in 0..<n { sum += cosineTable[u * n + x] * Double(gray[y * n + x]) }
                intermediate[y * n + u] = sum
            }
        }
        var out = [Double](repeating: 0, count: n * n)
        for u in 0..<n {
            for v in 0..<n {
                var sum = 0.0
                for y in 0..<n { sum += cosineTable[v * n + y] * intermediate[y * n + u] }
                out[v * n + u] = sum
            }
        }
        return out
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Core && swift test --filter PerceptualHash`
Expected: PASS, 12 tests. The golden-vector test is the one that matters: if it fails, the port diverged from `photolib` and the cause must be found before proceeding — do not adjust the expected values to match the code.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/LightboxCore/Hashing Core/Tests/LightboxCoreTests/PerceptualHashTests.swift
git commit -m "feat: port photolib's DCT perceptual hash with golden vectors"
```

---

### Task 11: ThumbnailCache

**Files:**
- Create: `Core/Sources/LightboxCore/Thumbnails/ThumbnailCache.swift`
- Test: `Core/Tests/LightboxCoreTests/ThumbnailCacheTests.swift`

**Interfaces:**
- Consumes: `TempTree`, `Fixtures`.
- Produces:
  - `public actor ThumbnailCache { public init(directory: URL, budgetBytes: Int64 = 2 << 30); public func thumbnail(for url: URL, mtime: Double, size: Int) async throws -> URL; public func evictIfNeeded() throws; public func cachedCount() throws -> Int }`
  - `public enum ThumbnailError: Error, Equatable { case generationFailed }`

The cache key is a SHA-256 of `path + mtime + size`, so editing a file's metadata in phase 2 invalidates its thumbnail automatically. Files are stored two levels deep (`ab/abcdef….png`) to keep any one directory small.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import LightboxCore

@Test func generatesAndCachesAThumbnail() async throws {
    let tree = try TempTree()
    let image = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"),
                                        width: 400, height: 300)
    let cache = ThumbnailCache(directory: tree.root.appendingPathComponent("cache"))

    let first = try await cache.thumbnail(for: image, mtime: 1000, size: 256)
    #expect(FileManager.default.fileExists(atPath: first.path))
    #expect(try await cache.cachedCount() == 1)

    let second = try await cache.thumbnail(for: image, mtime: 1000, size: 256)
    #expect(first == second)
    #expect(try await cache.cachedCount() == 1)   // served from cache, not regenerated
}

@Test func aChangedModificationTimeProducesADifferentCacheEntry() async throws {
    let tree = try TempTree()
    let image = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
    let cache = ThumbnailCache(directory: tree.root.appendingPathComponent("cache"))

    let before = try await cache.thumbnail(for: image, mtime: 1000, size: 256)
    let after = try await cache.thumbnail(for: image, mtime: 2000, size: 256)
    #expect(before != after)
    #expect(try await cache.cachedCount() == 2)
}

@Test func differentRequestedSizesAreCachedSeparately() async throws {
    let tree = try TempTree()
    let image = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
    let cache = ThumbnailCache(directory: tree.root.appendingPathComponent("cache"))
    let small = try await cache.thumbnail(for: image, mtime: 1000, size: 128)
    let large = try await cache.thumbnail(for: image, mtime: 1000, size: 512)
    #expect(small != large)
}

@Test func concurrentRequestsForTheSameImageProduceOneEntry() async throws {
    let tree = try TempTree()
    let image = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
    let cache = ThumbnailCache(directory: tree.root.appendingPathComponent("cache"))

    let urls = try await withThrowingTaskGroup(of: URL.self) { group in
        for _ in 0..<8 {
            group.addTask { try await cache.thumbnail(for: image, mtime: 1000, size: 256) }
        }
        var seen: [URL] = []
        for try await url in group { seen.append(url) }
        return seen
    }
    #expect(Set(urls).count == 1)
    #expect(try await cache.cachedCount() == 1)
}

@Test func throwsGenerationFailedForANonImage() async throws {
    let tree = try TempTree()
    let junk = tree.root.appendingPathComponent("junk.jpg")
    try Data("not an image".utf8).write(to: junk)
    let cache = ThumbnailCache(directory: tree.root.appendingPathComponent("cache"))
    await #expect(throws: ThumbnailError.generationFailed) {
        _ = try await cache.thumbnail(for: junk, mtime: 1000, size: 256)
    }
}

@Test func evictionRemovesTheOldestEntriesUntilUnderBudget() async throws {
    let tree = try TempTree()
    let cache = ThumbnailCache(directory: tree.root.appendingPathComponent("cache"),
                               budgetBytes: 1)   // everything is over budget
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter ThumbnailCache`
Expected: FAIL — `cannot find 'ThumbnailCache' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
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
    private var inFlight: [String: Task<URL, Error>] = [:]

    public init(directory: URL, budgetBytes: Int64 = 2 << 30) {
        self.directory = directory
        self.budgetBytes = budgetBytes
    }

    public func thumbnail(for url: URL, mtime: Double, size: Int) async throws -> URL {
        let key = Self.cacheKey(path: url.path, mtime: mtime, size: size)
        let destination = location(for: key)

        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        if let existing = inFlight[key] { return try await existing.value }

        let task = Task<URL, Error> {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: size, height: size),
                scale: 1.0,
                representationTypes: .thumbnail)
            let representation: QLThumbnailRepresentation
            do {
                representation = try await QLThumbnailGenerator.shared
                    .generateBestRepresentation(for: request)
            } catch {
                throw ThumbnailError.generationFailed
            }
            guard let destinationRef = CGImageDestinationCreateWithURL(
                destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw ThumbnailError.generationFailed
            }
            CGImageDestinationAddImage(destinationRef, representation.cgImage, nil)
            guard CGImageDestinationFinalize(destinationRef) else {
                throw ThumbnailError.generationFailed
            }
            return destination
        }

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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Core && swift test --filter ThumbnailCache`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/LightboxCore/Thumbnails Core/Tests/LightboxCoreTests/ThumbnailCacheTests.swift
git commit -m "feat: add QuickLook-backed ThumbnailCache with request coalescing and LRU eviction"
```

---

### Task 12: SearchQuery and the FTS5 sanitizer

**Files:**
- Create: `Core/Sources/LightboxCore/Search/SearchQuery.swift`
- Create: `Core/Sources/LightboxCore/Search/FTS5Query.swift`
- Test: `Core/Tests/LightboxCoreTests/SearchQueryTests.swift`
- Test: `Core/Tests/LightboxCoreTests/FTS5QueryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum NumericConstraint: Sendable, Codable, Hashable { case equal(Double), atLeast(Double), atMost(Double), between(Double, Double) }`
  - `public struct DateRange: Sendable, Codable, Hashable { public var from: Date?; public var to: Date? }`
  - `public indirect enum Predicate: Sendable, Codable, Hashable` with cases `all`, `and([Predicate])`, `or([Predicate])`, `not(Predicate)`, `width(NumericConstraint)`, `height(NumericConstraint)`, `exactDimensions(width: Int, height: Int)`, `megapixels(NumericConstraint)`, `aspectRatio(NumericConstraint)`, `fileSize(NumericConstraint)`, `fileExtension(Set<String>)`, `captureDate(DateRange)`, `modifiedDate(DateRange)`, `cameraMake(String)`, `cameraModel(String)`, `filenameText(String)`, `hasDuplicates`
  - `public struct SearchQuery: Sendable, Codable, Hashable` with `scope: Scope`, `predicate: Predicate`, `sort: Sort`, `limit: Int?`, `offset: Int?`
  - `public enum FTS5Query { public static func sanitize(_ raw: String) -> String? }`

**The sanitizer is the security-relevant piece of this task.** FTS5 has its own query grammar. Passing user text through unmodified means an unbalanced quote throws at the SQLite layer, `*` and `NEAR` change the query's meaning, and `-` and `^` are operators. The sanitizer reduces input to alphanumeric tokens, quotes each one, and joins with `AND` — user text can only ever be terms, never syntax.

- [ ] **Step 1: Write the failing sanitizer test**

```swift
import Testing
@testable import LightboxCore

@Test func quotesEachTokenAndJoinsWithAnd() {
    #expect(FTS5Query.sanitize("holiday invoice") == "\"holiday\" AND \"invoice\"*")
    #expect(FTS5Query.sanitize("beach") == "\"beach\"*")
}

@Test func neutralisesFTS5Operators() {
    // Every one of these is FTS5 syntax that must not survive as syntax.
    #expect(FTS5Query.sanitize("a NEAR b") == "\"a\" AND \"NEAR\" AND \"b\"*")
    #expect(FTS5Query.sanitize("cat OR dog") == "\"cat\" AND \"OR\" AND \"dog\"*")
    #expect(FTS5Query.sanitize("-excluded") == "\"excluded\"*")
    #expect(FTS5Query.sanitize("^anchor") == "\"anchor\"*")
    #expect(FTS5Query.sanitize("wild*card") == "\"wild\" AND \"card\"*")
    #expect(FTS5Query.sanitize("col:val") == "\"col\" AND \"val\"*")
}

@Test func survivesUnbalancedAndEmbeddedQuotes() {
    #expect(FTS5Query.sanitize("\"unclosed") == "\"unclosed\"*")
    #expect(FTS5Query.sanitize("say \"hi\" now") == "\"say\" AND \"hi\" AND \"now\"*")
}

@Test func returnsNilWhenNothingSearchableRemains() {
    #expect(FTS5Query.sanitize("") == nil)
    #expect(FTS5Query.sanitize("   ") == nil)
    #expect(FTS5Query.sanitize("*") == nil)
    #expect(FTS5Query.sanitize("\"\"\"") == nil)
    #expect(FTS5Query.sanitize("--- ^^^") == nil)
}

@Test func keepsUnicodeLettersAndDigits() {
    #expect(FTS5Query.sanitize("caf\u{e9} 2019") == "\"caf\u{e9}\" AND \"2019\"*")
    #expect(FTS5Query.sanitize("\u{6771}\u{4EAC}") == "\"\u{6771}\u{4EAC}\"*")
}

@Test func onlyTheFinalTokenIsAPrefixMatch() {
    // Search-as-you-type: the word being typed is a prefix, earlier words are
    // complete. Making every token a prefix would match far too much.
    #expect(FTS5Query.sanitize("one two three") == "\"one\" AND \"two\" AND \"three\"*")
}
```

- [ ] **Step 2: Write the failing SearchQuery test**

```swift
import Testing
import Foundation
@testable import LightboxCore

@Test func searchQueryRoundTripsThroughJSON() throws {
    let query = SearchQuery(
        scope: .folder(path: "/lib", recursive: true),
        predicate: .and([
            .exactDimensions(width: 200, height: 200),
            .not(.fileExtension(["png"])),
            .or([.cameraMake("Canon"), .cameraMake("Nikon")]),
            .captureDate(DateRange(from: Date(timeIntervalSince1970: 0), to: nil)),
            .megapixels(.between(2, 24)),
        ]),
        sort: SearchQuery.Sort(field: .captureDate, ascending: false),
        limit: 500, offset: nil)

    let data = try JSONEncoder().encode(query)
    #expect(try JSONDecoder().decode(SearchQuery.self, from: data) == query)
}

@Test func defaultQueryMatchesEverythingInAFolder() {
    let query = SearchQuery(scope: .folder(path: "/lib", recursive: false))
    #expect(query.predicate == .all)
    #expect(query.sort.field == .name)
    #expect(query.sort.ascending == true)
    #expect(query.limit == nil)
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd Core && swift test --filter "FTS5Query|SearchQuery"`
Expected: FAIL — `cannot find 'FTS5Query' in scope`.

- [ ] **Step 4: Write SearchQuery**

```swift
import Foundation

public enum NumericConstraint: Sendable, Codable, Hashable {
    case equal(Double)
    case atLeast(Double)
    case atMost(Double)
    case between(Double, Double)
}

public struct DateRange: Sendable, Codable, Hashable {
    public var from: Date?
    public var to: Date?
    public init(from: Date? = nil, to: Date? = nil) { self.from = from; self.to = to }
}

/// A search as a value: composable, comparable, and encodable, so that a saved
/// search is literally the same thing the search bar produces.
public indirect enum Predicate: Sendable, Codable, Hashable {
    case all
    case and([Predicate])
    case or([Predicate])
    case not(Predicate)

    case width(NumericConstraint)
    case height(NumericConstraint)
    case exactDimensions(width: Int, height: Int)
    case megapixels(NumericConstraint)
    case aspectRatio(NumericConstraint)
    case fileSize(NumericConstraint)
    case fileExtension(Set<String>)
    case captureDate(DateRange)
    case modifiedDate(DateRange)
    case cameraMake(String)
    case cameraModel(String)
    case filenameText(String)
    case hasDuplicates
}

public struct SearchQuery: Sendable, Codable, Hashable {
    public enum Scope: Sendable, Codable, Hashable {
        case folder(path: String, recursive: Bool)
        case everywhere
    }

    public enum SortField: String, Sendable, Codable, Hashable, CaseIterable {
        case name, captureDate, modifiedDate, size, width, height
    }

    public struct Sort: Sendable, Codable, Hashable {
        public var field: SortField
        public var ascending: Bool
        public init(field: SortField = .name, ascending: Bool = true) {
            self.field = field; self.ascending = ascending
        }
    }

    public var scope: Scope
    public var predicate: Predicate
    public var sort: Sort
    public var limit: Int?
    public var offset: Int?

    public init(scope: Scope, predicate: Predicate = .all,
                sort: Sort = Sort(), limit: Int? = nil, offset: Int? = nil) {
        self.scope = scope; self.predicate = predicate
        self.sort = sort; self.limit = limit; self.offset = offset
    }
}
```

- [ ] **Step 5: Write FTS5Query**

```swift
import Foundation

/// Turns arbitrary user text into a safe FTS5 MATCH expression.
///
/// FTS5 has a query grammar of its own: `*`, `^`, `-`, `:`, `NEAR`, `AND`,
/// `OR`, and double quotes are all syntax. Passing user text through untouched
/// means an unbalanced quote throws inside SQLite and a stray operator silently
/// changes what the user asked for. Reducing input to alphanumeric tokens and
/// quoting each one means user text can only ever be terms.
public enum FTS5Query {
    public static func sanitize(_ raw: String) -> String? {
        let tokens = raw
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return nil }

        // Quotes are doubled defensively. Tokenization already removed them,
        // but this must stay correct if the token rule is ever loosened.
        let quoted = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }

        // Only the last token is a prefix match: the user is still typing it.
        var terms = quoted
        terms[terms.count - 1] += "*"
        return terms.joined(separator: " AND ")
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd Core && swift test --filter "FTS5Query|SearchQuery"`
Expected: PASS, 8 tests.

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/LightboxCore/Search Core/Tests/LightboxCoreTests/
git commit -m "feat: add SearchQuery model and a hardened FTS5 sanitizer"
```

---

### Task 13: QueryCompiler and IndexStore.search

**Files:**
- Create: `Core/Sources/LightboxCore/Search/QueryCompiler.swift`
- Modify: `Core/Sources/LightboxCore/Index/IndexStore.swift` — add `search(_:)`
- Test: `Core/Tests/LightboxCoreTests/QueryCompilerTests.swift`

**Interfaces:**
- Consumes: `SearchQuery`, `Predicate`, `FTS5Query` (Task 12); `IndexStore`, `FileRecord` (Task 4).
- Produces:
  - `public struct CompiledQuery: Sendable { public let sql: String; public let arguments: StatementArguments }`
  - `public enum QueryCompiler { public static func compile(_ query: SearchQuery) -> CompiledQuery }`
  - `public func IndexStore.search(_ query: SearchQuery) throws -> [FileRecord]`

Every value reaches SQLite as a bound parameter. No predicate is rendered by string interpolation of user input.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import LightboxCore

private func seededStore() throws -> IndexStore {
    let store = try IndexStore.inMemory()
    func add(_ path: String, w: Int?, h: Int?, size: Int64,
             capture: Double?, make: String?, ext: String,
             content: String? = nil, image: String? = nil) throws {
        var record = FileRecord(
            id: nil, path: path,
            parentDir: (path as NSString).deletingLastPathComponent,
            name: (path as NSString).lastPathComponent, ext: ext,
            size: size, mtime: 1_700_000_000, inode: 1,
            width: w, height: h, captureTime: capture, captureOffset: nil,
            cameraMake: make, cameraModel: nil, orientation: 1,
            contentHash: content, imageHash: image, imageHashKind: nil,
            phash: nil, hashedAt: content == nil ? nil : 1, indexedAt: 1)
        record.id = nil
        _ = try store.upsert(record)
    }
    try add("/lib/icon.png", w: 200, h: 200, size: 1_000, capture: nil, make: nil, ext: "png")
    try add("/lib/beach.jpg", w: 4000, h: 3000, size: 5_000_000,
            capture: 1_550_000_000, make: "Canon", ext: "jpg")
    try add("/lib/sub/sunset-invoice.jpg", w: 1920, h: 1080, size: 900_000,
            capture: 1_600_000_000, make: "Nikon", ext: "jpg")
    try add("/lib/sub/dup-a.jpg", w: 100, h: 100, size: 500, capture: nil, make: nil,
            ext: "jpg", content: "cc", image: "ii")
    try add("/lib/sub/dup-b.jpg", w: 100, h: 100, size: 600, capture: nil, make: nil,
            ext: "jpg", content: "dd", image: "ii")
    try add("/elsewhere/other.jpg", w: 200, h: 200, size: 1_000, capture: nil, make: nil, ext: "jpg")
    return store
}

private func names(_ records: [FileRecord]) -> [String] { records.map(\.name) }

@Test func folderScopeRespectsRecursion() throws {
    let store = try seededStore()
    let shallow = try store.search(SearchQuery(scope: .folder(path: "/lib", recursive: false)))
    #expect(Set(names(shallow)) == ["icon.png", "beach.jpg"])

    let deep = try store.search(SearchQuery(scope: .folder(path: "/lib", recursive: true)))
    #expect(deep.count == 5)
    #expect(!names(deep).contains("other.jpg"))
}

@Test func everywhereScopeIgnoresFolders() throws {
    let store = try seededStore()
    #expect(try store.search(SearchQuery(scope: .everywhere)).count == 6)
}

@Test func findsExactDimensions() throws {
    let store = try seededStore()
    let found = try store.search(SearchQuery(
        scope: .everywhere, predicate: .exactDimensions(width: 200, height: 200)))
    #expect(Set(names(found)) == ["icon.png", "other.jpg"])
}

@Test func filtersOnNumericConstraints() throws {
    let store = try seededStore()
    func search(_ predicate: Predicate) throws -> [String] {
        names(try store.search(SearchQuery(scope: .everywhere, predicate: predicate)))
    }
    #expect(try search(.width(.atLeast(1920))).sorted() == ["beach.jpg", "sunset-invoice.jpg"])
    #expect(try search(.width(.atMost(200))).count == 4)
    #expect(try search(.fileSize(.between(1_000, 1_000_000))).sorted()
            == ["icon.png", "other.jpg", "sunset-invoice.jpg"])
    #expect(try search(.megapixels(.atLeast(10))) == ["beach.jpg"])
    #expect(try search(.aspectRatio(.between(1.7, 1.8))) == ["sunset-invoice.jpg"])
}

@Test func filtersOnExtensionAndCamera() throws {
    let store = try seededStore()
    let pngs = try store.search(SearchQuery(scope: .everywhere,
                                            predicate: .fileExtension(["png"])))
    #expect(names(pngs) == ["icon.png"])

    let canon = try store.search(SearchQuery(scope: .everywhere,
                                             predicate: .cameraMake("Canon")))
    #expect(names(canon) == ["beach.jpg"])
}

@Test func filtersOnCaptureDateRange() throws {
    let store = try seededStore()
    let found = try store.search(SearchQuery(
        scope: .everywhere,
        predicate: .captureDate(DateRange(from: Date(timeIntervalSince1970: 1_560_000_000),
                                          to: nil))))
    #expect(names(found) == ["sunset-invoice.jpg"])
}

@Test func searchesFilenameTextThroughFTS5() throws {
    let store = try seededStore()
    let found = try store.search(SearchQuery(scope: .everywhere,
                                             predicate: .filenameText("invoice")))
    #expect(names(found) == ["sunset-invoice.jpg"])
}

@Test func hostileSearchTextDoesNotThrow() throws {
    let store = try seededStore()
    for hostile in ["\"", "*", "NEAR", "a OR b", "-x", "^y", "c:d", "'; DROP TABLE files;--", ""] {
        let found = try store.search(SearchQuery(scope: .everywhere,
                                                 predicate: .filenameText(hostile)))
        #expect(found.count >= 0, "hostile input \(hostile) must not throw")
    }
    #expect(try store.count() == 6)   // nothing was dropped
}

@Test func findsFilesSharingAnImageHash() throws {
    let store = try seededStore()
    let found = try store.search(SearchQuery(scope: .everywhere, predicate: .hasDuplicates))
    #expect(Set(names(found)) == ["dup-a.jpg", "dup-b.jpg"])
}

@Test func composesWithAndOrNot() throws {
    let store = try seededStore()
    let found = try store.search(SearchQuery(
        scope: .folder(path: "/lib", recursive: true),
        predicate: .and([
            .not(.fileExtension(["png"])),
            .or([.width(.equal(1920)), .width(.equal(4000))]),
        ])))
    #expect(Set(names(found)) == ["beach.jpg", "sunset-invoice.jpg"])
}

@Test func sortsAndPaginates() throws {
    let store = try seededStore()
    let sorted = try store.search(SearchQuery(
        scope: .everywhere,
        sort: SearchQuery.Sort(field: .size, ascending: false), limit: 2))
    #expect(names(sorted) == ["beach.jpg", "sunset-invoice.jpg"])

    let page = try store.search(SearchQuery(
        scope: .everywhere,
        sort: SearchQuery.Sort(field: .size, ascending: false), limit: 2, offset: 2))
    #expect(names(page) == ["icon.png", "other.jpg"] || names(page) == ["other.jpg", "icon.png"])
}

@Test func anEmptyPredicateSetIsNotAMatchAll() throws {
    let store = try seededStore()
    // `.and([])` is vacuously true and `.or([])` is vacuously false. Getting
    // this backwards would silently return the whole library for an empty
    // filter panel.
    #expect(try store.search(SearchQuery(scope: .everywhere, predicate: .and([]))).count == 6)
    #expect(try store.search(SearchQuery(scope: .everywhere, predicate: .or([]))).isEmpty)
}

@Test func aFolderContainingSQLWildcardsDoesNotOverMatch() throws {
    let store = try IndexStore.inMemory()
    for path in ["/a_b/one.jpg", "/axb/two.jpg"] {
        _ = try store.upsert(FileRecord(
            id: nil, path: path, parentDir: (path as NSString).deletingLastPathComponent,
            name: (path as NSString).lastPathComponent, ext: "jpg", size: 1, mtime: 1, inode: 1,
            width: nil, height: nil, captureTime: nil, captureOffset: nil,
            cameraMake: nil, cameraModel: nil, orientation: nil, contentHash: nil,
            imageHash: nil, imageHashKind: nil, phash: nil, hashedAt: nil, indexedAt: 1))
    }
    let found = try store.search(SearchQuery(scope: .folder(path: "/a_b", recursive: true)))
    #expect(names(found) == ["one.jpg"])   // `_` must not match `x`
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter QueryCompiler`
Expected: FAIL — `cannot find 'QueryCompiler' in scope`.

- [ ] **Step 3: Write QueryCompiler**

```swift
import Foundation
import GRDB

public struct CompiledQuery: Sendable {
    public let sql: String
    public let arguments: StatementArguments
}

/// Turns a `SearchQuery` into parameterized SQL.
///
/// Every user-supplied value is a bound parameter. Nothing from the user is
/// interpolated into the statement text, including in the `LIKE` patterns used
/// for folder scoping, whose wildcards are escaped separately.
public enum QueryCompiler {
    public static func compile(_ query: SearchQuery) -> CompiledQuery {
        var arguments: [DatabaseValueConvertible?] = []

        let scopeClause = scope(query.scope, &arguments)
        let predicateClause = condition(query.predicate, &arguments)

        var sql = "SELECT * FROM files WHERE (\(scopeClause)) AND (\(predicateClause))"
        sql += " ORDER BY \(orderBy(query.sort))"
        if let limit = query.limit {
            sql += " LIMIT ?"
            arguments.append(limit)
            if let offset = query.offset {
                sql += " OFFSET ?"
                arguments.append(offset)
            }
        }
        return CompiledQuery(sql: sql, arguments: StatementArguments(arguments))
    }

    private static func scope(_ scope: SearchQuery.Scope,
                              _ arguments: inout [DatabaseValueConvertible?]) -> String {
        switch scope {
        case .everywhere:
            return "1"
        case .folder(let path, let recursive):
            let normalized = path.hasSuffix("/") && path != "/" ? String(path.dropLast()) : path
            if recursive {
                arguments.append(normalized)
                arguments.append(IndexStore.likePrefix(normalized))
                return "parent_dir = ? OR path LIKE ? ESCAPE '\\'"
            }
            arguments.append(normalized)
            return "parent_dir = ?"
        }
    }

    private static func condition(_ predicate: Predicate,
                                  _ arguments: inout [DatabaseValueConvertible?]) -> String {
        switch predicate {
        case .all:
            return "1"

        case .and(let parts):
            // Vacuously true: an empty filter panel matches everything.
            guard !parts.isEmpty else { return "1" }
            return parts.map { "(\(condition($0, &arguments)))" }.joined(separator: " AND ")

        case .or(let parts):
            // Vacuously false: "any of nothing" matches nothing.
            guard !parts.isEmpty else { return "0" }
            return parts.map { "(\(condition($0, &arguments)))" }.joined(separator: " OR ")

        case .not(let inner):
            return "NOT (\(condition(inner, &arguments)))"

        case .width(let c):
            return numeric("width", c, &arguments)
        case .height(let c):
            return numeric("height", c, &arguments)
        case .fileSize(let c):
            return numeric("size", c, &arguments)
        case .megapixels(let c):
            return numeric("(CAST(width AS REAL) * height / 1000000.0)", c, &arguments)
        case .aspectRatio(let c):
            // The height guard keeps a corrupt zero-height row from making the
            // whole query error out on division by zero.
            return "(height > 0 AND \(numeric("(CAST(width AS REAL) / height)", c, &arguments)))"

        case .exactDimensions(let width, let height):
            arguments.append(width)
            arguments.append(height)
            return "width = ? AND height = ?"

        case .fileExtension(let extensions):
            guard !extensions.isEmpty else { return "0" }
            let sorted = extensions.map { $0.lowercased() }.sorted()
            arguments.append(contentsOf: sorted as [DatabaseValueConvertible?])
            return "ext IN (\(Array(repeating: "?", count: sorted.count).joined(separator: ",")))"

        case .captureDate(let range):
            return dateRange("capture_time", range, &arguments)
        case .modifiedDate(let range):
            return dateRange("mtime", range, &arguments)

        case .cameraMake(let make):
            arguments.append(make)
            return "camera_make = ? COLLATE NOCASE"
        case .cameraModel(let model):
            arguments.append(model)
            return "camera_model = ? COLLATE NOCASE"

        case .filenameText(let text):
            guard let match = FTS5Query.sanitize(text) else { return "1" }
            arguments.append(match)
            return "id IN (SELECT rowid FROM files_fts WHERE files_fts MATCH ?)"

        case .hasDuplicates:
            return """
                (image_hash IS NOT NULL AND image_hash IN (
                    SELECT image_hash FROM files WHERE image_hash IS NOT NULL
                    GROUP BY image_hash HAVING count(*) > 1))
                OR (content_hash IS NOT NULL AND content_hash IN (
                    SELECT content_hash FROM files WHERE content_hash IS NOT NULL
                    GROUP BY content_hash HAVING count(*) > 1))
                """
        }
    }

    private static func numeric(_ column: String, _ constraint: NumericConstraint,
                                _ arguments: inout [DatabaseValueConvertible?]) -> String {
        switch constraint {
        case .equal(let value):
            arguments.append(value)
            return "\(column) = ?"
        case .atLeast(let value):
            arguments.append(value)
            return "\(column) >= ?"
        case .atMost(let value):
            arguments.append(value)
            return "\(column) <= ?"
        case .between(let low, let high):
            arguments.append(min(low, high))
            arguments.append(max(low, high))
            return "\(column) >= ? AND \(column) <= ?"
        }
    }

    private static func dateRange(_ column: String, _ range: DateRange,
                                  _ arguments: inout [DatabaseValueConvertible?]) -> String {
        var clauses: [String] = ["\(column) IS NOT NULL"]
        if let from = range.from {
            arguments.append(from.timeIntervalSince1970)
            clauses.append("\(column) >= ?")
        }
        if let to = range.to {
            arguments.append(to.timeIntervalSince1970)
            clauses.append("\(column) <= ?")
        }
        return clauses.joined(separator: " AND ")
    }

    private static func orderBy(_ sort: SearchQuery.Sort) -> String {
        let direction = sort.ascending ? "ASC" : "DESC"
        // NULLs last in both directions: a photo with no capture date belongs
        // at the end of a date sort, never at the top.
        let column = switch sort.field {
        case .name: "name COLLATE NOCASE"
        case .captureDate: "capture_time"
        case .modifiedDate: "mtime"
        case .size: "size"
        case .width: "width"
        case .height: "height"
        }
        return "(\(column)) IS NULL, \(column) \(direction), id ASC"
    }
}
```

- [ ] **Step 4: Add `search` to IndexStore**

Add to `IndexStore`, after `filesMissingHashes`:

```swift
    public func search(_ query: SearchQuery) throws -> [FileRecord] {
        let compiled = QueryCompiler.compile(query)
        return try dbq.read { db in
            try FileRecord.fetchAll(db, sql: compiled.sql, arguments: compiled.arguments)
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Core && swift test --filter QueryCompiler`
Expected: PASS, 12 tests.

- [ ] **Step 6: Run the whole suite**

Run: `cd Core && swift test`
Expected: PASS, everything from Tasks 1–13.

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/LightboxCore Core/Tests/LightboxCoreTests/QueryCompilerTests.swift
git commit -m "feat: compile SearchQuery to parameterized SQL and add IndexStore.search"
```

---

### Task 14: IndexCoordinator — tier 0

**Files:**
- Create: `Core/Sources/LightboxCore/Coordinator/IndexProgress.swift`
- Create: `Core/Sources/LightboxCore/Coordinator/IndexCoordinator.swift`
- Modify: `Core/Sources/LightboxCore/Index/IndexStore.swift` — add `deleteRows(inFolder:keeping:)`
- Test: `Core/Tests/LightboxCoreTests/IndexCoordinatorTests.swift`

**Interfaces:**
- Consumes: `Walker`/`WalkOptions` (Task 3), `IndexStore`/`FileRecord` (Task 4), `MetadataReading` (Task 5).
- Produces:
  - `public struct IndexProgress: Sendable, Hashable { public enum Phase: String, Sendable { case idle, walking, reading, hashing, paused, finished }; public var phase: Phase; public var completed: Int; public var total: Int; public var failed: Int }`
  - `public actor IndexCoordinator { public init(store: IndexStore, walker: Walker, metadata: any MetadataReading, hasher: any FileHashing, grayscale: any GrayscaleRendering, concurrency: Int); public func indexTier0(root: URL, recursive: Bool, onProgress: (@Sendable (IndexProgress) -> Void)?) throws -> IndexProgress }` — declared `throws`, not `async`; actor isolation makes every call site `try await` anyway.
  - `public func IndexStore.deleteRows(inFolder folder: String, keeping: Set<String>) throws -> Int`

**Tiering refinement, and the reason for it.** The spec's tier 0 listed thumbnails and the perceptual hash. Implementation makes both wrong for that tier:

- **Thumbnails are generated on demand by the grid, not by the indexer.** Pre-generating 50k thumbnails on folder open is minutes of work for images the user may never scroll to, and requesting them from the visible cells makes viewport priority automatic rather than something the coordinator has to model.
- **The perceptual hash moves to tier 1.** It requires decoding the image, which is the expensive thing tier 1 exists to quarantine. Tier 0 reads only ImageIO's property dictionary, which does not decode pixels.

Tier 0 is therefore: walk, stat, read metadata properties, upsert. That is fast enough to run on every folder open.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import LightboxCore

private struct StubMetadataReader: MetadataReading {
    var failingNames: Set<String> = []
    func read(_ url: URL) throws -> ImageMetadata {
        if failingNames.contains(url.lastPathComponent) { throw MetadataError.notAnImage }
        return ImageMetadata(width: 640, height: 480,
                             captureTime: Date(timeIntervalSince1970: 1_600_000_000),
                             captureOffset: "+00:00", cameraMake: "Stub", cameraModel: "S1",
                             orientation: 1)
    }
}

private struct StubHasher: FileHashing {
    func hashes(for url: URL, mediaType: MediaType) throws -> FileHashes {
        FileHashes(contentHash: "c-\(url.lastPathComponent)",
                   imageHash: "i-\(url.lastPathComponent)", imageHashKind: "jpeg-scan-v1")
    }
}

private struct StubGrayscale: GrayscaleRendering {
    func gray32(from url: URL) throws -> [UInt8] { [UInt8](repeating: 200, count: 1024) }
}

private func makeCoordinator(_ store: IndexStore,
                             metadata: StubMetadataReader = StubMetadataReader()) -> IndexCoordinator {
    IndexCoordinator(store: store, walker: Walker(), metadata: metadata,
                     hasher: StubHasher(), grayscale: StubGrayscale(), concurrency: 4)
}

@Test func tier0IndexesEveryImageInTheTree() async throws {
    let tree = try TempTree()
    try tree.file("a.jpg"); try tree.file("sub/b.png"); try tree.file("notes.txt")
    let store = try IndexStore.inMemory()

    let progress = try await makeCoordinator(store)
        .indexTier0(root: tree.root, recursive: true, onProgress: nil)

    #expect(progress.phase == .finished)
    #expect(progress.total == 2)
    #expect(progress.completed == 2)
    #expect(try store.count() == 2)

    let record = try #require(try store.record(atPath: tree.root.appendingPathComponent("a.jpg").path))
    #expect(record.width == 640)
    #expect(record.height == 480)
    #expect(record.cameraMake == "Stub")
    #expect(record.contentHash == nil)      // tier 1's job, not tier 0's
}

@Test func tier0RespectsRecursionSetting() async throws {
    let tree = try TempTree()
    try tree.file("a.jpg"); try tree.file("sub/b.jpg")
    let store = try IndexStore.inMemory()
    _ = try await makeCoordinator(store).indexTier0(root: tree.root, recursive: false, onProgress: nil)
    #expect(try store.count() == 1)
}

@Test func tier0SkipsFilesThatHaveNotChanged() async throws {
    let tree = try TempTree()
    try tree.file("a.jpg")
    let store = try IndexStore.inMemory()
    let coordinator = makeCoordinator(store)

    _ = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
    let first = try #require(try store.record(atPath: tree.root.appendingPathComponent("a.jpg").path))

    let second = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
    #expect(second.total == 1)
    #expect(second.completed == 0)          // nothing needed re-reading
    let after = try #require(try store.record(atPath: tree.root.appendingPathComponent("a.jpg").path))
    #expect(after.indexedAt == first.indexedAt)
}

@Test func tier0ReindexesAFileWhoseContentChanged() async throws {
    let tree = try TempTree()
    let url = try tree.file("a.jpg", bytes: 10)
    let store = try IndexStore.inMemory()
    let coordinator = makeCoordinator(store)
    _ = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)

    try Data(repeating: 0x42, count: 999).write(to: url)
    let second = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
    #expect(second.completed == 1)
    let record = try #require(try store.record(atPath: url.path))
    #expect(record.size == 999)
}

@Test func tier0StillIndexesAFileWhoseMetadataCannotBeRead() async throws {
    let tree = try TempTree()
    try tree.file("good.jpg"); try tree.file("bad.jpg")
    let store = try IndexStore.inMemory()
    let coordinator = makeCoordinator(store, metadata: StubMetadataReader(failingNames: ["bad.jpg"]))

    let progress = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
    #expect(progress.failed == 1)
    #expect(try store.count() == 2)         // both rows exist; one has no dimensions
    let bad = try #require(try store.record(atPath: tree.root.appendingPathComponent("bad.jpg").path))
    #expect(bad.width == nil)
    #expect(bad.size > 0)                   // the stat succeeded even though the read did not
}

@Test func tier0RemovesRowsForVanishedFiles() async throws {
    let tree = try TempTree()
    let doomed = try tree.file("gone.jpg")
    try tree.file("stays.jpg")
    let store = try IndexStore.inMemory()
    let coordinator = makeCoordinator(store)
    _ = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
    #expect(try store.count() == 2)

    try FileManager.default.removeItem(at: doomed)
    _ = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
    #expect(try store.count() == 1)
    #expect(try store.record(atPath: doomed.path) == nil)
}

@Test func aNonRecursiveScanDoesNotDeleteRowsInSubdirectories() async throws {
    let tree = try TempTree()
    try tree.file("a.jpg"); try tree.file("sub/b.jpg")
    let store = try IndexStore.inMemory()
    let coordinator = makeCoordinator(store)
    _ = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
    #expect(try store.count() == 2)

    // Re-opening the same folder with the toggle off must not orphan the
    // subdirectory's rows, or every toggle would destroy half the index.
    _ = try await coordinator.indexTier0(root: tree.root, recursive: false, onProgress: nil)
    #expect(try store.count() == 2)
}

@Test func tier0ReportsProgressMonotonically() async throws {
    let tree = try TempTree()
    for i in 0..<20 { try tree.file("img\(i).jpg") }
    let store = try IndexStore.inMemory()

    let box = Mutex<[IndexProgress]>([])
    _ = try await makeCoordinator(store).indexTier0(root: tree.root, recursive: true) { progress in
        box.withLock { $0.append(progress) }
    }
    let seen = box.withLock { $0 }
    #expect(!seen.isEmpty)
    #expect(seen.last?.phase == .finished)
    #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.completed <= $1.completed })
}

@Test func tier0StopsWhenTheTaskIsCancelled() async throws {
    let tree = try TempTree()
    for i in 0..<500 { try tree.file("img\(i).jpg") }
    let store = try IndexStore.inMemory()
    let coordinator = makeCoordinator(store)

    let task = Task { try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil) }
    task.cancel()
    _ = try? await task.value
    #expect(try store.count() < 500)
}
```

Add this small helper to `Core/Tests/LightboxCoreTests/Support/TempTree.swift`, since Swift 6 forbids capturing a mutable array in a `@Sendable` closure:

```swift
/// A minimal mutex, so tests can accumulate values from a Sendable callback.
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter IndexCoordinator`
Expected: FAIL — `cannot find 'IndexCoordinator' in scope`.

- [ ] **Step 3: Add the folder-scoped delete to IndexStore**

Add to `IndexStore`, next to `deleteRows(under:keeping:)`:

```swift
    /// Removes rows whose immediate parent is `folder` and whose paths are not
    /// in `keeping`. Used after a non-recursive scan, which knows nothing about
    /// subdirectories and must not delete their rows.
    @discardableResult
    public func deleteRows(inFolder folder: String, keeping: Set<String>) throws -> Int {
        try dbq.write { db in
            let stale = try String.fetchAll(db, sql: "SELECT path FROM files WHERE parent_dir = ?",
                                            arguments: [folder])
                .filter { !keeping.contains($0) }
            for path in stale {
                if let id = try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                                               arguments: [path]) {
                    try db.execute(sql: "DELETE FROM files_fts WHERE rowid = ?", arguments: [id])
                    try db.execute(sql: "DELETE FROM files WHERE id = ?", arguments: [id])
                }
            }
            return stale.count
        }
    }
```

- [ ] **Step 4: Write IndexProgress**

```swift
import Foundation

public struct IndexProgress: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable {
        case idle, walking, reading, hashing, paused, finished
    }

    public var phase: Phase
    /// Files actually read this pass. Files skipped as unchanged are not counted.
    public var completed: Int
    public var total: Int
    public var failed: Int

    public init(phase: Phase = .idle, completed: Int = 0, total: Int = 0, failed: Int = 0) {
        self.phase = phase; self.completed = completed; self.total = total; self.failed = failed
    }

    public var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }
}
```

- [ ] **Step 5: Write IndexCoordinator**

```swift
import Foundation

/// Drives the indexing pipeline.
///
/// Tier 0 — walk, stat, read metadata properties, upsert — runs on every folder
/// open. It decodes nothing: ImageIO's property dictionary is a header read.
/// Thumbnails are not generated here; the grid requests them for the cells it
/// is actually showing, which makes viewport priority a property of the UI
/// rather than something this actor has to model.
public actor IndexCoordinator {
    private let store: IndexStore
    private let walker: Walker
    private let metadata: any MetadataReading
    private let hasher: any FileHashing
    private let grayscale: any GrayscaleRendering
    private let concurrency: Int
    private var paused = false

    public init(store: IndexStore,
                walker: Walker = Walker(),
                metadata: any MetadataReading = MetadataReader(),
                hasher: any FileHashing = FileHasher(),
                grayscale: any GrayscaleRendering = GrayscaleRenderer(),
                concurrency: Int = 4) {
        self.store = store
        self.walker = walker
        self.metadata = metadata
        self.hasher = hasher
        self.grayscale = grayscale
        self.concurrency = max(1, concurrency)
    }

    @discardableResult
    public func indexTier0(root: URL, recursive: Bool,
                           onProgress: (@Sendable (IndexProgress) -> Void)? = nil)
        throws -> IndexProgress {
        var progress = IndexProgress(phase: .walking)
        onProgress?(progress)

        var entries: [WalkEntry] = []
        walker.scan(root: root, options: WalkOptions(includeSubdirectories: recursive)) { event in
            if case .entry(let entry) = event { entries.append(entry) }
        }

        progress.phase = .reading
        progress.total = entries.count
        onProgress?(progress)

        var livePaths = Set<String>()
        livePaths.reserveCapacity(entries.count)
        let now = Date().timeIntervalSince1970

        for entry in entries {
            if Task.isCancelled { return progress }
            livePaths.insert(entry.url.path)

            let mtime = entry.mtime.timeIntervalSince1970
            guard try store.needsReindex(path: entry.url.path, size: entry.size, mtime: mtime) else {
                continue
            }

            var record = FileRecord(entry: entry, indexedAt: now)
            // A file whose metadata cannot be read is still a file: it keeps
            // its row, its size, and its place in the grid. Losing it entirely
            // would make a corrupt image invisible rather than visibly broken.
            do {
                let read = try metadata.read(entry.url)
                record.width = read.width
                record.height = read.height
                record.captureTime = read.captureTime?.timeIntervalSince1970
                record.captureOffset = read.captureOffset
                record.cameraMake = read.cameraMake
                record.cameraModel = read.cameraModel
                record.orientation = read.orientation
            } catch {
                progress.failed += 1
            }

            _ = try store.upsert(record)
            progress.completed += 1
            if progress.completed % 25 == 0 { onProgress?(progress) }
        }

        // Reconcile: rows for files that are no longer on disk. Scoped to what
        // this scan actually looked at, so toggling recursion off does not
        // delete every subdirectory's rows.
        if recursive {
            _ = try store.deleteRows(under: root.path, keeping: livePaths)
        } else {
            _ = try store.deleteRows(inFolder: root.path, keeping: livePaths)
        }

        progress.phase = .finished
        onProgress?(progress)
        return progress
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd Core && swift test --filter IndexCoordinator`
Expected: PASS, 9 tests.

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/LightboxCore Core/Tests/LightboxCoreTests/
git commit -m "feat: add IndexCoordinator tier 0 with reconciliation and cancellation"
```

---

### Task 15: IndexCoordinator — tier 1 hashing pass

**Files:**
- Modify: `Core/Sources/LightboxCore/Coordinator/IndexCoordinator.swift` — add `runHashingPass`, `pause`, `resume`
- Test: `Core/Tests/LightboxCoreTests/HashingPassTests.swift`

**Interfaces:**
- Consumes: everything from Task 14, plus `FileHashing` (Task 9), `GrayscaleRendering`/`PerceptualHash` (Task 10).
- Produces:
  - `public func IndexCoordinator.runHashingPass(root: URL, onProgress: (@Sendable (IndexProgress) -> Void)?) async throws -> IndexProgress`
  - `public func IndexCoordinator.pause()`, `public func IndexCoordinator.resume()`, `public var IndexCoordinator.isPaused: Bool`

**The queue is the database.** Work is `hashed_at IS NULL`, drained in batches. That makes the pass resumable across a quit for free, with no separate progress record to keep in sync. It also means **a file that fails must still have `hashed_at` set**, or it is retried on every pass forever — the row records that the attempt happened, with NULL hashes.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import LightboxCore

private struct CountingHasher: FileHashing {
    let calls: Mutex<[String]>
    var failingNames: Set<String> = []
    func hashes(for url: URL, mediaType: MediaType) throws -> FileHashes {
        calls.withLock { $0.append(url.lastPathComponent) }
        if failingNames.contains(url.lastPathComponent) { throw HashError.unreadable }
        return FileHashes(contentHash: "c-\(url.lastPathComponent)",
                          imageHash: "i-\(url.lastPathComponent)",
                          imageHashKind: "jpeg-scan-v1")
    }
}

private struct StubGray: GrayscaleRendering {
    func gray32(from url: URL) throws -> [UInt8] {
        var seed = UInt32(truncatingIfNeeded: url.lastPathComponent.hashValue)
        return (0..<1024).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: seed >> 24)
        }
    }
}

private func coordinator(_ store: IndexStore, hasher: any FileHashing,
                         grayscale: any GrayscaleRendering = StubGray()) -> IndexCoordinator {
    IndexCoordinator(store: store, walker: Walker(), metadata: MetadataReader(),
                     hasher: hasher, grayscale: grayscale, concurrency: 2)
}

private func seedTier0(_ tree: TempTree, _ store: IndexStore, count: Int) async throws {
    for i in 0..<count { try tree.file("img\(i).jpg") }
    struct Stub: MetadataReading {
        func read(_ url: URL) throws -> ImageMetadata { ImageMetadata(width: 10, height: 10) }
    }
    let c = IndexCoordinator(store: store, walker: Walker(), metadata: Stub(),
                             hasher: CountingHasher(calls: Mutex([])), grayscale: StubGray())
    _ = try await c.indexTier0(root: tree.root, recursive: true, onProgress: nil)
}

@Test func hashingPassStoresAllThreeHashes() async throws {
    let tree = try TempTree(); let store = try IndexStore.inMemory()
    try await seedTier0(tree, store, count: 3)

    let hasher = CountingHasher(calls: Mutex([]))
    let progress = try await coordinator(store, hasher: hasher)
        .runHashingPass(root: tree.root, onProgress: nil)

    #expect(progress.phase == .finished)
    #expect(progress.completed == 3)
    let record = try #require(try store.record(atPath: tree.root.appendingPathComponent("img0.jpg").path))
    #expect(record.contentHash == "c-img0.jpg")
    #expect(record.imageHash == "i-img0.jpg")
    #expect(record.imageHashKind == "jpeg-scan-v1")
    #expect(record.phash?.count == 16)
    #expect(record.hashedAt != nil)
}

@Test func aSecondPassDoesNoWork() async throws {
    let tree = try TempTree(); let store = try IndexStore.inMemory()
    try await seedTier0(tree, store, count: 3)
    let hasher = CountingHasher(calls: Mutex([]))
    let c = coordinator(store, hasher: hasher)

    _ = try await c.runHashingPass(root: tree.root, onProgress: nil)
    let afterFirst = hasher.calls.withLock { $0.count }
    _ = try await c.runHashingPass(root: tree.root, onProgress: nil)
    #expect(hasher.calls.withLock { $0.count } == afterFirst)
}

@Test func aFileThatFailsIsNotRetriedForever() async throws {
    let tree = try TempTree(); let store = try IndexStore.inMemory()
    try await seedTier0(tree, store, count: 2)
    let hasher = CountingHasher(calls: Mutex([]), failingNames: ["img1.jpg"])
    let c = coordinator(store, hasher: hasher)

    let first = try await c.runHashingPass(root: tree.root, onProgress: nil)
    #expect(first.failed == 1)
    let record = try #require(try store.record(atPath: tree.root.appendingPathComponent("img1.jpg").path))
    #expect(record.hashedAt != nil)         // attempted
    #expect(record.contentHash == nil)      // but unhashed

    let callsAfterFirst = hasher.calls.withLock { $0.count }
    _ = try await c.runHashingPass(root: tree.root, onProgress: nil)
    #expect(hasher.calls.withLock { $0.count } == callsAfterFirst)
}

@Test func aReIndexedFileIsRehashed() async throws {
    let tree = try TempTree(); let store = try IndexStore.inMemory()
    try await seedTier0(tree, store, count: 1)
    let hasher = CountingHasher(calls: Mutex([]))
    _ = try await coordinator(store, hasher: hasher).runHashingPass(root: tree.root, onProgress: nil)

    let url = tree.root.appendingPathComponent("img0.jpg")
    try Data(repeating: 0x7A, count: 4321).write(to: url)
    try await seedTier0(tree, store, count: 1)   // re-runs tier 0 over the changed file

    let after = try #require(try store.record(atPath: url.path))
    #expect(after.hashedAt == nil, "changing a file must invalidate its hashes")
    #expect(after.contentHash == nil)
}

@Test func pauseStopsThePassAndResumeContinuesIt() async throws {
    let tree = try TempTree(); let store = try IndexStore.inMemory()
    try await seedTier0(tree, store, count: 40)
    let hasher = CountingHasher(calls: Mutex([]))
    let c = coordinator(store, hasher: hasher)

    await c.pause()
    let paused = try await c.runHashingPass(root: tree.root, onProgress: nil)
    #expect(paused.phase == .paused)
    #expect(paused.completed == 0)

    await c.resume()
    let resumed = try await c.runHashingPass(root: tree.root, onProgress: nil)
    #expect(resumed.phase == .finished)
    #expect(resumed.completed == 40)
}

@Test func onlyFilesUnderTheGivenRootAreHashed() async throws {
    let store = try IndexStore.inMemory()
    let inside = try TempTree(); let outside = try TempTree()
    try await seedTier0(inside, store, count: 2)
    try await seedTier0(outside, store, count: 2)

    let hasher = CountingHasher(calls: Mutex([]))
    let progress = try await coordinator(store, hasher: hasher)
        .runHashingPass(root: inside.root, onProgress: nil)
    #expect(progress.completed == 2)
    #expect(hasher.calls.withLock { $0.count } == 2)
}

@Test func hashingPassStopsOnCancellation() async throws {
    let tree = try TempTree(); let store = try IndexStore.inMemory()
    try await seedTier0(tree, store, count: 300)
    let hasher = CountingHasher(calls: Mutex([]))
    let c = coordinator(store, hasher: hasher)

    let task = Task { try await c.runHashingPass(root: tree.root, onProgress: nil) }
    task.cancel()
    _ = try? await task.value
    #expect(hasher.calls.withLock { $0.count } < 300)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter HashingPass`
Expected: FAIL — `value of type 'IndexCoordinator' has no member 'runHashingPass'`.

- [ ] **Step 3: Add the hashing pass to IndexCoordinator**

```swift
    public var isPaused: Bool { paused }
    public func pause() { paused = true }
    public func resume() { paused = false }

    /// Computes the content hash, image-data hash, and perceptual hash for
    /// every file under `root` that has not been attempted yet.
    ///
    /// The work queue is the database — rows with `hashed_at IS NULL` — so the
    /// pass resumes across a quit with no separate bookkeeping. `hashed_at` is
    /// set even when hashing fails; without that, an unreadable file would be
    /// retried on every pass for the life of the index.
    @discardableResult
    public func runHashingPass(root: URL,
                               onProgress: (@Sendable (IndexProgress) -> Void)? = nil)
        async throws -> IndexProgress {
        var progress = IndexProgress(phase: .hashing)
        progress.total = try store.countMissingHashes(under: root.path)
        onProgress?(progress)

        if paused {
            progress.phase = .paused
            onProgress?(progress)
            return progress
        }

        let batchSize = 64

        while true {
            if Task.isCancelled { return progress }
            if paused {
                progress.phase = .paused
                onProgress?(progress)
                return progress
            }

            let batch = try store.filesMissingHashes(under: root.path, limit: batchSize)
            if batch.isEmpty { break }

            let results = await withTaskGroup(of: (Int64, FileHashes?, String?).self) { group in
                var running = 0
                var iterator = batch.makeIterator()
                var collected: [(Int64, FileHashes?, String?)] = []

                func addNext() {
                    guard let record = iterator.next(), let id = record.id else { return }
                    running += 1
                    group.addTask { [hasher, grayscale] in
                        let url = URL(fileURLWithPath: record.path)
                        guard let mediaType = MediaType.forExtension(record.ext) else {
                            return (id, nil, nil)
                        }
                        let hashes = try? hasher.hashes(for: url, mediaType: mediaType)
                        let perceptual = (try? grayscale.gray32(from: url))
                            .flatMap { try? PerceptualHash(gray: $0) }?.hex
                        return (id, hashes, perceptual)
                    }
                }

                for _ in 0..<concurrency { addNext() }
                while running > 0, let result = await group.next() {
                    running -= 1
                    collected.append(result)
                    addNext()
                }
                return collected
            }

            let now = Date().timeIntervalSince1970
            for (id, hashes, perceptual) in results {
                // `hashed_at` is recorded either way: it means "attempted".
                try store.setHashes(fileID: id,
                                    content: hashes?.contentHash,
                                    image: hashes?.imageHash,
                                    imageKind: hashes?.imageHashKind,
                                    phash: perceptual,
                                    hashedAt: now)
                if hashes == nil { progress.failed += 1 } else { progress.completed += 1 }
            }
            onProgress?(progress)
        }

        progress.phase = .finished
        onProgress?(progress)
        return progress
    }
```

- [ ] **Step 4: Add `countMissingHashes` to IndexStore**

`setHashes` already accepts an optional content hash from Task 4, so only the count is new:

```swift
    public func countMissingHashes(under prefix: String) throws -> Int {
        try dbq.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM files
                WHERE hashed_at IS NULL AND (path = ? OR path LIKE ? ESCAPE '\\')
                """, arguments: [prefix, Self.likePrefix(prefix)])!
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Core && swift test --filter HashingPass`
Expected: PASS, 7 tests.

- [ ] **Step 6: Run the whole suite**

Run: `cd Core && swift test`
Expected: PASS. This is the end of the headless half of phase 1.

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/LightboxCore Core/Tests/LightboxCoreTests/
git commit -m "feat: add resumable tier 1 hashing pass with pause and failure recording"
```

---

### Task 16: App shell, folder tree, and the include-subfolders toggle

**Files:**
- Create: `App/Lightbox.xcodeproj` (via Xcode, steps below)
- Create: `App/Lightbox/LightboxApp.swift`
- Create: `App/Lightbox/BrowserModel.swift`
- Create: `App/Lightbox/Views/BrowserView.swift`
- Create: `App/Lightbox/Views/FolderTreeView.swift`
- Create: `App/Lightbox/Views/PathBarView.swift`
- Create: `Core/Sources/LightboxCore/Search/FolderNode.swift`
- Test: `Core/Tests/LightboxCoreTests/FolderNodeTests.swift`

**Interfaces:**
- Consumes: `IndexStore`, `IndexCoordinator`, `SearchQuery` from earlier tasks.
- Produces:
  - `public struct FolderNode: Sendable, Hashable, Identifiable { public let url: URL; public var id: String { url.path }; public var name: String; public static func children(of url: URL) -> [FolderNode] }`
  - `@MainActor @Observable final class BrowserModel` in the app target, with `root: URL?`, `includeSubfolders: Bool`, `records: [FileRecord]`, `progress: IndexProgress`, `open(_ url: URL) async`, `refresh() async`

The folder enumeration lives in `Core` so it is testable headless; only the views live in the app target.

- [ ] **Step 1: Create the Xcode project**

Follow exactly; the two easily-missed steps are the deployment target and the sandbox.

1. Xcode → File → New → Project → macOS → **App**.
2. Product Name `Lightbox`, Interface **SwiftUI**, Language **Swift**, Storage **None**, Testing System **None**. Uncheck "Create Git repository".
3. Save into `lightbox/App/`.
4. Target `Lightbox` → General → Minimum Deployments → **macOS 26.0**.
5. Target `Lightbox` → Signing & Capabilities → **remove the App Sandbox capability** if the template added one. The spec calls for no sandbox: with it enabled, browsing an arbitrary directory requires security-scoped bookmarks for every folder.
6. File → Add Package Dependencies → **Add Local…** → select `lightbox/Core` → add product `LightboxCore` to the `Lightbox` target.
7. Confirm the `Lightbox` group in the navigator is a **file-system synchronized group** (Xcode 16+ default, shown with a folder icon). Files dropped into `App/Lightbox/` then compile without editing `project.pbxproj`. If it is a plain group, delete it and re-add the folder as a synchronized group.

Verify from the command line:

```bash
xcodebuild -project App/Lightbox.xcodeproj -scheme Lightbox -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Write the failing FolderNode test**

```swift
import Testing
import Foundation
@testable import LightboxCore

@Test func listsOnlyDirectories() throws {
    let tree = try TempTree()
    try tree.directory("photos")
    try tree.directory("archive")
    try tree.file("loose.jpg")
    let children = FolderNode.children(of: tree.root)
    #expect(children.map(\.name) == ["archive", "photos"])   // sorted, case-insensitive
}

@Test func hidesDotDirectoriesAndOpaqueBundles() throws {
    let tree = try TempTree()
    try tree.directory("visible")
    try tree.directory(".hidden")
    try tree.directory("Old.photoslibrary")
    try tree.directory("Thing.app")
    #expect(FolderNode.children(of: tree.root).map(\.name) == ["visible"])
}

@Test func returnsEmptyForAnUnreadableOrMissingDirectory() throws {
    let tree = try TempTree()
    #expect(FolderNode.children(of: tree.root.appendingPathComponent("nope")).isEmpty)
}

@Test func sortsCaseInsensitivelyAndNaturally() throws {
    let tree = try TempTree()
    for name in ["Zebra", "apple", "Banana", "2019", "10-october"] { try tree.directory(name) }
    #expect(FolderNode.children(of: tree.root).map(\.name)
            == ["10-october", "2019", "apple", "Banana", "Zebra"])
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd Core && swift test --filter FolderNode`
Expected: FAIL — `cannot find 'FolderNode' in scope`.

- [ ] **Step 4: Write FolderNode**

```swift
import Foundation

/// One directory in the sidebar tree.
public struct FolderNode: Sendable, Hashable, Identifiable {
    public let url: URL
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public init(url: URL) { self.url = url }

    /// Immediate subdirectories, sorted for display.
    ///
    /// Shares `Walker`'s notion of what is not user content, so the sidebar and
    /// the grid never disagree about whether a folder exists.
    public static func children(of url: URL) -> [FolderNode] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return []
        }
        return names
            .filter { !Walker.isJunk($0) }
            .map { url.appendingPathComponent($0, isDirectory: true) }
            .filter { child in
                var st = stat()
                guard lstat(child.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return false }
                return !Walker.opaqueBundleExtensions.contains(child.pathExtension.lowercased())
            }
            .map(FolderNode.init(url:))
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}
```

Change `Walker.opaqueBundleExtensions` from `private static let` to `static let` so `FolderNode` can share it.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Core && swift test --filter FolderNode`
Expected: PASS, 4 tests.

- [ ] **Step 6: Write the app shell**

`App/Lightbox/BrowserModel.swift`:

```swift
import Foundation
import Observation
import LightboxCore

@MainActor
@Observable
final class BrowserModel {
    private(set) var records: [FileRecord] = []
    private(set) var progress = IndexProgress()
    private(set) var root: URL?

    var includeSubfolders = true {
        didSet { Task { await refresh() } }
    }

    var sort = SearchQuery.Sort() {
        didSet { Task { await reload() } }
    }

    private let store: IndexStore
    private let coordinator: IndexCoordinator
    private var indexingTask: Task<Void, Never>?

    init() throws {
        store = try IndexStore(url: IndexStore.defaultURL)
        coordinator = IndexCoordinator(store: store)
    }

    func open(_ url: URL) async {
        root = url
        await refresh()
    }

    /// Re-scans the current folder, then reloads the grid from the index.
    func refresh() async {
        guard let root else { return }
        indexingTask?.cancel()
        let recursive = includeSubfolders
        indexingTask = Task { [coordinator, weak self] in
            _ = try? await coordinator.indexTier0(root: root, recursive: recursive) { progress in
                Task { @MainActor in self?.progress = progress }
            }
            await self?.reload()
        }
        await indexingTask?.value
    }

    func reload() async {
        guard let root else { return }
        let query = SearchQuery(scope: .folder(path: root.path, recursive: includeSubfolders),
                                sort: sort)
        records = (try? store.search(query)) ?? []
    }

    func startHashingPass() {
        guard let root else { return }
        Task { [coordinator, weak self] in
            _ = try? await coordinator.runHashingPass(root: root) { progress in
                Task { @MainActor in self?.progress = progress }
            }
        }
    }
}
```

`App/Lightbox/LightboxApp.swift`:

```swift
import SwiftUI

@main
struct LightboxApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Folder…") { NotificationCenter.default.post(name: .openFolder, object: nil) }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let openFolder = Notification.Name("LightboxOpenFolder")
}
```

`App/Lightbox/Views/BrowserView.swift`:

```swift
import SwiftUI
import LightboxCore

struct BrowserView: View {
    @State private var model: BrowserModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let model {
                NavigationSplitView {
                    FolderTreeView(model: model)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 260)
                } detail: {
                    VStack(spacing: 0) {
                        PathBarView(model: model)
                        Divider()
                        // Task 17 replaces this with PhotoGridView.
                        Text("\(model.records.count) images")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else if let loadError {
                ContentUnavailableView("Could not open the index", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                ProgressView().task { start() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { _ in
            chooseFolder()
        }
    }

    private func start() {
        do { model = try BrowserModel() } catch { loadError = error.localizedDescription }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let model else { return }
        Task { await model.open(url) }
    }
}
```

`App/Lightbox/Views/PathBarView.swift`:

```swift
import SwiftUI

struct PathBarView: View {
    @Bindable var model: BrowserModel

    var body: some View {
        HStack(spacing: 12) {
            Text(model.root?.path ?? "No folder open")
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(model.root == nil ? .secondary : .primary)

            Spacer()

            if model.progress.phase != .finished && model.progress.phase != .idle {
                ProgressView(value: model.progress.fraction)
                    .frame(width: 120)
                Text("\(model.progress.completed)/\(model.progress.total)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Toggle("Include Subfolders", isOn: $model.includeSubfolders)
                .toggleStyle(.checkbox)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
```

`App/Lightbox/Views/FolderTreeView.swift`:

```swift
import SwiftUI
import LightboxCore

struct FolderTreeView: View {
    let model: BrowserModel
    @State private var roots: [FolderNode] = []

    var body: some View {
        List {
            OutlineGroup(roots, id: \.id, children: \.loadedChildren) { node in
                Text(node.name)
                    .onTapGesture { Task { await model.open(node.url) } }
            }
        }
        .task {
            let home = FileManager.default.homeDirectoryForCurrentUser
            roots = [FolderNode(url: home.appendingPathComponent("Pictures"))]
        }
    }
}

private extension FolderNode {
    /// `OutlineGroup` wants an optional array; nil means "no disclosure arrow".
    var loadedChildren: [FolderNode]? {
        let kids = FolderNode.children(of: url)
        return kids.isEmpty ? nil : kids
    }
}
```

- [ ] **Step 7: Verify the app runs**

```bash
xcodebuild -project App/Lightbox.xcodeproj -scheme Lightbox -configuration Debug build 2>&1 | tail -3
open App/build/Debug/Lightbox.app 2>/dev/null || xcodebuild -project App/Lightbox.xcodeproj -scheme Lightbox -configuration Debug -showBuildSettings | grep BUILT_PRODUCTS_DIR
```

Manual check: the window opens, ⌘O presents a folder picker, choosing a folder shows a non-zero image count, and toggling **Include Subfolders** changes that count.

- [ ] **Step 8: Commit**

```bash
git add App Core/Sources/LightboxCore/Search/FolderNode.swift Core/Tests/LightboxCoreTests/FolderNodeTests.swift
git commit -m "feat: add app shell, folder tree, path bar, and include-subfolders toggle"
```

---

### Task 17: PhotoGrid and the selection model

**Files:**
- Create: `Core/Sources/LightboxCore/Search/SelectionModel.swift`
- Create: `App/Lightbox/Views/PhotoGridView.swift`
- Create: `App/Lightbox/Views/ThumbnailCell.swift`
- Modify: `App/Lightbox/Views/BrowserView.swift` — swap the placeholder for the grid
- Modify: `App/Lightbox/BrowserModel.swift` — hold selection and a `ThumbnailCache`
- Test: `Core/Tests/LightboxCoreTests/SelectionModelTests.swift`

**Interfaces:**
- Consumes: `FileRecord`, `ThumbnailCache`.
- Produces:
  - `public struct SelectionModel: Sendable, Hashable { public private(set) var selected: Set<Int64>; public private(set) var anchor: Int64?; public init(); public mutating func click(_ id: Int64, in order: [Int64], shift: Bool, command: Bool); public mutating func selectAll(_ order: [Int64]); public mutating func clear(); public func neighbour(of id: Int64, in order: [Int64], offset: Int) -> Int64? }`

Selection lives in `Core` because its rules are logic, not presentation, and getting shift-click wrong is the kind of bug that is obvious in a test and invisible in a demo.

The grid is built behind a small surface — `PhotoGridView` takes records, a selection binding, and a thumbnail provider — so that if Task 18's measurement finds `LazyVGrid` inadequate, the `NSCollectionView` replacement is confined to this one file.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import LightboxCore

private let order: [Int64] = [1, 2, 3, 4, 5, 6]

@Test func plainClickReplacesTheSelection() {
    var selection = SelectionModel()
    selection.click(3, in: order, shift: false, command: false)
    #expect(selection.selected == [3])
    selection.click(5, in: order, shift: false, command: false)
    #expect(selection.selected == [5])
    #expect(selection.anchor == 5)
}

@Test func commandClickTogglesWithoutClearing() {
    var selection = SelectionModel()
    selection.click(2, in: order, shift: false, command: false)
    selection.click(4, in: order, shift: false, command: true)
    #expect(selection.selected == [2, 4])
    selection.click(2, in: order, shift: false, command: true)
    #expect(selection.selected == [4])
    #expect(selection.anchor == 2)
}

@Test func shiftClickSelectsTheRangeFromTheAnchor() {
    var selection = SelectionModel()
    selection.click(2, in: order, shift: false, command: false)
    selection.click(5, in: order, shift: true, command: false)
    #expect(selection.selected == [2, 3, 4, 5])
    #expect(selection.anchor == 2, "the anchor stays put so the range can be resized")

    // Shrinking the range replaces it rather than accumulating.
    selection.click(3, in: order, shift: true, command: false)
    #expect(selection.selected == [2, 3])
}

@Test func shiftClickWorksBackwards() {
    var selection = SelectionModel()
    selection.click(5, in: order, shift: false, command: false)
    selection.click(2, in: order, shift: true, command: false)
    #expect(selection.selected == [2, 3, 4, 5])
}

@Test func shiftClickWithNoAnchorBehavesLikeAPlainClick() {
    var selection = SelectionModel()
    selection.click(4, in: order, shift: true, command: false)
    #expect(selection.selected == [4])
    #expect(selection.anchor == 4)
}

@Test func selectAllAndClear() {
    var selection = SelectionModel()
    selection.selectAll(order)
    #expect(selection.selected.count == 6)
    selection.clear()
    #expect(selection.selected.isEmpty)
    #expect(selection.anchor == nil)
}

@Test func selectionSurvivesAnIdThatIsNoLongerInTheOrder() {
    // The grid reloads after a rescan; an id that vanished must not crash a
    // subsequent shift-click.
    var selection = SelectionModel()
    selection.click(99, in: order, shift: false, command: false)
    selection.click(3, in: order, shift: true, command: false)
    #expect(selection.selected == [3])
}

@Test func neighbourWalksTheOrderAndStopsAtTheEnds() {
    let selection = SelectionModel()
    #expect(selection.neighbour(of: 3, in: order, offset: 1) == 4)
    #expect(selection.neighbour(of: 3, in: order, offset: -1) == 2)
    #expect(selection.neighbour(of: 1, in: order, offset: -1) == 1)
    #expect(selection.neighbour(of: 6, in: order, offset: 1) == 6)
    #expect(selection.neighbour(of: 3, in: order, offset: 4) == 6)
    #expect(selection.neighbour(of: 99, in: order, offset: 1) == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter SelectionModel`
Expected: FAIL — `cannot find 'SelectionModel' in scope`.

- [ ] **Step 3: Write SelectionModel**

```swift
import Foundation

/// Finder-style multiple selection.
///
/// The anchor deliberately does not move on a shift-click: that is what lets a
/// user widen and then narrow a range by shift-clicking repeatedly, which is
/// how every macOS list behaves.
public struct SelectionModel: Sendable, Hashable {
    public private(set) var selected: Set<Int64> = []
    public private(set) var anchor: Int64?

    public init() {}

    public mutating func click(_ id: Int64, in order: [Int64], shift: Bool, command: Bool) {
        if shift, let anchor, let from = order.firstIndex(of: anchor),
           let to = order.firstIndex(of: id) {
            let range = from <= to ? from...to : to...from
            selected = Set(order[range])
            return
        }

        if command {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id
            return
        }

        selected = [id]
        anchor = id
    }

    public mutating func selectAll(_ order: [Int64]) {
        selected = Set(order)
        anchor = order.first
    }

    public mutating func clear() {
        selected = []
        anchor = nil
    }

    /// The id `offset` positions away, clamped to the ends. Returns nil when
    /// `id` is not in `order` at all.
    public func neighbour(of id: Int64, in order: [Int64], offset: Int) -> Int64? {
        guard let index = order.firstIndex(of: id) else { return nil }
        let target = min(max(0, index + offset), order.count - 1)
        return order[target]
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Core && swift test --filter SelectionModel`
Expected: PASS, 8 tests.

- [ ] **Step 5: Write the grid views**

`App/Lightbox/Views/ThumbnailCell.swift`:

```swift
import SwiftUI
import LightboxCore

struct ThumbnailCell: View {
    let record: FileRecord
    let side: CGFloat
    let isSelected: Bool
    let cache: ThumbnailCache

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if failed {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: side, height: side)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }

            Text(record.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: side)
        }
        // The task runs when the cell appears and is cancelled when it is
        // recycled, so scrolling past an image stops work on it. This is what
        // makes viewport priority automatic.
        .task(id: record.id) {
            let pixels = Int(side * 2)
            guard let url = try? await cache.thumbnail(
                for: URL(fileURLWithPath: record.path), mtime: record.mtime, size: pixels)
            else { failed = true; return }
            image = NSImage(contentsOf: url)
        }
    }
}
```

`App/Lightbox/Views/PhotoGridView.swift`:

```swift
import SwiftUI
import LightboxCore

/// The thumbnail grid.
///
/// Deliberately a thin, self-contained view over `records` plus a selection
/// binding: Task 18 measures this at 50k items, and if `LazyVGrid` does not
/// hold up, only this file is replaced by an `NSCollectionView` bridge.
struct PhotoGridView: View {
    let records: [FileRecord]
    let cache: ThumbnailCache
    @Binding var selection: SelectionModel
    let thumbnailSide: CGFloat

    private var order: [Int64] { records.compactMap(\.id) }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbnailSide + 16), spacing: 12)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(records, id: \.id) { record in
                    ThumbnailCell(record: record, side: thumbnailSide,
                                  isSelected: record.id.map { selection.selected.contains($0) } ?? false,
                                  cache: cache)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard let id = record.id else { return }
                            let flags = NSEvent.modifierFlags
                            selection.click(id, in: order,
                                            shift: flags.contains(.shift),
                                            command: flags.contains(.command))
                        }
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onTapGesture { selection.clear() }
        .focusable()
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .onKeyPress(keys: ["a"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selection.selectAll(order)
            return .handled
        }
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        guard let anchor = selection.anchor ?? order.first,
              let next = selection.neighbour(of: anchor, in: order, offset: offset)
        else { return .ignored }
        selection.click(next, in: order, shift: false, command: false)
        return .handled
    }
}
```

- [ ] **Step 6: Wire the grid into BrowserModel and BrowserView**

Add to `BrowserModel`:

```swift
    var selection = SelectionModel()
    var thumbnailSide: CGFloat = 128

    let thumbnails = ThumbnailCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lightbox/thumbnails", isDirectory: true))
```

In `BrowserView`, replace the placeholder `Text("\(model.records.count) images")` with:

```swift
                        PhotoGridView(records: model.records,
                                      cache: model.thumbnails,
                                      selection: Bindable(model).selection,
                                      thumbnailSide: model.thumbnailSide)
```

Add a size slider to `PathBarView`, before the toggle:

```swift
            Slider(value: $model.thumbnailSide, in: 64...320) { Text("Size") }
                .labelsHidden()
                .frame(width: 120)
```

- [ ] **Step 7: Verify**

```bash
cd Core && swift test
cd .. && xcodebuild -project App/Lightbox.xcodeproj -scheme Lightbox -configuration Debug build 2>&1 | tail -3
```

Manual check on a folder of a few hundred images: thumbnails appear as cells scroll into view; click, ⌘-click, shift-click, ⌘A, and arrow keys all behave as in the Finder; the size slider resizes cells.

- [ ] **Step 8: Commit**

```bash
git add App Core/Sources/LightboxCore/Search/SelectionModel.swift Core/Tests/LightboxCoreTests/SelectionModelTests.swift
git commit -m "feat: add the thumbnail grid and Finder-style selection"
```

---

### Task 18: The 50k measurement

**Files:**
- Create: `Core/Sources/LightboxCore/Diagnostics/Benchmark.swift`
- Create: `scripts/make-fixture-library.swift`
- Create: `docs/superpowers/notes/2026-09-05-grid-measurement.md`
- Modify: `App/Lightbox/Views/PhotoGridView.swift` — only if the measurement demands it

**Interfaces:**
- Consumes: `IndexCoordinator`, `IndexStore`.
- Produces: a written measurement, and a decision on whether `LazyVGrid` survives.

**This task exists because the spec refuses to spend the `NSCollectionView` complexity budget before there is a number.** It is not optional and it is not a formality: its result determines whether phases 2–4 are built on `LazyVGrid` or on an `NSCollectionView` bridge, and finding out later is far more expensive.

- [ ] **Step 1: Write the fixture generator**

`scripts/make-fixture-library.swift`:

```swift
// Generates a synthetic library for performance measurement.
// Usage: swift scripts/make-fixture-library.swift <output-dir> <count>
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

for index in 0..<count {
    let folder = root.appendingPathComponent("2019/\(String(format: "%02d", index % 12 + 1))",
                                             isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let (width, height) = sizes[index % sizes.count]

    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: Double(index % 255) / 255.0, green: 0.4, blue: 0.7, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(red: 0.1, green: Double((index * 7) % 255) / 255.0, blue: 0.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))

    let url = folder.appendingPathComponent("img\(index).jpg")
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { exit(1) }
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.6,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2019:\(String(format: "%02d", index % 12 + 1)):15 12:00:00",
        ] as [CFString: Any],
    ]
    CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    _ = CGImageDestinationFinalize(destination)

    if index % 5000 == 0 { print("\(index)/\(count)") }
}
print("done: \(count) images in \(root.path)")
```

Generate the library. This takes a while and produces several gigabytes — put it on a fast local volume, not the external drive, so the measurement isolates the grid rather than the disk:

```bash
mkdir -p ~/lightbox-bench
swift scripts/make-fixture-library.swift ~/lightbox-bench 50000
du -sh ~/lightbox-bench
```

- [ ] **Step 2: Write the indexing benchmark**

`Core/Sources/LightboxCore/Diagnostics/Benchmark.swift`:

```swift
import Foundation

/// Timings for one indexing pass, for the phase 1 performance measurement.
public struct BenchmarkResult: Sendable {
    public let fileCount: Int
    public let walkSeconds: Double
    public let tier0Seconds: Double
    public let querySeconds: Double
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

        return BenchmarkResult(fileCount: entries, walkSeconds: walkSeconds,
                               tier0Seconds: tier0Seconds, querySeconds: querySeconds)
    }
}
```

- [ ] **Step 3: Add a frame-time overlay to the app**

Add to `PhotoGridView`, so scroll smoothness is measurable without Instruments. Gate it behind a launch argument so it never ships in a normal run:

```swift
    @State private var frameTimes: [Double] = []
    @State private var lastFrame = Date()

    private var showsFrameTimes: Bool {
        ProcessInfo.processInfo.arguments.contains("--measure-frames")
    }
```

and overlay it on the `ScrollView`:

```swift
        .overlay(alignment: .topTrailing) {
            if showsFrameTimes, !frameTimes.isEmpty {
                let sorted = frameTimes.sorted()
                let median = sorted[sorted.count / 2] * 1000
                let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))] * 1000
                Text(String(format: "median %.1f ms  p99 %.1f ms  n=%d",
                            median, p99, frameTimes.count))
                    .font(.caption.monospaced())
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
            }
        }
        .onScrollGeometryChange(for: CGFloat.self, of: \.contentOffset.y) { _, _ in
            guard showsFrameTimes else { return }
            let now = Date()
            frameTimes.append(now.timeIntervalSince(lastFrame))
            lastFrame = now
            if frameTimes.count > 2000 { frameTimes.removeFirst(1000) }
        }
```

- [ ] **Step 4: Run the measurement**

Add `Core/Tests/LightboxCoreTests/BenchmarkTests.swift`. It is disabled by
default so a normal `swift test` never spends minutes on it, and is run
explicitly for the measurement:

```swift
import Testing
import Foundation
@testable import LightboxCore

@Test(.disabled("benchmark: run explicitly for the phase 1 measurement"))
func measureIndexingOfFiftyThousandImages() async throws {
    let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("lightbox-bench")
    try #require(FileManager.default.fileExists(atPath: root.path),
                 "run scripts/make-fixture-library.swift first")

    let result = try await Benchmark.indexingPass(root: root)
    print("files:  \(result.fileCount)")
    print(String(format: "walk:   %.2fs", result.walkSeconds))
    print(String(format: "tier 0: %.2fs", result.tier0Seconds))
    print(String(format: "query:  %.3fs", result.querySeconds))

    #expect(result.fileCount == 50_000)
    #expect(result.querySeconds < 0.1)
}
```

Run it:

```bash
cd Core && swift test --filter measureIndexingOfFiftyThousandImages --no-parallel 2>&1 | tail -20
```

Swift Testing skips `.disabled` tests even when named by `--filter`; temporarily
comment out the `.disabled` trait to run it, and restore the trait before
committing.

Then launch the app with `--measure-frames`, open `~/lightbox-bench` with **Include Subfolders** on, and scroll continuously from top to bottom at speed. Also record peak memory from Activity Monitor.

- [ ] **Step 5: Record the results and decide**

Write `docs/superpowers/notes/2026-09-05-grid-measurement.md` with the actual numbers, and judge against these thresholds:

| Measure | Threshold | Meaning if it fails |
|---|---|---|
| Tier 0 over 50k files | under 3 minutes | The pipeline, not the grid, needs work |
| Folder open to first thumbnails visible | under 1.5 s | The initial query or the grid's first layout is too slow |
| Median scroll frame time | ≤ 16.7 ms | — |
| 99th-percentile scroll frame time | ≤ 33 ms | Dropped frames during fast scroll |
| Peak resident memory while scrolling | under 2 GB | Cells or thumbnails are not being released |
| `width >= 1920` query over 50k rows | under 100 ms | An index is missing |

**If the frame-time or memory thresholds fail, replace `LazyVGrid` with an `NSCollectionView` bridge inside `PhotoGridView.swift` and only that file.** Re-run the measurement afterwards and record both sets of numbers, so the cost of the swap is documented rather than assumed.

- [ ] **Step 6: Commit**

```bash
git add scripts Core/Sources/LightboxCore/Diagnostics docs/superpowers/notes App
git commit -m "perf: measure the grid at 50k images and record the result"
```

---

### Task 19: Search bar, filter panel, and the metadata inspector

**Files:**
- Create: `App/Lightbox/Views/FilterPanelView.swift`
- Create: `App/Lightbox/Views/InspectorView.swift`
- Modify: `App/Lightbox/BrowserModel.swift` — hold the query, drive facets
- Modify: `App/Lightbox/Views/BrowserView.swift` — three panes
- Modify: `App/Lightbox/Views/PathBarView.swift` — search field, sort control
- Modify: `Core/Sources/LightboxCore/Index/IndexStore.swift` — add `facets(for:)`
- Test: `Core/Tests/LightboxCoreTests/FacetTests.swift`

**Interfaces:**
- Consumes: `SearchQuery`, `QueryCompiler`, `IndexStore`.
- Produces:
  - `public struct Facets: Sendable, Hashable { public let byExtension: [String: Int]; public let byCamera: [String: Int]; public let total: Int }`
  - `public func IndexStore.facets(for query: SearchQuery) throws -> Facets`

The inspector is **read-only in phase 1**. Editing arrives in phase 2 with `MetadataWriter`; building an editable field now would mean building it twice.

- [ ] **Step 1: Write the failing facet test**

```swift
import Testing
import Foundation
@testable import LightboxCore

private func store(_ rows: [(String, String, String?)]) throws -> IndexStore {
    let store = try IndexStore.inMemory()
    for (path, ext, make) in rows {
        _ = try store.upsert(FileRecord(
            id: nil, path: path, parentDir: (path as NSString).deletingLastPathComponent,
            name: (path as NSString).lastPathComponent, ext: ext, size: 10, mtime: 1, inode: 1,
            width: 100, height: 100, captureTime: nil, captureOffset: nil,
            cameraMake: make, cameraModel: nil, orientation: 1, contentHash: nil,
            imageHash: nil, imageHashKind: nil, phash: nil, hashedAt: nil, indexedAt: 1))
    }
    return store
}

@Test func countsByExtensionAndCamera() throws {
    let s = try store([
        ("/l/a.jpg", "jpg", "Canon"), ("/l/b.jpg", "jpg", "Canon"),
        ("/l/c.png", "png", nil), ("/l/d.heic", "heic", "Apple"),
    ])
    let facets = try s.facets(for: SearchQuery(scope: .everywhere))
    #expect(facets.total == 4)
    #expect(facets.byExtension == ["jpg": 2, "png": 1, "heic": 1])
    #expect(facets.byCamera == ["Canon": 2, "Apple": 1])   // NULL cameras are not a bucket
}

@Test func facetsRespectTheCurrentPredicate() throws {
    let s = try store([
        ("/l/a.jpg", "jpg", "Canon"), ("/l/sub/b.jpg", "jpg", "Canon"), ("/l/c.png", "png", nil),
    ])
    let facets = try s.facets(for: SearchQuery(scope: .folder(path: "/l", recursive: false)))
    #expect(facets.total == 2)
    #expect(facets.byExtension == ["jpg": 1, "png": 1])
}

@Test func facetsOfAnEmptyResultAreEmptyNotAbsent() throws {
    let s = try store([("/l/a.jpg", "jpg", "Canon")])
    let facets = try s.facets(for: SearchQuery(scope: .everywhere,
                                               predicate: .fileExtension(["gif"])))
    #expect(facets.total == 0)
    #expect(facets.byExtension.isEmpty)
    #expect(facets.byCamera.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter Facet`
Expected: FAIL — `value of type 'IndexStore' has no member 'facets'`.

- [ ] **Step 3: Add facets to IndexStore**

```swift
public struct Facets: Sendable, Hashable {
    public let byExtension: [String: Int]
    public let byCamera: [String: Int]
    public let total: Int
}

extension IndexStore {
    /// Counts for the filter panel, computed over the *current* result set so
    /// the numbers describe what narrowing would actually do.
    public func facets(for query: SearchQuery) throws -> Facets {
        let compiled = QueryCompiler.compile(query)
        return try dbq.read { db in
            func counts(_ column: String) throws -> [String: Int] {
                let sql = """
                    SELECT \(column) AS bucket, count(*) AS n
                    FROM (\(compiled.sql))
                    WHERE \(column) IS NOT NULL AND \(column) <> ''
                    GROUP BY bucket
                    """
                var result: [String: Int] = [:]
                for row in try Row.fetchAll(db, sql: sql, arguments: compiled.arguments) {
                    result[row["bucket"]] = row["n"]
                }
                return result
            }
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM (\(compiled.sql))",
                                         arguments: compiled.arguments) ?? 0
            return Facets(byExtension: try counts("ext"),
                          byCamera: try counts("camera_make"),
                          total: total)
        }
    }
}
```

**Note:** `compiled.sql` may carry a `LIMIT`. Facets must describe the whole result set, so build them from a query with `limit` and `offset` cleared:

```swift
        var unlimited = query
        unlimited.limit = nil
        unlimited.offset = nil
        let compiled = QueryCompiler.compile(unlimited)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Core && swift test --filter Facet`
Expected: PASS, 3 tests.

- [ ] **Step 5: Add search and filter state to BrowserModel**

```swift
    var searchText = "" {
        didSet { Task { await reload() } }
    }
    var selectedExtensions: Set<String> = [] {
        didSet { Task { await reload() } }
    }
    var minimumWidth: Double? {
        didSet { Task { await reload() } }
    }
    private(set) var facets = Facets(byExtension: [:], byCamera: [:], total: 0)

    private var currentQuery: SearchQuery? {
        guard let root else { return nil }
        var parts: [Predicate] = []
        if !searchText.isEmpty { parts.append(.filenameText(searchText)) }
        if !selectedExtensions.isEmpty { parts.append(.fileExtension(selectedExtensions)) }
        if let minimumWidth { parts.append(.width(.atLeast(minimumWidth))) }
        return SearchQuery(scope: .folder(path: root.path, recursive: includeSubfolders),
                           predicate: parts.isEmpty ? .all : .and(parts),
                           sort: sort)
    }
```

Replace the body of `reload()`:

```swift
    func reload() async {
        guard let query = currentQuery else { return }
        records = (try? store.search(query)) ?? []
        facets = (try? store.facets(for: query))
            ?? Facets(byExtension: [:], byCamera: [:], total: 0)
        // Drop selections for rows that are no longer in the result set.
        let living = Set(records.compactMap(\.id))
        if !selection.selected.isSubset(of: living) {
            var replacement = SelectionModel()
            for id in selection.selected where living.contains(id) {
                replacement.click(id, in: Array(living), shift: false, command: true)
            }
            selection = replacement
        }
    }
```

- [ ] **Step 6: Write the filter panel and inspector**

`App/Lightbox/Views/FilterPanelView.swift`:

```swift
import SwiftUI
import LightboxCore

struct FilterPanelView: View {
    @Bindable var model: BrowserModel

    private static let widthPresets: [(String, Double?)] = [
        ("Any width", nil), ("≥ 1000 px", 1000), ("≥ 1920 px", 1920), ("≥ 4000 px", 4000),
    ]

    var body: some View {
        Form {
            Section("File type") {
                ForEach(model.facets.byExtension.sorted(by: { $0.key < $1.key }), id: \.key) { ext, count in
                    Toggle(isOn: Binding(
                        get: { model.selectedExtensions.contains(ext) },
                        set: { on in
                            if on { model.selectedExtensions.insert(ext) }
                            else { model.selectedExtensions.remove(ext) }
                        })) {
                        HStack {
                            Text(".\(ext)")
                            Spacer()
                            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                if model.facets.byExtension.isEmpty {
                    Text("No matches").foregroundStyle(.secondary)
                }
            }

            Section("Dimensions") {
                Picker("Width", selection: Binding(
                    get: { model.minimumWidth },
                    set: { model.minimumWidth = $0 })) {
                    ForEach(Self.widthPresets, id: \.0) { label, value in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section("Camera") {
                ForEach(model.facets.byCamera.sorted(by: { $0.key < $1.key }), id: \.key) { make, count in
                    HStack {
                        Text(make)
                        Spacer()
                        Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }

            Section("Content hashes") {
                Button("Compute hashes for this folder") { model.startHashingPass() }
                    .disabled(model.root == nil)
                Text("Reads every file. Needed for duplicate detection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
```

`App/Lightbox/Views/InspectorView.swift`:

```swift
import SwiftUI
import LightboxCore

/// Read-only in phase 1. Editing arrives with MetadataWriter in phase 2.
struct InspectorView: View {
    let records: [FileRecord]

    var body: some View {
        Form {
            if records.isEmpty {
                Text("No selection").foregroundStyle(.secondary)
            } else {
                Section(records.count == 1 ? records[0].name : "\(records.count) images selected") {
                    row("Dimensions", shared { record in
                        guard let w = record.width, let h = record.height else { return nil }
                        return "\(w) × \(h)"
                    })
                    row("Size", shared { ByteCountFormatter.string(fromByteCount: $0.size,
                                                                   countStyle: .file) })
                    row("Captured", shared { record in
                        record.captureDate.map { Self.dateFormatter.string(from: $0) }
                    })
                    row("Time zone", shared(\.captureOffset))
                    row("Camera", shared { record in
                        [record.cameraMake, record.cameraModel].compactMap { $0 }
                            .joined(separator: " ").nilIfEmpty
                    })
                    row("Modified", shared { Self.dateFormatter.string(from: $0.modifiedDate) })
                }

                Section("Hashes") {
                    row("Content", shared(\.contentHash).map { String($0.prefix(16)) + "…" })
                    row("Image data", shared(\.imageHash).map { String($0.prefix(16)) + "…" })
                    row("Rule", shared(\.imageHashKind))
                    row("Perceptual", shared(\.phash))
                    if records.contains(where: { $0.hashedAt == nil }) {
                        Text("Not yet hashed").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        LabeledContent(label) {
            Text(value ?? (records.count > 1 ? "(multiple values)" : "—"))
                .foregroundStyle(value == nil ? .secondary : .primary)
                .textSelection(.enabled)
        }
    }

    /// The value if every selected record agrees on it, otherwise nil — which
    /// the row renders as "(multiple values)".
    private func shared(_ extract: (FileRecord) -> String?) -> String? {
        let values = Set(records.map(extract).map { $0 ?? "" })
        guard values.count == 1, let only = values.first, !only.isEmpty else { return nil }
        return only
    }

    private func shared(_ keyPath: KeyPath<FileRecord, String?>) -> String? {
        shared { $0[keyPath: keyPath] }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
```

- [ ] **Step 7: Assemble the three panes**

In `BrowserView`, replace the `NavigationSplitView` body with:

```swift
                NavigationSplitView {
                    VStack(spacing: 0) {
                        FolderTreeView(model: model)
                        Divider()
                        FilterPanelView(model: model)
                    }
                    .navigationSplitViewColumnWidth(min: 220, ideal: 280)
                } detail: {
                    HSplitView {
                        VStack(spacing: 0) {
                            PathBarView(model: model)
                            Divider()
                            PhotoGridView(records: model.records,
                                          cache: model.thumbnails,
                                          selection: Bindable(model).selection,
                                          thumbnailSide: model.thumbnailSide)
                        }
                        InspectorView(records: model.records.filter {
                            $0.id.map { model.selection.selected.contains($0) } ?? false
                        })
                        .frame(minWidth: 260, idealWidth: 300)
                    }
                }
```

Add the search field and sort control to `PathBarView`, after the path text:

```swift
            TextField("Search filenames", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            Picker("Sort", selection: $model.sort.field) {
                ForEach(SearchQuery.SortField.allCases, id: \.self) { field in
                    Text(field.rawValue).tag(field)
                }
            }
            .frame(width: 140)
```

- [ ] **Step 8: Verify**

```bash
cd Core && swift test
cd .. && xcodebuild -project App/Lightbox.xcodeproj -scheme Lightbox -configuration Debug build 2>&1 | tail -3
```

Manual checks against a real folder:
- Typing in the search field narrows the grid, and typing a partial word still matches.
- Typing `"` or `*` into the search field narrows or clears the grid but never crashes.
- Ticking a file-type filter narrows the grid and the facet counts update.
- Selecting one image populates the inspector; selecting two with different dimensions shows `(multiple values)`.
- "Compute hashes for this folder" shows progress and, once finished, fills the inspector's hash rows.

- [ ] **Step 9: Commit**

```bash
git add App Core/Sources/LightboxCore Core/Tests/LightboxCoreTests/FacetTests.swift
git commit -m "feat: add search, faceted filters, and the read-only metadata inspector"
```

---

---

### Task 20: Index integrity check and rebuild

**Files:**
- Modify: `Core/Sources/LightboxCore/Index/IndexStore.swift` — add `checkIntegrity()` and `IndexStore.rebuild(at:)`
- Modify: `App/Lightbox/BrowserModel.swift` — check at launch
- Modify: `App/Lightbox/Views/BrowserView.swift` — offer the rebuild
- Test: `Core/Tests/LightboxCoreTests/IntegrityTests.swift`

**Interfaces:**
- Consumes: `IndexStore` (Task 4).
- Produces:
  - `public enum IndexHealth: Sendable, Equatable { case ok, corrupt(String) }`
  - `public func IndexStore.checkIntegrity() -> IndexHealth`
  - `public static func IndexStore.rebuild(at url: URL) throws -> IndexStore`

The spec requires that a corrupt index be detected at launch and offer a rebuild rather than leaving the app unusable. The index is a derived cache — every row can be recomputed by walking the disk again — so discarding and recreating it is always safe, which is exactly why this is a one-button recovery and not a repair tool.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import LightboxCore

@Test func aHealthyIndexReportsOK() throws {
    let store = try IndexStore.inMemory()
    #expect(store.checkIntegrity() == .ok)
}

@Test func aTruncatedDatabaseFileIsReportedCorrupt() throws {
    let tree = try TempTree()
    let url = tree.root.appendingPathComponent("index.sqlite")
    _ = try IndexStore(url: url)          // create and close

    // Overwrite the SQLite header with garbage.
    let handle = try FileHandle(forWritingTo: url)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Data(repeating: 0x7F, count: 64))
    try handle.close()

    // Opening may throw outright, or open and fail the check. Either counts as
    // detection; what must not happen is silent acceptance.
    if let store = try? IndexStore(url: url) {
        guard case .corrupt = store.checkIntegrity() else {
            Issue.record("a corrupted database was reported healthy")
            return
        }
    }
}

@Test func rebuildReplacesTheFileWithAnEmptyIndex() throws {
    let tree = try TempTree()
    let url = tree.root.appendingPathComponent("index.sqlite")
    let store = try IndexStore(url: url)
    _ = try store.upsert(FileRecord(
        id: nil, path: "/a/b.jpg", parentDir: "/a", name: "b.jpg", ext: "jpg",
        size: 1, mtime: 1, inode: 1, width: nil, height: nil, captureTime: nil,
        captureOffset: nil, cameraMake: nil, cameraModel: nil, orientation: nil,
        contentHash: nil, imageHash: nil, imageHashKind: nil, phash: nil,
        hashedAt: nil, indexedAt: 1))
    #expect(try store.count() == 1)

    let rebuilt = try IndexStore.rebuild(at: url)
    #expect(try rebuilt.count() == 0)
    #expect(rebuilt.checkIntegrity() == .ok)
    #expect(try rebuilt.tableNames().contains("files"))
}

@Test func rebuildWorksEvenWhenNoFileExists() throws {
    let tree = try TempTree()
    let url = tree.root.appendingPathComponent("nested/index.sqlite")
    let rebuilt = try IndexStore.rebuild(at: url)
    #expect(try rebuilt.count() == 0)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter Integrity`
Expected: FAIL — `value of type 'IndexStore' has no member 'checkIntegrity'`.

- [ ] **Step 3: Add integrity support to IndexStore**

```swift
public enum IndexHealth: Sendable, Equatable {
    case ok
    case corrupt(String)
}

extension IndexStore {
    /// Runs SQLite's own integrity check.
    ///
    /// Quick rather than full: a full check on a 50k-row database is fast, but
    /// this runs at every launch and `quick_check` catches the failures that
    /// matter — a truncated file, a torn page — without the cost.
    public func checkIntegrity() -> IndexHealth {
        do {
            let result = try dbq.read { db in
                try String.fetchOne(db, sql: "PRAGMA quick_check")
            }
            return result == "ok" ? .ok : .corrupt(result ?? "unknown")
        } catch {
            return .corrupt(error.localizedDescription)
        }
    }

    /// Deletes the index and creates an empty one.
    ///
    /// Always safe: the index is a derived cache. Every row it holds can be
    /// recomputed by walking the disk, so nothing the user created is lost —
    /// only time.
    public static func rebuild(at url: URL) throws -> IndexStore {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if manager.fileExists(atPath: sidecar.path) {
                try manager.removeItem(at: sidecar)
            }
        }
        return try IndexStore(url: url)
    }
}
```

- [ ] **Step 4: Check at launch in BrowserModel**

Replace `BrowserModel.init()` with:

```swift
    init() throws {
        let url = IndexStore.defaultURL
        if let opened = try? IndexStore(url: url), opened.checkIntegrity() == .ok {
            store = opened
        } else {
            // The index is a cache. Rebuilding costs a rescan, never data.
            store = try IndexStore.rebuild(at: url)
            didRebuildIndex = true
        }
        coordinator = IndexCoordinator(store: store)
    }

    private(set) var didRebuildIndex = false
```

In `BrowserView`, surface it once so the rescan is not mysterious — add to the `NavigationSplitView`'s detail column:

```swift
                    .overlay(alignment: .top) {
                        if model.didRebuildIndex {
                            Text("The index was damaged and has been rebuilt. Folders will be rescanned as you open them.")
                                .font(.callout)
                                .padding(8)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                .padding(8)
                        }
                    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Core && swift test --filter Integrity`
Expected: PASS, 4 tests.

- [ ] **Step 6: Run the whole suite and build the app**

```bash
cd Core && swift test
cd .. && xcodebuild -project App/Lightbox.xcodeproj -scheme Lightbox -configuration Debug build 2>&1 | tail -3
```

- [ ] **Step 7: Commit**

```bash
git add Core App
git commit -m "feat: detect a corrupt index at launch and rebuild it"
```

---

## Definition of done for phase 1

- [ ] `cd Core && swift test` passes with no skipped tests other than those gated on exiftool being absent.
- [ ] `xcodebuild -project App/Lightbox.xcodeproj -scheme Lightbox build` succeeds.
- [ ] Opening a real folder shows thumbnails; the include-subfolders toggle changes what is shown.
- [ ] Searching `200x200` via the dimension filter finds exactly the 200×200 images.
- [ ] The hashing pass completes over a real folder, survives being quit halfway and resumed, and does not re-hash on a second run.
- [ ] `docs/superpowers/notes/2026-09-05-grid-measurement.md` exists and records real numbers.
- [ ] A deliberately corrupted index is detected at launch and rebuilt rather than crashing.
- [ ] No task left a red test behind.
