import Testing
import Foundation
@testable import LightboxCore

struct FTS5QueryTests {
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

    // MARK: - Safety against a real FTS5 table

    /// Hostile inputs, written out by hand rather than generated from the
    /// sanitizer's own character set. Each is either FTS5 syntax, SQL
    /// injection shaped, degenerate unicode, or a parser stressor.
    private static let hostileInputs: [String] = [
        "\"unclosed",
        "\"\"\"",
        "say \"hi\" now",
        "a NEAR b",
        "NEAR(a b, 2)",
        "cat OR dog",
        "x AND y",
        "NOT z",
        "-excluded",
        "^anchor",
        "col:val",
        "wild*card",
        "*",
        "((((",
        "a + b - c",
        "{brace} [bracket]",
        "'; DROP TABLE files; --",
        "%wild%card_",
        "\\backslash\\",
        "\u{0}null\u{0}byte",
        "line\nbreak\ttab",
        "«guillemets» — dash…",
        "emoji 🙂🔥",
        "caf\u{e9} \u{6771}\u{4EAC}",
        String(repeating: "aaaa bbbb ", count: 400),   // ~800 tokens
        String(repeating: "x", count: 100_000),        // one enormous token
        String(repeating: "-*^:\"", count: 5_000),     // pure syntax, huge
    ]

    /// Every sanitized hostile input must execute as a MATCH pattern against a
    /// real FTS5 table without SQLite throwing, and must never be interpreted
    /// as query syntax.
    @Test func sanitizedOutputIsAcceptedByARealFTS5Table() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(FileRecord(
            id: nil, path: "/lib/beach.jpg", parentDir: "/lib", name: "beach.jpg",
            ext: "jpg", size: 1, mtime: 0, device: 1, inode: 1,
            width: 1, height: 1, captureTime: nil, captureOffset: nil,
            cameraMake: nil, cameraModel: nil, orientation: 1,
            contentHash: nil, imageHash: nil, imageHashKind: nil,
            phash: nil, hashedAt: nil, indexedAt: 0))

        for raw in Self.hostileInputs {
            guard let pattern = FTS5Query.sanitize(raw) else { continue }
            // A syntax error inside SQLite throws here and fails the test.
            _ = try store.ftsMatchRowIDs(pattern)
        }
    }

    /// Operators must be neutralized semantically, not just syntactically:
    /// "beach OR zzz" as real FTS5 syntax would match beach.jpg; as sanitized
    /// terms it requires the literal token "OR" and must match nothing.
    @Test func operatorsDoNotChangeQueryMeaning() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(FileRecord(
            id: nil, path: "/lib/beach.jpg", parentDir: "/lib", name: "beach.jpg",
            ext: "jpg", size: 1, mtime: 0, device: 1, inode: 1,
            width: 1, height: 1, captureTime: nil, captureOffset: nil,
            cameraMake: nil, cameraModel: nil, orientation: 1,
            contentHash: nil, imageHash: nil, imageHashKind: nil,
            phash: nil, hashedAt: nil, indexedAt: 0))

        // NOT-shaped input still finds the term it names.
        let excluded = try store.ftsMatchRowIDs(FTS5Query.sanitize("-beach")!)
        #expect(excluded.count == 1)

        // OR-shaped input is a conjunction of terms, not an alternation.
        let orQuery = try store.ftsMatchRowIDs(FTS5Query.sanitize("beach OR zzz")!)
        #expect(orQuery.isEmpty)
    }
}
