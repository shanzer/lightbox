import Testing
import Foundation
@testable import LightboxCore

struct SearchQueryTests {
    @Test func searchQueryRoundTripsThroughJSON() throws {
        let query = SearchQuery(
            scope: .folder(path: "/lib", recursive: true),
            predicate: .and([
                .exactDimensions(width: 200, height: 200),
                .not(.fileExtension(["png"])),
                .or([.cameraMake("Canon"), .cameraMake("Nikon")]),
                .captureDate(DateRange(from: Date(timeIntervalSince1970: 0), to: nil)),
                .megapixels(.between(2, 24)),
            ]),
            sort: SearchQuery.Sort(field: .captureDate, ascending: false),
            limit: 500, offset: nil)

        let data = try JSONEncoder().encode(query)
        #expect(try JSONDecoder().decode(SearchQuery.self, from: data) == query)
    }

    /// The first round-trip exercises recursion; this one covers every
    /// remaining SearchPredicate case and the `.everywhere` scope, so a saved
    /// search can never hit an unencodable case.
    @Test func everyRemainingPredicateCaseRoundTrips() throws {
        let query = SearchQuery(
            scope: .everywhere,
            predicate: .or([
                .all,
                .width(.equal(1920)),
                .height(.atLeast(1080)),
                .aspectRatio(.atMost(1.78)),
                .fileSize(.between(1_000, 2_000)),
                .fileExtension(["jpg", "jpeg", "png"]),
                .modifiedDate(DateRange(from: nil, to: Date(timeIntervalSince1970: 86_400))),
                .cameraModel("EOS R5"),
                .filenameText("holiday"),
                .hasDuplicates,
            ]),
            sort: SearchQuery.Sort(field: .size, ascending: true),
            limit: nil, offset: 40)

        let data = try JSONEncoder().encode(query)
        #expect(try JSONDecoder().decode(SearchQuery.self, from: data) == query)
    }

    @Test func defaultQueryMatchesEverythingInAFolder() {
        let query = SearchQuery(scope: .folder(path: "/lib", recursive: false))
        #expect(query.predicate == .all)
        #expect(query.sort.field == .name)
        #expect(query.sort.ascending == true)
        #expect(query.limit == nil)
    }
}
