import Foundation
import GRDB

public struct CompiledQuery: Sendable {
    public let sql: String
    public let arguments: StatementArguments
}

public enum QueryCompilerError: Error, Equatable, Sendable {
    /// A predicate tree nested deeper than any UI can produce. The realistic
    /// source is `saved_searches.query` — persisted JSON, so attacker-
    /// influenceable once saved searches are imported or synced. Uncapped,
    /// the compiler's own recursion crashes hard (SIGBUS) around 200 levels;
    /// this is thrown, and catchable, long before that.
    case predicateTooDeep(limit: Int)
}

/// Turns a `SearchQuery` into parameterized SQL.
///
/// Every user-supplied value is a bound parameter. Nothing from the user is
/// interpolated into the statement text: folder scoping binds the byte-range
/// values from `IndexStore.pathScope`, and filename text goes through
/// `FTS5Query.sanitize` and is then bound to the `MATCH` operator.
///
/// Throws `IndexStoreError.invalidScope` for a folder scope that is empty or
/// relative — the realistic source is a stale persisted setting, which must
/// surface as an error rather than silently searching nothing.
public enum QueryCompiler {
    public static func compile(_ query: SearchQuery) throws -> CompiledQuery {
        var arguments: [DatabaseValueConvertible?] = []

        let scopeClause = try scope(query.scope, &arguments)
        let predicateClause = try condition(query.predicate, depth: 0, &arguments)

        var sql = "SELECT * FROM files WHERE (\(scopeClause)) AND (\(predicateClause))"
        sql += " ORDER BY \(orderBy(query.sort))"
        switch (query.limit, query.offset) {
        case (nil, nil):
            break
        case (let limit?, nil):
            sql += " LIMIT ?"
            arguments.append(limit)
        case (let limit, let offset?):
            // OFFSET is only valid after LIMIT; -1 is SQLite's "no limit",
            // so an offset without a limit still skips rows instead of being
            // silently dropped.
            sql += " LIMIT ? OFFSET ?"
            arguments.append(limit ?? -1)
            arguments.append(offset)
        }
        return CompiledQuery(sql: sql, arguments: StatementArguments(arguments))
    }

    private static func scope(_ scope: SearchQuery.Scope,
                              _ arguments: inout [DatabaseValueConvertible?]) throws -> String {
        switch scope {
        case .everywhere:
            return "1"
        case .folder(let path, let recursive):
            // `pathScope` is the one source of truth for "at or under this
            // prefix": byte-range bounds, not LIKE, so no wildcard escaping
            // and no ASCII case folding that would leak `/LIB` into `/lib`.
            let bounds = try IndexStore.pathScope(path)
            if recursive {
                arguments.append(bounds.exact)
                arguments.append(bounds.lower)
                arguments.append(bounds.upper)
                return IndexStore.scopePredicateSQL
            }
            arguments.append(bounds.exact)
            return "parent_dir = ?"
        }
    }

    /// Deeper than any UI can nest, shallow enough that neither this
    /// function's recursion (SIGBUS near 200 levels) nor the system SQLite's
    /// parser stack (measured overflowing at ~89 levels of the nesting this
    /// compiler emits — Apple's build is far shallower than stock SQLite's
    /// documented 1000) is ever reached.
    private static let maxPredicateDepth = 64

