import Testing
import Foundation
@testable import LightboxCore

/// `rows` is (path, extension, camera make, width) — everything the two facet
/// dimensions and the one numeric filter in the phase 1 panel are built from.
private func store(_ rows: [(String, String, String?, Int)]) throws -> IndexStore {
    let store = try IndexStore.inMemory()
    var inode: Int64 = 0
    for (path, ext, make, width) in rows {
        inode += 1
        _ = try store.upsert(FileRecord(
            id: nil, path: path, parentDir: (path as NSString).deletingLastPathComponent,
            name: (path as NSString).lastPathComponent, ext: ext, size: 10, mtime: 1,
            device: 1, inode: inode,
            width: width, height: 100, captureTime: nil, captureOffset: nil,
            cameraMake: make, cameraModel: nil, orientation: 1, contentHash: nil,
            imageHash: nil, imageHashKind: nil, phash: nil, hashedAt: nil, indexedAt: 1))
    }
    return store
}

@Suite struct FacetTests {
    @Test func countsByExtensionAndCamera() throws {
        let s = try store([
            ("/l/a.jpg", "jpg", "Canon", 100), ("/l/b.jpg", "jpg", "Canon", 100),
            ("/l/c.png", "png", nil, 100), ("/l/d.heic", "heic", "Apple", 100),
        ])
        let facets = try s.facets(for: SearchQuery(scope: .everywhere))
        #expect(facets.total == 4)
        #expect(facets.byExtension == ["jpg": 2, "png": 1, "heic": 1])
        // NULL cameras are not a bucket, so the camera counts deliberately do
        // not add up to `total`.
        #expect(facets.byCamera == ["Canon": 2, "Apple": 1])
    }

    @Test func facetsRespectTheCurrentScope() throws {
        let s = try store([
            ("/l/a.jpg", "jpg", "Canon", 100), ("/l/sub/b.jpg", "jpg", "Canon", 100),
            ("/l/c.png", "png", nil, 100),
        ])
        let facets = try s.facets(for: SearchQuery(scope: .folder(path: "/l", recursive: false)))
        #expect(facets.total == 2)
        #expect(facets.byExtension == ["jpg": 1, "png": 1])
        #expect(facets.byCamera == ["Canon": 1])
    }

    @Test func facetsRespectTheCurrentPredicate() throws {
        let s = try store([
            ("/l/a.jpg", "jpg", "Canon", 4000), ("/l/b.jpg", "jpg", "Canon", 100),
            ("/l/c.png", "png", "Nikon", 4000),
        ])
        let facets = try s.facets(for: SearchQuery(scope: .everywhere,
                                                   predicate: .width(.atLeast(1920))))
        #expect(facets.total == 2)
        #expect(facets.byExtension == ["jpg": 1, "png": 1])
        #expect(facets.byCamera == ["Canon": 1, "Nikon": 1])
    }

    @Test func facetsOfAnEmptyResultAreEmptyNotAbsent() throws {
        let s = try store([("/l/a.jpg", "jpg", "Canon", 100)])
        let facets = try s.facets(for: SearchQuery(scope: .everywhere,
                                                   predicate: .fileExtension(["gif"])))
        #expect(facets.total == 0)
        #expect(facets.byExtension.isEmpty)
        #expect(facets.byCamera.isEmpty)
    }

    /// The counts describe the whole result set, not the page on screen.
    ///
    /// The panel's whole job is to say what narrowing *would* do; a count taken
    /// after a `LIMIT` would say "3 png files" while scrolling one page further
    /// revealed thousands more. Asserted against the same query run twice —
    /// once paged, once not — so the expectation comes from the data rather
    /// than from a number copied out of the implementation.
    @Test func facetsIgnoreLimitAndOffset() throws {
        var rows: [(String, String, String?, Int)] = []
        for index in 0..<10 { rows.append(("/l/a\(index).jpg", "jpg", "Canon", 100)) }
        for index in 0..<4 { rows.append(("/l/b\(index).png", "png", "Nikon", 100)) }
        let s = try store(rows)

        let unpaged = try s.facets(for: SearchQuery(scope: .everywhere))
        var paged = SearchQuery(scope: .everywhere)
        paged.limit = 2
        paged.offset = 1
        #expect(try s.search(paged).count == 2, "the limit must really be in force for the search")
        #expect(try s.facets(for: paged) == unpaged)
        #expect(unpaged.total == rows.count)
    }

