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

        var digest = SHA256()
        do {
            // `read(upToCount:)` returns nil only at a clean end-of-file; a
            // genuine I/O error (e.g. `EIO` from a failing drive, or `EISDIR`)
            // throws instead. `try?` here would collapse that distinction and
            // silently hash whatever partial data was read before the error —
            // exactly the corruption this streaming hasher must not produce.
            while let chunk = try handle.read(upToCount: bufferSize), !chunk.isEmpty {
                digest.update(data: chunk)
            }
        } catch {
            throw HashError.truncated
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
