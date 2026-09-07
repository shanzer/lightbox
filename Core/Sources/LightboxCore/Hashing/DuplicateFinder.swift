import Foundation

// Filed under `Hashing/` rather than `Search/` deliberately. `Search/` is the
// machinery that turns a `SearchQuery` into SQL; this file *consumes* that as
// a scope and is otherwise entirely about what the three hashes mean — which
// key groups which rows, and what a Hamming distance of 12 is worth. Those are
// the invariants documented in HANDOFF §6, and they belong next to the code
// that computes them.

/// One `content_hash` sub-group inside an exact-image group: files whose whole
/// bytes are identical, not merely their image data.
///
/// More than one of these in a group is the interesting case — it means the
/// same picture is stored with different metadata, which is exactly what
/// `image_hash` exists to see and what a metadata edit creates.
public struct ExactCopy: Sendable, Equatable {
    public let contentHash: String?
    public let files: [FileRecord]

    public init(contentHash: String?, files: [FileRecord]) {
        self.contentHash = contentHash
        self.files = files
    }
}

/// Files that carry the same image, grouped by `image_hash` and sub-grouped by
/// `content_hash`.
public struct DuplicateGroup: Sendable, Equatable {
    /// The `image_hash` this group is keyed on, or nil for a group that fell
    /// back to `content_hash` because the format has no image-hash rule
    /// (spec §11: RAW, TIFF, GIF, PSD — and HEIC while it has none).
    public let imageHash: String?
    /// `image_hash_kind`: which per-format rule produced `imageHash`. Nil
    /// exactly when `imageHash` is nil.
    public let kind: String?
    public let copies: [ExactCopy]

    /// Every file in the group, sub-group order preserved.
    public var files: [FileRecord] { copies.flatMap(\.files) }

    public init(imageHash: String?, kind: String?, copies: [ExactCopy]) {
        self.imageHash = imageHash
        self.kind = kind
        self.copies = copies
    }
}

public struct NearMatch: Sendable, Equatable {
    public let file: FileRecord
    /// Hamming distance from the seed, in bits: 0...`DuplicateFinder.nearThreshold`.
    public let distance: Int

    public init(file: FileRecord, distance: Int) {
        self.file = file
        self.distance = distance
    }
}

/// A seed and the files whose perceptual hashes are within
/// `DuplicateFinder.nearThreshold` bits of it.
///
/// Star-shaped, not a transitive cluster: every match is stated against the
/// seed, and the distance shown is the distance the user can check. A
/// transitive cluster would chain A-B-C with A and C 24 bits apart and present
/// them as one set of duplicates, which is how a near-duplicate view starts
/// recommending the deletion of a different photograph.
public struct NearGroup: Sendable, Equatable {
    public let seed: FileRecord
    public let matches: [NearMatch]

    public init(seed: FileRecord, matches: [NearMatch]) {
        self.seed = seed
        self.matches = matches
    }
}

/// The near tier on its own, so a caller can run it separately from the exact
/// tier — see `DuplicateFinder.nearGroups(for:excluding:)`.
public struct NearTierResult: Sendable, Equatable {
    public let groups: [NearGroup]
    /// Nil when the tier ran; otherwise the scope size that exceeded the
    /// ceiling. See `DuplicateReport.nearTierSkipped`.
    public let skipped: Int?

    public init(groups: [NearGroup], skipped: Int?) {
        self.groups = groups
        self.skipped = skipped
    }
}

public struct DuplicateReport: Sendable, Equatable {
    /// Exact-image groups. A row appears in at most one.
    public let exact: [DuplicateGroup]
    /// The separate, lower-confidence tier. Never repeats a pair that is
    /// already together in an exact group.
    public let near: [NearGroup]
    /// Nil when the near tier ran. Otherwise the number of hashed rows in
    /// scope, which exceeded `DuplicateFinder.nearTierCeiling` — the exact
    /// tier in this report is complete, the near tier is empty because it was
    /// not attempted, and the caller should say so rather than showing "no
    /// near-duplicates".
    public let nearTierSkipped: Int?

    public init(exact: [DuplicateGroup], near: [NearGroup], nearTierSkipped: Int?) {
        self.exact = exact
        self.near = near
        self.nearTierSkipped = nearTierSkipped
    }
}

