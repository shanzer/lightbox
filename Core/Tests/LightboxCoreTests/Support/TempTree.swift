import Foundation
import Testing

enum TempTreeError: Error, CustomStringConvertible {
    case noPosixPermissions(String)

    var description: String {
        switch self {
        case .noPosixPermissions(let path):
            "no POSIX permissions reported for \(path)"
        }
    }
}

/// A throwaway directory tree, removed when the instance is released.
///
/// Permission changes must go through `chmod(_:_:)` rather than `FileManager`
/// directly. A directory left at mode `0o000` defeats `removeItem`, so the
/// original mode of anything changed is recorded and restored before removal —
/// otherwise a test that locks a directory leaks its whole tree into the
/// temporary directory, and `try?` cleanup makes that leak invisible.
final class TempTree {
    let root: URL

    /// Original POSIX modes, keyed by absolute path, captured the first time
    /// each path is changed so repeated `chmod` calls cannot lose the real one.
    private var originalModes: [String: NSNumber] = [:]
    private var isCleanedUp = false

    /// A suffix unique to this instance, minted once and shared by every call
    /// to `uniqueName(_:ext:)`. Each test builds its own `TempTree`, so this
    /// tags every fixture that test creates — which matters for a fixture
    /// that leaves the tree altogether, the way a trashed file lands in the
    /// developer's real `~/.Trash`. Two tests trashing same-named fixtures at
    /// once is exactly how `swift test`'s parallel suites collide there:
    /// Finder's Trash de-duplicates by name, so two `IMG_0001.CR2`s racing
    /// into it fight over one slot. A per-instance tag means no two tests
    /// ever offer the same name to begin with.
    private lazy var tag = String(UUID().uuidString.prefix(8))

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lightbox-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        do {
            try cleanup()
        } catch {
            // A deinit cannot throw, but a leaked tree must not pass silently:
            // surface it as a test issue instead of swallowing it.
            Issue.record("TempTree cleanup failed for \(root.path): \(error)")
        }
    }

    /// Restores every mode changed through `chmod` and removes the tree.
    ///
    /// Idempotent, so a suite may call it explicitly and `deinit` may call it
    /// again. Removal failure is thrown rather than ignored.
    func cleanup() throws {
        guard !isCleanedUp else { return }
        isCleanedUp = true

        // Shallowest first: a parent must be traversable again before a child
        // inside it can be restored.
        let byDepth = originalModes.keys.sorted {
            let a = $0.split(separator: "/").count, b = $1.split(separator: "/").count
            return a == b ? $0 < $1 : a < b
        }
        for path in byDepth {
            // Best effort: a restore failure surfaces as the removal failure below.
            try? FileManager.default.setAttributes(
                [.posixPermissions: originalModes[path]!], ofItemAtPath: path)
        }

        try FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func file(_ relativePath: String, bytes: Int = 8) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// Mints `"<stem>-<tag>.<ext>"`, a fixture name unique to this tree.
    /// A companion shares its sibling's tag by passing the same `stem`:
    /// `uniqueName("IMG_0001", ext: "CR2")` and `uniqueName("IMG_0001", ext: "xmp")`
    /// still pair up on the shared stem, just not on the literal `"IMG_0001"`
    /// a concurrently running test might also choose.
    func uniqueName(_ stem: String, ext: String) -> String {
        "\(stem)-\(tag).\(ext)"
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

    /// Sets the POSIX mode of an existing item, remembering the mode it had so
    /// cleanup can put it back.
    @discardableResult
    func chmod(_ relativePath: String, _ mode: Int) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        if originalModes[url.path] == nil {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let current = attributes[.posixPermissions] as? NSNumber else {
                throw TempTreeError.noPosixPermissions(url.path)
            }
            originalModes[url.path] = current
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
        return url
    }
}
