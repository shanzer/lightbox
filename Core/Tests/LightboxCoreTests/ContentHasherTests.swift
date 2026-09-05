import Testing
import Foundation
import CryptoKit
@testable import LightboxCore

/// A `struct` suite so swift-testing builds a fresh instance per test and
/// releases it afterwards: teardown of `tree` is then the framework's
/// contract rather than an ARC ordering inferred from where it was last used.
struct ContentHasherTests {
    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    @Test func matchesKnownSHA256Vectors() throws {
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
        #expect(throws: HashError.unreadable) {
            try ContentHasher().hash(tree.root.appendingPathComponent("nope.bin"))
        }
    }

    @Test func hexIsLowercaseAndSixtyFourCharacters() throws {
        let url = try tree.file("a.bin", bytes: 10)
        let hex = try ContentHasher().hash(url)
        #expect(hex.count == 64)
        #expect(hex == hex.lowercased())
        #expect(hex.allSatisfy { $0.isHexDigit })
    }

    /// `FileHandle(forReadingFrom:)` succeeds for a directory on macOS, but the
    /// subsequent `read` throws `EISDIR`. That is a real, reachable stand-in
    /// for a mid-read I/O failure on a flaky external volume: a naive `try?`
    /// around the read collapses this into a clean end-of-file and silently
    /// returns the empty-file hash, which is precisely the bug this test
    /// exists to catch. The fixed implementation must propagate it as a
    /// `HashError` instead of hashing whatever partial (here: zero-byte) read
    /// it got.
    @Test func throwsOnAReadFailureInsteadOfHashingAPartialRead() throws {
        let dir = try tree.directory("adir")
        #expect(throws: HashError.truncated) {
            try ContentHasher().hash(dir)
        }
    }
}