/// The `id`, ordering fields and perceptual hash of one row — the near tier's
/// working set. See `IndexStore.perceptualHashRows(for:)`.
struct PerceptualHashRow: Sendable, Hashable {
    let id: Int64
    let name: String
    let path: String
    let phash: String
}

/// Groups a search scope into exact duplicates and near-duplicates.
///
/// Two tiers, because they carry very different confidence. The exact tier is
/// arithmetic: two files with the same `image_hash` hold the same image data,
/// full stop. The near tier is a judgement — a perceptual hash within 12 bits
/// usually means the same photograph re-encoded or resized, and occasionally
/// means two frames of the same scene. The view must label them differently,
/// and this type keeps them apart so it can.
///
/// Read-only, and that is a safety property rather than an accident: this is
/// the query whose answer a user deletes files on. Nothing here writes, so
/// nothing here can put a hash on the wrong row; `IndexStore.setHashes(for:)`
/// is the single guarded writer that keeps that true.
public struct DuplicateFinder: Sendable {
    /// Bits, inclusive. photolib's threshold, and the one HANDOFF §6 measures
    /// the cross-tool divergence (0-4 bits, mean 1.22) against — so a Lightbox
    /// hash compared with a photolib hash spends up to 8 of these 12 on
    /// pipeline disagreement alone, and still has budget left.
    public static let nearThreshold = 12

    /// Rows above which the pairwise near-duplicate scan is refused.
    ///
    /// The scan is `n(n-1)/2` 64-bit XOR + popcount. Measured on the M4 mini in
    /// a **release** build over synthetic hashes — the scan's cost depends on
    /// the row count and nothing else — it runs 0.06 s at 10,000 rows, 0.41 s
    /// at 25,000, 1.32 s at 50,000, 3.37 s at 100,000 and 13.65 s at 200,000.
    /// Clean quadratic growth, so the issue's 5 s budget lands at about 120,000
    /// rows, and that is the number. Full run in
    /// `docs/superpowers/notes/2026-09-07-duplicate-grouping.md`.
    ///
    /// A debug build is roughly 85x slower here (4.0 s at 10,000 rows), so any
    /// re-measurement has to be `swift test -c release` or it is measuring
    /// bounds checks.
    ///
    /// There is no bucketed fast path, and that is a deliberate refusal rather
    /// than an omission. Bucketing on a 16-bit prefix only finds pairs that
    /// agree exactly on those bits; at a threshold of 12 over 64 bits the
    /// pigeonhole bound needs *thirteen* bands before an exact band match is
    /// implied, so 5-bit bands, and 13 passes over buckets of ~1/32 of the
    /// scope comes out within a small factor of the brute-force scan while
    /// being far harder to prove correct. A prefix filter that is merely
    /// *approximate* would silently drop real near-duplicates from a view whose
    /// output is a deletion, which is not a trade this feature can make. So:
    /// exhaustive up to the ceiling, and an honest refusal past it.
    public static let nearTierCeiling = 120_000

    private let store: IndexStore
    private let ceiling: Int

    public init(store: IndexStore, nearTierCeiling: Int = DuplicateFinder.nearTierCeiling) {
        self.store = store
        self.ceiling = nearTierCeiling
    }

    public func report(for query: SearchQuery) throws -> DuplicateReport {
        let exact = try exactGroups(for: query)
        let near = try nearGroups(for: query, excluding: exact)
        return DuplicateReport(exact: exact, near: near.groups, nearTierSkipped: near.skipped)
    }

    // MARK: - Exact tier

