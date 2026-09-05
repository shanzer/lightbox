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
        // No `sizing`, so no `fstat` is issued and this path is exactly the
        // loop it has always been: open, read to a clean EOF, throw
        // `.truncated` on anything else.
        try stream(url, consume: { digest.update(data: $0); return true })
        return digest.finalize().hexEncoded
    }

    /// The file's entire contents, read through the same loop as `hash(_:)`,
    /// or nil when the file is larger than `limit`.
    ///
    /// Exists so a caller that needs the bytes themselves — the image-data
    /// parsers, which have to walk a file's structure — gets one read whose
    /// every failure is a `HashError`. `Data(contentsOf:, .mappedIfSafe)` would
    /// be the obvious alternative and is the wrong one: a mid-read `EIO` on a
    /// failing external volume arrives as `SIGBUS` through a mapping, which
    /// cannot be caught and cannot be turned into `.truncated`.
    ///
    /// The cap is a parameter rather than the caller's business because this
    /// method is `public` and unbounded buffering is the one way to misuse it.
    /// It is enforced twice: once against the size `fstat` reports for the
    /// descriptor being read, and again against the bytes actually accumulated,
    /// so a file appended to after the first check still cannot exceed it.
    ///
    /// - Returns: the file's bytes, or nil if it exceeds `limit`.
    public func readWholeFile(_ url: URL, upTo limit: Int) throws -> Data? {
        precondition(limit >= 0, "upTo must not be negative")
        var out = Data()
        let complete = try stream(
            url,
            sizing: { size in
                guard size <= limit else { return false }
                // Seeded from the descriptor's own size, so a symlink's
                // seven-byte path length cannot start a doubling cascade.
                // A hint only: the loop below still decides how many bytes
                // there really are, so a stale size cannot truncate the read.
                if size > 0 { out.reserveCapacity(size) }
                return true
            },
            consume: { chunk in
                out.append(chunk)
                return out.count <= limit
            })
        return complete ? out : nil
    }

    /// Reads `url` in `bufferSize` chunks, handing each to `consume`.
    ///
    /// Shared by `hash(_:)` and `readWholeFile(_:upTo:)` so the two cannot
    /// disagree about what counts as a clean end-of-file or an I/O error.
    ///
    /// `sizing`, when supplied, is called once with the size `fstat` reports
    /// for the descriptor that is about to be read, before any bytes are read;
    /// returning false abandons the read. It is taken from the open descriptor
    /// rather than from a separate stat of the path because the two need not
    /// describe the same object: `FileManager.attributesOfItem(atPath:)` and
    /// `URL.resourceValues(forKeys: [.fileSizeKey])` both report a *symlink's
    /// own* size, while `open(2)` follows the link — so a `.jpg` link to a
    /// 200 MB file measures seven bytes, passes any caller-side size guard, and
    /// then reads 200 MB. Sizing the descriptor also closes the
    /// check-then-read race, because the decision is made about the very file
    /// the loop goes on to read.
    ///
    /// Returning false from `consume` abandons the read as well, so a caller
    /// enforcing a cap stays bounded even if the file grows after `sizing` ran.
    ///
    /// - Returns: true if the file was read through to its end; false if
    ///   `sizing` or `consume` abandoned it.
    @discardableResult
    private func stream(_ url: URL,
                        sizing: ((Int) -> Bool)? = nil,
                        consume: (Data) -> Bool) throws -> Bool {
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

        if let sizing {
            var info = stat()
            // Cannot fail for a descriptor this function just opened, short of
            // the kernel disagreeing with itself. Classified the same way a
            // failed read is: the file opened, but could not be measured.
            guard fstat(fd, &info) == 0 else { throw HashError.truncated }
            guard sizing(Int(info.st_size)) else { return false }
        }

        do {
            // `read(upToCount:)` returns nil only at a clean end-of-file; a
            // genuine I/O error (e.g. `EIO` from a failing drive, or `EISDIR`)
            // throws instead. `try?` here would collapse that distinction and
            // silently hash whatever partial data was read before the error —
            // exactly the corruption this streaming hasher must not produce.
            while let chunk = try handle.read(upToCount: bufferSize), !chunk.isEmpty {
                guard consume(chunk) else { return false }
            }
        } catch {
            throw HashError.truncated
        }
        return true
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