    /// Text that survives tokenization as nothing must count nothing.
    ///
    /// `FTS5Query.sanitize` distinguishes an empty field (`noInput`, not a
    /// filter) from typed text with no searchable term in it
    /// (`noSearchableTerms`, matches nothing). Collapsing the two here would
    /// have the panel report the entire library as the breakdown of a search
    /// the grid is showing as empty.
    @Test func hostileSearchTextFacetsNothingRatherThanEverything() throws {
        let s = try store([
            ("/l/a.jpg", "jpg", "Canon", 100), ("/l/b.png", "png", "Nikon", 100),
        ])
        #expect(FTS5Query.sanitize("***") == .noSearchableTerms)

        let facets = try s.facets(for: SearchQuery(scope: .everywhere,
                                                   predicate: .filenameText("***")))
        #expect(facets.total == 0)
        #expect(facets.byExtension.isEmpty)
        #expect(facets.byCamera.isEmpty)
    }

    /// An empty search field is not a filter, and must not be mistaken for one.
    @Test func anEmptySearchFieldFacetsEverything() throws {
        let s = try store([
            ("/l/a.jpg", "jpg", "Canon", 100), ("/l/b.png", "png", "Nikon", 100),
        ])
        #expect(FTS5Query.sanitize("   ") == .noInput)

        let facets = try s.facets(for: SearchQuery(scope: .everywhere,
                                                   predicate: .filenameText("   ")))
        #expect(facets == (try s.facets(for: SearchQuery(scope: .everywhere))))
        #expect(facets.total == 2)
    }

    @Test func searchTextNarrowsTheFacets() throws {
        let s = try store([
            ("/l/beach.jpg", "jpg", "Canon", 100), ("/l/beach.png", "png", "Nikon", 100),
            ("/l/mountain.jpg", "jpg", "Apple", 100),
        ])
        let facets = try s.facets(for: SearchQuery(scope: .everywhere,
                                                   predicate: .filenameText("beach")))
        #expect(facets.total == 2)
        #expect(facets.byExtension == ["jpg": 1, "png": 1])
        #expect(facets.byCamera == ["Canon": 1, "Nikon": 1])
    }

    /// A bad scope is an error, not an empty breakdown.
    ///
    /// Zero is a legitimate answer — `facetsOfAnEmptyResultAreEmptyNotAbsent`
    /// depends on it — so a stale relative path in a persisted setting must not
    /// be able to masquerade as "this folder is empty".
    @Test func aRelativeScopeThrowsRatherThanCountingNothing() throws {
        let s = try store([("/l/a.jpg", "jpg", "Canon", 100)])
        #expect(throws: IndexStoreError.invalidScope("~/Pictures")) {
            try s.facets(for: SearchQuery(scope: .folder(path: "~/Pictures", recursive: true)))
        }
        #expect(throws: IndexStoreError.invalidScope("")) {
            try s.facets(for: SearchQuery(scope: .folder(path: "", recursive: false)))
        }
    }

    /// Empty-string buckets are excluded alongside NULL ones.
    ///
    /// `camera_make` arrives from EXIF, where an empty tag and an absent tag
    /// are both common; a `""` row in the panel renders as a blank line with a
    /// count next to it, which reads as a bug.
    @Test func emptyStringsAreNotABucket() throws {
        let s = try store([
            ("/l/a.jpg", "jpg", "", 100), ("/l/b.jpg", "jpg", "Canon", 100),
        ])
        let facets = try s.facets(for: SearchQuery(scope: .everywhere))
        #expect(facets.total == 2)
        #expect(facets.byCamera == ["Canon": 1])
    }

    /// The filter clause `facets(for:)` is built from must be exactly the one
    /// `search` matches on, or the panel would count a different set of rows
    /// than the grid shows.
    @Test func facetTotalAgreesWithTheSearchItDescribes() throws {
        let s = try store([
            ("/l/beach.jpg", "jpg", "Canon", 4000), ("/l/sub/beach.png", "png", nil, 100),
            ("/l/sub/deep/beach.jpg", "jpg", "Canon", 4000), ("/other/beach.jpg", "jpg", nil, 4000),
        ])
        let query = SearchQuery(scope: .folder(path: "/l", recursive: true),
                                predicate: .and([.filenameText("beach"),
                                                 .width(.atLeast(1920))]))
        #expect(try s.facets(for: query).total == (try s.search(query).count))
    }
}