    /// The exact tier alone.
    ///
    /// Public, and separate from `report(for:)`, because the two tiers are
    /// orders of magnitude apart in cost: the exact tier is one indexed
    /// `GROUP BY` and the near tier compares every pair in the scope. A view
    /// that must have both before it can draw anything makes the cheap,
    /// certain answer wait on the expensive, hedged one.
    public func exactGroups(for query: SearchQuery) throws -> [DuplicateGroup] {
        /// The grouping key, kept in two namespaces. An `image_hash` and a
        /// `content_hash` are both SHA-256 hex and could collide as bare
        /// strings while meaning entirely different things.
        enum Key: Hashable {
            case image(String)
            case content(String)
        }

        var buckets: [Key: [FileRecord]] = [:]
        for row in try store.duplicateCandidates(for: query) {
            if let image = row.imageHash {
                buckets[.image(image), default: []].append(row)
            } else if let content = row.contentHash {
                buckets[.content(content), default: []].append(row)
            }
        }

        var groups: [DuplicateGroup] = []
        groups.reserveCapacity(buckets.count)
        for (key, rows) in buckets {
            // The SQL only returns rows whose key is shared, but a group of one
            // is not a duplicate under any circumstances, so the invariant is
            // restated here rather than trusted across a layer.
            guard rows.count > 1 else { continue }
            let ordered = rows.sorted(by: Self.precedes)
            let copies = Self.subGroups(ordered)
            let imageHash: String?
            switch key {
            case .image(let hash): imageHash = hash
            case .content: imageHash = nil
            }
            // Every row in an image-hash group carries the same rule by
            // construction; take it from the first rather than asserting it.
            groups.append(DuplicateGroup(imageHash: imageHash,
                                         kind: imageHash == nil ? nil : ordered[0].imageHashKind,
                                         copies: copies))
        }
        return groups.sorted { a, b in
            guard let first = a.files.first, let second = b.files.first else {
                return b.files.first != nil
            }
            return Self.precedes(first, second)
        }
    }

    /// Splits an already-ordered group by `content_hash`, preserving that
    /// order both within each sub-group and between them.
    private static func subGroups(_ ordered: [FileRecord]) -> [ExactCopy] {
        var order: [String] = []
        var byHash: [String: [FileRecord]] = [:]
        // A nil content_hash cannot be a dictionary key and must not be folded
        // in with the empty string, so it gets its own sentinel and is mapped
        // back on the way out.
        let nilKey = "\u{0}nil"
        for row in ordered {
            let key = row.contentHash ?? nilKey
            if byHash[key] == nil { order.append(key) }
            byHash[key, default: []].append(row)
        }
        return order.map { key in
            ExactCopy(contentHash: key == nilKey ? nil : key, files: byHash[key] ?? [])
        }
    }

    // MARK: - Near tier

    /// One candidate, flattened for the pairwise scan.
    private struct Candidate {
        let id: Int64
        let bits: UInt64
        let exactGroup: Int
    }

    /// The near tier alone, given the exact groups whose pairs it must not
    /// repeat. Pass the groups `exactGroups(for:)` returned for the same query;
    /// passing `[]` yields every near pair including the ones the exact tier
    /// already covers, which is almost never what a view wants.
    public func nearGroups(for query: SearchQuery,
                           excluding exact: [DuplicateGroup]) throws -> NearTierResult {
        // Which exact group each row landed in, so the near tier can leave
        // those pairs alone. `-1` stands for "no exact group", and two rows
        // both at -1 are *not* in the same group — the comparison in
        // `starCover` has to respect that.
        var exactGroupOf: [Int64: Int] = [:]
        for (index, group) in exact.enumerated() {
            for file in group.files {
                if let id = file.id { exactGroupOf[id] = index }
            }
        }

        let rows = try store.perceptualHashRows(for: query)
        guard !rows.isEmpty else { return NearTierResult(groups: [], skipped: nil) }
        guard rows.count <= ceiling else {
            return NearTierResult(groups: [], skipped: rows.count)
        }

        // Seeds are taken in the grid's order — name case-insensitively, then
        // path — not in row-id order. Ids are reused rowids, so an id-ordered
        // greedy pass would silently re-seat every group the first time a row
        // is deleted and its id handed to another file.
        //
        // The folding key is computed once per row rather than inside the
        // comparator, which would fold both names on every one of the
        // n log n comparisons.
        let ordered = rows.map { (key: $0.name.lowercased(), row: $0) }
            .sorted { Self.precedes(name: $0.key, path: $0.row.path,
                                    before: $1.key, path: $1.row.path) }
            .map(\.row)

        var candidates: [Candidate] = []
        candidates.reserveCapacity(ordered.count)
        for row in ordered {
            // A stored hash that will not parse is a corrupt row, not a reason
            // to fail the whole duplicate view. It loses its near matches; its
            // exact grouping, which does not go through here, is untouched.
            guard let parsed = try? PerceptualHash(hex: row.phash) else { continue }
            candidates.append(Candidate(id: row.id, bits: parsed.value,
                                        exactGroup: exactGroupOf[row.id] ?? -1))
        }
        guard candidates.count > 1 else { return NearTierResult(groups: [], skipped: nil) }

        let pairs = Self.starCover(candidates, threshold: Self.nearThreshold)
        guard !pairs.isEmpty else { return NearTierResult(groups: [], skipped: nil) }

        // One fetch for every record either tier of this pass needs, rather
        // than a query per group.
        var wanted: [Int64] = []
        for pair in pairs {
            wanted.append(pair.seed)
            wanted.append(contentsOf: pair.matches.map(\.id))
        }
        let byID = Dictionary(try store.records(ids: wanted).compactMap { record in
            record.id.map { ($0, record) }
        }, uniquingKeysWith: { first, _ in first })

        let groups: [NearGroup] = pairs.compactMap { pair in
            guard let seed = byID[pair.seed] else { return nil }
            let matches = pair.matches.compactMap { match in
                byID[match.id].map { NearMatch(file: $0, distance: match.distance) }
            }
            guard !matches.isEmpty else { return nil }
            return NearGroup(seed: seed, matches: matches)
        }
        return NearTierResult(groups: groups, skipped: nil)
    }

