import Foundation

public enum NumericConstraint: Sendable, Codable, Hashable {
    case equal(Double)
    case atLeast(Double)
    case atMost(Double)
    case between(Double, Double)
}

public struct DateRange: Sendable, Codable, Hashable {
    public var from: Date?
    public var to: Date?
    public init(from: Date? = nil, to: Date? = nil) { self.from = from; self.to = to }
}

/// A search as a value: composable, comparable, and encodable, so that a saved
/// search is literally the same thing the search bar produces.
public indirect enum Predicate: Sendable, Codable, Hashable {
    case all
    case and([Predicate])
    case or([Predicate])
    case not(Predicate)

    case width(NumericConstraint)
    case height(NumericConstraint)
    case exactDimensions(width: Int, height: Int)
    case megapixels(NumericConstraint)
    case aspectRatio(NumericConstraint)
    case fileSize(NumericConstraint)
    case fileExtension(Set<String>)
    case captureDate(DateRange)
    case modifiedDate(DateRange)
    case cameraMake(String)
    case cameraModel(String)
    case filenameText(String)
    case hasDuplicates
}

public struct SearchQuery: Sendable, Codable, Hashable {
    public enum Scope: Sendable, Codable, Hashable {
        case folder(path: String, recursive: Bool)
        case everywhere
    }

    public enum SortField: String, Sendable, Codable, Hashable, CaseIterable {
        case name, captureDate, modifiedDate, size, width, height
    }

    public struct Sort: Sendable, Codable, Hashable {
        public var field: SortField
        public var ascending: Bool
        public init(field: SortField = .name, ascending: Bool = true) {
            self.field = field; self.ascending = ascending
        }
    }

    public var scope: Scope
    public var predicate: Predicate
    public var sort: Sort
    public var limit: Int?
    public var offset: Int?

    public init(scope: Scope, predicate: Predicate = .all,
                sort: Sort = Sort(), limit: Int? = nil, offset: Int? = nil) {
        self.scope = scope; self.predicate = predicate
        self.sort = sort; self.limit = limit; self.offset = offset
    }
}