    private static func condition(_ predicate: SearchPredicate, depth: Int,
                                  _ arguments: inout [DatabaseValueConvertible?]) throws -> String {
        guard depth <= maxPredicateDepth else {
            throw QueryCompilerError.predicateTooDeep(limit: maxPredicateDepth)
        }
        switch predicate {
        case .all:
            return "1"

        case .and(let parts):
            // Vacuously true: an empty filter panel matches everything.
            guard !parts.isEmpty else { return "1" }
            // A single-element group needs no parentheses; wrapping anyway
            // would spend SQLite parser stack for nothing.
            guard parts.count > 1 else { return try condition(parts[0], depth: depth + 1, &arguments) }
            return try parts.map { "(\(try condition($0, depth: depth + 1, &arguments)))" }
                .joined(separator: " AND ")

        case .or(let parts):
            // Vacuously false: "any of nothing" matches nothing.
            guard !parts.isEmpty else { return "0" }
            guard parts.count > 1 else { return try condition(parts[0], depth: depth + 1, &arguments) }
            return try parts.map { "(\(try condition($0, depth: depth + 1, &arguments)))" }
                .joined(separator: " OR ")

        case .not(let inner):
            // `IS NOT TRUE` folds SQL's three-valued logic back to two: a row
            // whose attribute is NULL makes the inner predicate UNKNOWN, and
            // plain `NOT UNKNOWN` is still UNKNOWN — silently dropping the
            // row from both a filter and its negation. An unknown attribute
            // must count as "does not match", so its negation matches.
            // (`IS NOT TRUE`, not `NOT COALESCE(expr, 0)`: identical
            // semantics, but COALESCE burns the system SQLite's parser stack
            // about five times faster, overflowing at 17 nested negations.)
            return "(\(try condition(inner, depth: depth + 1, &arguments))) IS NOT TRUE"

        case .width(let c):
            return numeric("width", c, &arguments)
        case .height(let c):
            return numeric("height", c, &arguments)
        case .fileSize(let c):
            return numeric("size", c, &arguments)
        case .megapixels(let c):
            return numeric("(CAST(width AS REAL) * height / 1000000.0)", c, &arguments)
        case .aspectRatio(let c):
            // The height guard keeps a corrupt zero-height row from making the
            // whole query error out on division by zero.
            return "(height > 0 AND \(numeric("(CAST(width AS REAL) / height)", c, &arguments)))"

        case .exactDimensions(let width, let height):
            arguments.append(width)
            arguments.append(height)
            return "width = ? AND height = ?"

        case .fileExtension(let extensions):
            guard !extensions.isEmpty else { return "0" }
            let sorted = extensions.map { $0.lowercased() }.sorted()
            arguments.append(contentsOf: sorted as [DatabaseValueConvertible?])
            return "ext IN (\(Array(repeating: "?", count: sorted.count).joined(separator: ",")))"

        case .captureDate(let range):
            return dateRange("capture_time", range, &arguments)
        case .modifiedDate(let range):
            return dateRange("mtime", range, &arguments)

        case .cameraMake(let make):
            arguments.append(make)
            return "camera_make = ? COLLATE NOCASE"
        case .cameraModel(let model):
            arguments.append(model)
            return "camera_model = ? COLLATE NOCASE"

        case .filenameText(let text):
            switch FTS5Query.sanitize(text) {
            case .noInput:
                // An empty search field is not a filter.
                return "1"
            case .noSearchableTerms:
                // The user typed something and none of it is searchable:
                // that matches nothing. Treating it like `.noInput` would
                // show the entire library for `***`.
                return "0"
            case .pattern(let match):
                arguments.append(match)
                return "id IN (SELECT rowid FROM files_fts WHERE files_fts MATCH ?)"
            }

        case .hasDuplicates:
            // Deliberately evaluated over the whole `files` table, not the
            // folder scope: it means "this file has a twin somewhere in the
            // library", so a search scoped to /in still surfaces a file whose
            // only duplicate lives in /out.
            return """
                (image_hash IS NOT NULL AND image_hash IN (
                    SELECT image_hash FROM files WHERE image_hash IS NOT NULL
                    GROUP BY image_hash HAVING count(*) > 1))
                OR (content_hash IS NOT NULL AND content_hash IN (
                    SELECT content_hash FROM files WHERE content_hash IS NOT NULL
                    GROUP BY content_hash HAVING count(*) > 1))
                """
        }
    }

    private static func numeric(_ column: String, _ constraint: NumericConstraint,
                                _ arguments: inout [DatabaseValueConvertible?]) -> String {
        switch constraint {
        case .equal(let value):
            arguments.append(value)
            return "\(column) = ?"
        case .atLeast(let value):
            arguments.append(value)
            return "\(column) >= ?"
        case .atMost(let value):
            arguments.append(value)
            return "\(column) <= ?"
        case .between(let low, let high):
            arguments.append(min(low, high))
            arguments.append(max(low, high))
            return "\(column) >= ? AND \(column) <= ?"
        }
    }

    private static func dateRange(_ column: String, _ range: DateRange,
                                  _ arguments: inout [DatabaseValueConvertible?]) -> String {
        var clauses: [String] = ["\(column) IS NOT NULL"]
        if let from = range.from {
            arguments.append(from.timeIntervalSince1970)
            clauses.append("\(column) >= ?")
        }
        if let to = range.to {
            arguments.append(to.timeIntervalSince1970)
            clauses.append("\(column) <= ?")
        }
        return clauses.joined(separator: " AND ")
    }

    private static func orderBy(_ sort: SearchQuery.Sort) -> String {
        let direction = sort.ascending ? "ASC" : "DESC"
        // NULLs last in both directions: a photo with no capture date belongs
        // at the end of a date sort, never at the top.
        let column = switch sort.field {
        case .name: "name COLLATE NOCASE"
        case .captureDate: "capture_time"
        case .modifiedDate: "mtime"
        case .size: "size"
        case .width: "width"
        case .height: "height"
        }
        return "(\(column)) IS NULL, \(column) \(direction), id ASC"
    }
}