    private struct RawMatch { let id: Int64; let distance: Int }
    private struct RawGroup { let seed: Int64; let matches: [RawMatch] }

    /// Greedy star cover over `candidates`, which must already be in seed
    /// order.
    ///
    /// Each record ends up in at most one group, as seed or as match: the first
    /// unclaimed record becomes a seed and claims every unclaimed record within
    /// `threshold`. Deterministic, given the caller's ordering, and it makes
    /// "which group is this file in?" a question with one answer — which the
    /// view needs, because the answer is what the user acts on.
    ///
    /// Pairs already together in the same exact group are skipped: the exact
    /// tier has already reported them with far more confidence, and repeating
    /// them here would make every metadata-edited copy look like two findings.
    private static func starCover(_ candidates: [Candidate], threshold: Int) -> [RawGroup] {
        let count = candidates.count
        var claimed = [Bool](repeating: false, count: count)
        var groups: [RawGroup] = []

        candidates.withUnsafeBufferPointer { buffer in
            for seed in 0..<count where !claimed[seed] {
                let seedBits = buffer[seed].bits
                let seedGroup = buffer[seed].exactGroup
                var matches: [RawMatch] = []

                for other in (seed + 1)..<count {
                    if claimed[other] { continue }
                    let otherGroup = buffer[other].exactGroup
                    if seedGroup >= 0 && seedGroup == otherGroup { continue }
                    // Split into named steps: Swift 6.3.3 times out type-checking
                    // dense bit expressions written as one line.
                    let difference = seedBits ^ buffer[other].bits
                    let distance = difference.nonzeroBitCount
                    guard distance <= threshold else { continue }
                    claimed[other] = true
                    matches.append(RawMatch(id: buffer[other].id, distance: distance))
                }

                guard !matches.isEmpty else { continue }
                claimed[seed] = true
                // Closest first, then by the order the seed pass saw them,
                // which is the caller's name order.
                let sorted = matches.enumerated().sorted { a, b in
                    a.element.distance != b.element.distance
                        ? a.element.distance < b.element.distance
                        : a.offset < b.offset
                }.map(\.element)
                groups.append(RawGroup(seed: buffer[seed].id, matches: sorted))
            }
        }
        return groups
    }

    // MARK: - Ordering

    /// The grid's order: file name case-insensitively, then the full path as
    /// the tiebreak. Path is unique, so this is a total order and no rowid is
    /// needed to break a tie — which matters, because rowids are reused.
    ///
    /// `lowercased()` rather than SQLite's `COLLATE NOCASE`, which folds ASCII
    /// only: one comparator in Swift is easier to keep consistent across the
    /// three places this file sorts than one split across SQL and Swift.
    static func precedes(_ a: FileRecord, _ b: FileRecord) -> Bool {
        precedes(name: a.name.lowercased(), path: a.path,
                 before: b.name.lowercased(), path: b.path)
    }

    /// The same order over already-folded names, for the near tier, which folds
    /// once per row rather than once per comparison. One definition, so the two
    /// tiers cannot drift into different orders.
    static func precedes(name leftName: String, path leftPath: String,
                         before rightName: String, path rightPath: String) -> Bool {
        if leftName != rightName { return leftName < rightName }
        return leftPath < rightPath
    }
}
