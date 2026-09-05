import Testing
import Foundation
@testable import LightboxCore

/// Unwraps `.pattern` for the string-shape assertions; nil for the other cases.
private func pattern(_ raw: String) -> String? {
    if case .pattern(let p) = FTS5Query.sanitize(raw) { return p }
    return nil
}

struct FTS5QueryTests {
    @Test func quotesEachTokenAndJoinsWithAnd() {
        #expect(pattern("holiday invoice") == "\"holiday\" AND \"invoice\"*")
        #expect(pattern("beach") == "\"beach\"*")
    }

    @Test func neutralisesFTS5Operators() {
        // Every one of these is FTS5 syntax that must not survive as syntax.
        #expect(pattern("a NEAR b") == "\"a\" AND \"NEAR\" AND \"b\"*")
        #expect(pattern("cat OR dog") == "\"cat\" AND \"OR\" AND \"dog\"*")
        #expect(pattern("-excluded") == "\"excluded\"*")
        #expect(pattern("^anchor") == "\"anchor\"*")
        #expect(pattern("wild*card") == "\"wild\" AND \"card\"*")
        #expect(pattern("col:val") == "\"col\" AND \"val\"*")
    }

    @Test func survivesUnbalancedAndEmbeddedQuotes() {
        #expect(pattern("\"unclosed") == "\"unclosed\"*")
        #expect(pattern("say \"hi\" now") == "\"say\" AND \"hi\" AND \"now\"*")
    }

    /// Empty field and hostile-but-empty text must be distinct outcomes:
    /// the first means "no filter", the second must match nothing.
    @Test func distinguishesNoInputFromNoSearchableTerms() {
        #expect(FTS5Query.sanitize("") == .noInput)
        #expect(FTS5Query.sanitize("   ") == .noInput)
        #expect(FTS5Query.sanitize("*") == .noSearchableTerms)
        #expect(FTS5Query.sanitize("\"\"\"") == .noSearchableTerms)
        #expect(FTS5Query.sanitize("--- ^^^") == .noSearchableTerms)
        #expect(FTS5Query.sanitize("🙂🔥") == .noSearchableTerms)
    }

    @Test func keepsUnicodeLettersAndDigits() {
        #expect(pattern("caf\u{e9} 2019") == "\"caf\u{e9}\" AND \"2019\"*")
        #expect(pattern("\u{6771}\u{4EAC}") == "\"\u{6771}\u{4EAC}\"*")
    }

    @Test func onlyTheFinalTokenIsAPrefixMatch() {
        // Search-as-you-type: the word being typed is a prefix, earlier words are
        // complete. Making every token a prefix would match far too much.
        #expect(pattern("one two three") == "\"one\" AND \"two\" AND \"three\"*")
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

    private static func storeWithBeachJPG() throws -> IndexStore {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(FileRecord(
            id: nil, path: "/lib/beach.jpg", parentDir: "/lib", name: "beach.jpg",
            ext: "jpg", size: 1, mtime: 0, device: 1, inode: 1,
            width: 1, height: 1, captureTime: nil, captureOffset: nil,
            cameraMake: nil, cameraModel: nil, orientation: 1,
            contentHash: nil, imageHash: nil, imageHashKind: nil,
            phash: nil, hashedAt: nil, indexedAt: 0))
        return store
    }

    /// Every sanitized hostile input must execute as a MATCH pattern against a
    /// real FTS5 table without SQLite throwing, and must never be interpreted
    /// as query syntax. The execution floor keeps the test honest: if sanitize
    /// regressed to returning no patterns at all, zero statements would run
    /// and the loop alone would pass vacuously.
    @Test func sanitizedOutputIsAcceptedByARealFTS5Table() throws {
        let store = try Self.storeWithBeachJPG()

        var executed = 0
        for raw in Self.hostileInputs {
            guard case .pattern(let pattern) = FTS5Query.sanitize(raw) else { continue }
            // A syntax error inside SQLite throws here and fails the test.
            _ = try store.ftsMatchRowIDs(pattern)
            executed += 1
        }
        #expect(executed >= 20)
    }

    /// Operators must be neutralized semantically, not just syntactically:
    /// "beach OR zzz" as real FTS5 syntax would match beach.jpg; as sanitized
    /// terms it requires the literal token "OR" and must match nothing.
    @Test func operatorsDoNotChangeQueryMeaning() throws {
        let store = try Self.storeWithBeachJPG()

        // Positive control: prove the corpus CAN match. Raw "beach OR zzz" is
        // itself valid FTS5 syntax and alternates, so it finds the row — the
        // negative results below are therefore about sanitization, not about
        // an empty or broken corpus.
        #expect(try store.ftsMatchRowIDs("beach OR zzz").count == 1)

        // NOT-shaped input still finds the term it names.
        let excluded = try #require(pattern("-beach"))
        #expect(try store.ftsMatchRowIDs(excluded).count == 1)

        // OR-shaped input is a conjunction of terms, not an alternation.
        let orQuery = try #require(pattern("beach OR zzz"))
        #expect(try store.ftsMatchRowIDs(orQuery).isEmpty)
    }
}
