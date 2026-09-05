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
