import Foundation
import Testing

enum TempDirectoryError: Error, CustomStringConvertible {
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
/// A near-twin of `Core`'s `TempTree`, which lives in the `Core` test target
/// and is not visible here. Same contract for the same reason: a directory left
/// at mode `0o000` defeats `removeItem`, so the original mode of anything
/// changed through `chmod(_:_:)` is recorded and restored before removal —
/// otherwise a test that locks a directory leaks its whole tree into the
/// temporary directory, and `try?` cleanup makes that leak invisible.
final class TempDirectory {
    let root: URL

    private var originalModes: [String: NSNumber] = [:]
    private var isCleanedUp = false

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lightbox-app-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        do {
            try cleanup()
        } catch {
            // A deinit cannot throw, but a leaked tree must not pass silently.
            Issue.record("TempDirectory cleanup failed for \(root.path): \(error)")
        }
    }

    func cleanup() throws {
        guard !isCleanedUp else { return }
        isCleanedUp = true
        for (path, mode) in originalModes {
            try? FileManager.default.setAttributes([.posixPermissions: mode],
                                                   ofItemAtPath: path)
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

    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func chmod(_ relativePath: String, _ mode: Int) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        if originalModes[url.path] == nil {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let current = attributes[.posixPermissions] as? NSNumber else {
                throw TempDirectoryError.noPosixPermissions(url.path)
            }
            originalModes[url.path] = current
        }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)],
                                               ofItemAtPath: url.path)
        return url
    }
}
