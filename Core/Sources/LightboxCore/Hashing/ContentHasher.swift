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
        var digest = SHA256()
        try stream(url) { digest.update(data: $0) }
        return digest.finalize().hexEncoded
    }

    /// The file's entire contents, read through the same loop as `hash(_:)`.
    ///
    /// Exists so a caller that needs the bytes themselves — the image-data
    /// parsers, which have to walk a file's structure — gets one read whose
    /// every failure is a `HashError`. `Data(contentsOf:, .mappedIfSafe)` would
    /// be the obvious alternative and is the wrong one: a mid-read `EIO` on a
    /// failing external volume arrives as `SIGBUS` through a mapping, which
    /// cannot be caught and cannot be turned into `.truncated`.
    public func readWholeFile(_ url: URL) throws -> Data {
        var out = Data()
        if let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int, size > 0 {
            // A hint only. The loop below is still what decides how many bytes
            // there really are, so a stale or lying size cannot truncate it.
            out.reserveCapacity(size)
        }
        try stream(url) { out.append($0) }
        return out
    }

    /// Reads `url` in `bufferSize` chunks, handing each to `consume`.
    ///
    /// Shared by `hash(_:)` and `readWholeFile(_:)` so the two cannot disagree
    /// about what counts as a clean end-of-file or an I/O error.
    private func stream(_ url: URL, _ consume: (Data) -> Void) throws {
        // Opened via raw POSIX `open` rather than `FileHandle(forReadingFrom:)`:
        // on this toolchain the latter pre-emptively rejects directories (and
        // similar non-regular-file paths) at open time, which would make every
        // failure look identical to a missing file. Opening at the POSIX level
        // means "couldn't open it at all" (bad path, permissions) and
        // "opened fine but couldn't read it as a byte stream" (a directory, or
        // a genuine mid-stream I/O error on a flaky external volume) are
        // distinguishable, and the latter is exactly what `read` below must
        // not silently treat as a clean end-of-file.
        // O_CLOEXEC: now that this hasher owns the raw open flags, closing the
        // descriptor across exec is free — and it stops in-flight descriptors
        // (up to tens of thousands, one per file the indexer is concurrently
        // hashing) from leaking into any child process the app spawns.
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_CLOEXEC)
        }
        guard fd >= 0 else {
            throw HashError.unreadable
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }

        do {
            // `read(upToCount:)` returns nil only at a clean end-of-file; a
            // genuine I/O error (e.g. `EIO` from a failing drive, or `EISDIR`)
            // throws instead. `try?` here would collapse that distinction and
            // silently hash whatever partial data was read before the error —
            // exactly the corruption this streaming hasher must not produce.
            while let chunk = try handle.read(upToCount: bufferSize), !chunk.isEmpty {
                consume(chunk)
            }
        } catch {
            throw HashError.truncated
        }
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
