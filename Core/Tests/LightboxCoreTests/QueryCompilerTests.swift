import Testing
import Foundation
@testable import LightboxCore

private func makeRecord(_ path: String, w: Int? = nil, h: Int? = nil, size: Int64 = 1,
                        capture: Double? = nil, make: String? = nil, ext: String = "jpg",
                        content: String? = nil, image: String? = nil) -> FileRecord {
    FileRecord(
        id: nil, path: path,
        parentDir: (path as NSString).deletingLastPathComponent,
        name: (path as NSString).lastPathComponent, ext: ext,
        size: size, mtime: 1_700_000_000, device: 1, inode: 1,
        width: w, height: h, captureTime: capture, captureOffset: nil,
        cameraMake: make, cameraModel: nil, orientation: 1,
        contentHash: content, imageHash: image, imageHashKind: nil,
        phash: nil, hashedAt: content == nil ? nil : 1, indexedAt: 1)
}

private func seededStore() throws -> IndexStore {
    let store = try IndexStore.inMemory()
    func add(_ path: String, w: Int?, h: Int?, size: Int64,
             capture: Double?, make: String?, ext: String,
             content: String? = nil, image: String? = nil) throws {
        _ = try store.upsert(makeRecord(path, w: w, h: h, size: size, capture: capture,
                                        make: make, ext: ext, content: content, image: image))
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

struct QueryCompilerTests {

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
        func search(_ predicate: SearchPredicate) throws -> [String] {
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

        // Camera make matching is case-insensitive: "canon" is the same camera.
        let lower = try store.search(SearchQuery(scope: .everywhere,
                                                 predicate: .cameraMake("canon")))
        #expect(names(lower) == ["beach.jpg"])
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

    /// An empty search field means "no filename filter"; typed text that
    /// survives tokenization as no terms means the user asked for something
    /// and it matches nothing. Collapsing the two would make `***` or an
    /// emoji show the entire library.
    @Test func unsearchableTextMatchesNothingButEmptyTextMatchesEverything() throws {
        let store = try seededStore()
        for empty in ["", "   ", "\n\t"] {
            let found = try store.search(SearchQuery(scope: .everywhere,
                                                     predicate: .filenameText(empty)))
            #expect(found.count == 6, "no input \(String(reflecting: empty)) must not filter")
        }
        for unsearchable in ["***", "🙂🙂", "!!", "\"\""] {
            let found = try store.search(SearchQuery(scope: .everywhere,
                                                     predicate: .filenameText(unsearchable)))
            #expect(found.isEmpty, "\(String(reflecting: unsearchable)) must match nothing")
        }
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

    /// `SearchQuery` is encodable with an offset and no limit; the compiler
    /// must not silently ignore the offset in that case.
    @Test func offsetWithoutLimitStillSkipsRows() throws {
        let store = try seededStore()
        let rest = try store.search(SearchQuery(
            scope: .everywhere,
            sort: SearchQuery.Sort(field: .size, ascending: false), limit: nil, offset: 2))
        #expect(rest.count == 4)
        #expect(!names(rest).contains("beach.jpg"))
        #expect(!names(rest).contains("sunset-invoice.jpg"))
    }

    @Test func sortPutsMissingDatesLastInBothDirections() throws {
        let store = try seededStore()
        // Only beach and sunset-invoice have a capture time; the other four
        // rows have none and belong at the end of a date sort either way up.
        let asc = try store.search(SearchQuery(
            scope: .everywhere, sort: SearchQuery.Sort(field: .captureDate, ascending: true)))
        #expect(Array(names(asc).prefix(2)) == ["beach.jpg", "sunset-invoice.jpg"])
        #expect(asc.dropFirst(2).allSatisfy { $0.captureTime == nil })

        let desc = try store.search(SearchQuery(
            scope: .everywhere, sort: SearchQuery.Sort(field: .captureDate, ascending: false)))
        #expect(Array(names(desc).prefix(2)) == ["sunset-invoice.jpg", "beach.jpg"])
        #expect(desc.dropFirst(2).allSatisfy { $0.captureTime == nil })
    }

    @Test func anEmptyPredicateSetIsNotAMatchAll() throws {
        let store = try seededStore()
        // `.and([])` is vacuously true and `.or([])` is vacuously false. Getting
        // this backwards would silently return the whole library for an empty
        // filter panel.
        #expect(try store.search(SearchQuery(scope: .everywhere, predicate: .and([]))).count == 6)
        #expect(try store.search(SearchQuery(scope: .everywhere, predicate: .or([]))).isEmpty)
    }

    @Test func aZeroHeightRowCannotErrorAnAspectRatioQuery() throws {
        let store = try seededStore()
        _ = try store.upsert(makeRecord("/lib/corrupt.jpg", w: 100, h: 0))
        let found = try store.search(SearchQuery(scope: .everywhere,
                                                 predicate: .aspectRatio(.atLeast(0))))
        #expect(!names(found).contains("corrupt.jpg"))
        #expect(!found.isEmpty)   // the healthy rows still match
    }

    @Test func aFolderContainingSQLWildcardsDoesNotOverMatch() throws {
        let store = try IndexStore.inMemory()
        for path in ["/a_b/one.jpg", "/axb/two.jpg"] {
            _ = try store.upsert(makeRecord(path))
        }
        let found = try store.search(SearchQuery(scope: .folder(path: "/a_b", recursive: true)))
        #expect(names(found) == ["one.jpg"])   // `_` must not match `x`
    }

    /// `LIKE` folds ASCII case no matter what; the byte-range scope must not.
    /// A scope of `/lib` leaking `/LIB` would show a sibling directory's files.
    @Test func aCaseVariantSiblingDirectoryDoesNotLeakIntoScope() throws {
        let store = try IndexStore.inMemory()
        for path in ["/lib/a.jpg", "/LIB/b.jpg", "/lib/sub/c.jpg"] {
            _ = try store.upsert(makeRecord(path))
        }
        let deep = try store.search(SearchQuery(scope: .folder(path: "/lib", recursive: true)))
        #expect(Set(names(deep)) == ["a.jpg", "c.jpg"])

        let shallow = try store.search(SearchQuery(scope: .folder(path: "/lib", recursive: false)))
        #expect(names(shallow) == ["a.jpg"])
    }

    @Test func aRelativeOrEmptyScopeThrowsInvalidScope() throws {
        let store = try seededStore()
        #expect(throws: IndexStoreError.invalidScope("")) {
            try store.search(SearchQuery(scope: .folder(path: "", recursive: true)))
        }
        #expect(throws: IndexStoreError.invalidScope("~/Pictures")) {
            try store.search(SearchQuery(scope: .folder(path: "~/Pictures", recursive: false)))
        }
    }

    /// Every predicate that carries user text, driven with SQL metacharacters
    /// into a real database. The strings must behave as opaque values: no
    /// statement error, no dropped table, and a stored value equal to the
    /// hostile string is found by exact comparison (proof it was bound, not
    /// interpreted).
    @Test func hostileTextIsBoundAsDataEverywhere() throws {
        let hostile = "'; DROP TABLE files;--"
        let store = try IndexStore.inMemory()
        var record = makeRecord("/lib/evil.jpg")
        record.cameraMake = hostile
        record.cameraModel = "\" OR \"\"=\""
        _ = try store.upsert(record)
        _ = try store.upsert(makeRecord("/lib/plain.jpg"))

        let byMake = try store.search(SearchQuery(scope: .everywhere,
                                                  predicate: .cameraMake(hostile)))
        #expect(names(byMake) == ["evil.jpg"])

        let byModel = try store.search(SearchQuery(scope: .everywhere,
                                                   predicate: .cameraModel("\" OR \"\"=\"")))
        #expect(names(byModel) == ["evil.jpg"])

        let byExt = try store.search(SearchQuery(
            scope: .everywhere, predicate: .fileExtension([hostile, "') OR 1=1 --"])))
        #expect(byExt.isEmpty)

        let byScope = try store.search(SearchQuery(
            scope: .folder(path: "/x\(hostile)", recursive: true)))
        #expect(byScope.isEmpty)

        #expect(try store.count() == 2)   // the table survived all of it
    }
}
