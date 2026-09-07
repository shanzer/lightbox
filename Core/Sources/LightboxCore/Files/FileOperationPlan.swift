import Foundation

/// What to do about a destination that is already occupied.
public enum CollisionResolution: String, Sendable, Codable, Hashable, CaseIterable {
    /// Leave this item alone. It is not journalled and not attempted.
    case skip
    /// Give it a free name. The suffix goes on the *basename*, so an item and
    /// its companions stay a matched set: `IMG_0001 2.CR2` beside
    /// `IMG_0001 2.xmp`, never `IMG_0001 2.CR2` beside `IMG_0001.xmp`.
    case rename
    /// Overwrite what is there. The existing file is moved aside first, under a
    /// journalled row, and only sent to the Trash once the operation that takes
    /// its place has succeeded — so a failure mid-item cannot leave the user
    /// with neither file, and a completed replace is still undoable.
    ///
    /// **Only meaningful against a file that is really on disk.** See
    /// `FileOperationCollision.Kind.claimedInBatch`.
    case replace
}

/// A destination path that something else has a claim on, and *what* the claim
/// is — because the two cases are not the same question and do not offer the
/// same answers.
public struct FileOperationCollision: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        /// A file is already at this path on disk. `replace` means something
        /// here: there is an existing file, and the user may choose to displace
        /// it.
        case occupied
        /// **An earlier item of this same batch is going here.** Nothing is on
        /// disk yet. `replace` is meaningless — and worse than meaningless: the
        /// "existing file" it would displace is a photo the batch itself put
        /// there moments ago, so honouring it destroys one of the user's own
        /// selected files and reports `complete` for both. `replace` is
        /// therefore degraded to `rename` for these; see
        /// `PlannedItem.effectiveResolution`.
        case claimedInBatch
    }

    public let path: URL
    public let kind: Kind

    public init(path: URL, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

/// A file the `replace` policy will displace, and where it goes on the way out.
///
/// The aside is a filesystem mutation of a photo the user did not select, so it
/// gets its own journal row (`kind = .trash`, `src` = `occupant`, `dst` =
/// `stash`). Both paths are decided at plan time precisely so that row can be
/// written *before* the file is touched: a stash path invented at execute time
/// could not be journalled up front, and a crash between the aside and the
/// disposal would leave the photo as an unreferenced dot-file whose index row
/// the next tier 0 pass prunes.
public struct PlannedReplacement: Sendable, Equatable, Hashable {
    /// The file on disk that will be displaced, at **its own path**, which may
    /// differ in case from the destination being written. See
    /// `FileOperationPlan.occupants`.
    public let occupant: URL
    /// Where it waits while the operation runs. A dot-prefixed sibling, so the
    /// aside is a `rename(2)` rather than a copy, and so `Walker.isJunk` never
    /// indexes it.
    public let stash: URL

    public init(occupant: URL, stash: URL) {
        self.occupant = occupant
        self.stash = stash
    }
}

/// One item of a plan: a selected file, whatever travels with it, and where it
/// is going once the collision policy has been applied.
public struct PlannedItem: Sendable, Equatable {
    /// `files.id` for the selected file, or nil if it is not indexed.
    public let recordID: Int64?
    public let source: URL
    /// Companion files that will travel with `source`, in a stable order.
    public let companions: [URL]
    /// Where `source` is going, or nil for `trash`/`delete` and for an item
    /// resolved to `skip`.
    public let destination: URL?
    /// Where each entry of `companions` is going, index-parallel with it.
    public let companionDestinations: [URL]
    /// Destination paths something else has a claim on. **A companion whose own
    /// destination collides is a collision on the parent item** — the whole set
    /// travels together or not at all, so it is resolved together.
    public let collisions: [FileOperationCollision]
    /// What the user chose, or nil if they have not been asked yet.
    public let resolution: CollisionResolution?
    /// What will actually happen, which differs from `resolution` in exactly one
    /// case: `replace` against a collision this batch created itself becomes
    /// `rename`, because there is nothing on disk to replace and the file that
    /// *is* going there is the user's own. A sheet should show this rather than
    /// `resolution`.
    public let effectiveResolution: CollisionResolution?
    /// The files this item will displace. Empty unless `effectiveResolution` is
    /// `replace`.
    public let replacements: [PlannedReplacement]

    /// Every file this item will touch, the selected one first.
    public var files: [URL] { [source] + companions }

    public var needsResolution: Bool { !collisions.isEmpty && resolution == nil }

    /// Whether any of this item's collisions is with the batch itself. A sheet
    /// must not offer "replace the existing file" for these, and must not
    /// describe them as already existing at the destination — nothing is there.
    public var hasIntraBatchCollision: Bool {
        collisions.contains { $0.kind == .claimedInBatch }
    }
}

/// The plan the UI shows and `FileOperator.execute` runs.
///
/// A plan is a value, and resolving a collision produces a *new* plan rather
/// than mutating this one, because the destination names depend on the
/// resolutions of every earlier item: choosing `rename` for item 3 changes which
/// names item 4 finds free. Recomputing the whole thing from one filesystem
/// snapshot is the only way those stay consistent, and it is why the snapshot is
/// taken once, at plan time, and never re-read.
public struct FileOperationPlan: Sendable, Equatable {
    /// The `batch_id` every journal row for this plan carries.
    public let batchID: String
    public let kind: FileOperationKind
    /// Nil for `trash` and `delete`.
    public let destinationDirectory: URL?
    public let includeCompanions: Bool
    public let items: [PlannedItem]

    /// What is in the destination directory, as **lowercased name → the name as
    /// it really is on disk**.
    ///
    /// Both halves are needed, for different reasons. Occupancy is decided
    /// case-insensitively, because the volumes this app is built for are APFS
    /// and HFS+ in their default configuration, where `IMG_0001.JPG` and
    /// `img_0001.jpg` are one file. But the file a `replace` displaces has to be
    /// named *exactly*, or `record(atPath:)` misses its index row and the row
    /// outlives its file — a stale entry carrying a dead photo's `content_hash`,
    /// in the table duplicate detection reads.
    let occupants: [String: String]
    /// The volume answering at each distinct source directory when the plan was
    /// made, keyed by directory path. Re-checked per item; see
    /// `FileOperator.volumesStillAnswering`.
    let sourceVolumes: [String: VolumeIdentity]
    /// The volume answering at `destinationDirectory` when the plan was made.
    let destinationVolume: VolumeIdentity?
    /// The un-resolved inputs, in order, so `items` can be rebuilt.
    let inputs: [PlanInput]

    public var hasUnresolvedCollisions: Bool { items.contains { $0.needsResolution } }

    public var unresolvedCollisionIndices: [Int] {
        items.indices.filter { items[$0].needsResolution }
    }

    /// The same plan with `resolution` applied to item `index`.
    public func resolvingCollision(at index: Int,
                                   with resolution: CollisionResolution) -> FileOperationPlan {
        var updated = inputs
        guard updated.indices.contains(index) else { return self }
        updated[index].resolution = resolution
        return rebuilt(with: updated)
    }

    /// The same plan with `resolution` applied to every item that still needs
    /// one — the "apply to all" the sheet offers.
    public func resolvingAllCollisions(
        with resolution: CollisionResolution) -> FileOperationPlan {
        var updated = inputs
        for index in items.indices where items[index].needsResolution {
            updated[index].resolution = resolution
        }
        return rebuilt(with: updated)
    }

    private func rebuilt(with inputs: [PlanInput]) -> FileOperationPlan {
        FileOperationPlan(batchID: batchID, kind: kind,
                          destinationDirectory: destinationDirectory,
                          includeCompanions: includeCompanions,
                          occupants: occupants, sourceVolumes: sourceVolumes,
                          destinationVolume: destinationVolume, inputs: inputs)
    }

    init(batchID: String, kind: FileOperationKind, destinationDirectory: URL?,
         includeCompanions: Bool, occupants: [String: String],
         sourceVolumes: [String: VolumeIdentity], destinationVolume: VolumeIdentity?,
         inputs: [PlanInput]) {
        self.batchID = batchID
        self.kind = kind
        self.destinationDirectory = destinationDirectory
        self.includeCompanions = includeCompanions
        self.occupants = occupants
        self.sourceVolumes = sourceVolumes
        self.destinationVolume = destinationVolume
        self.inputs = inputs
        self.items = Self.derive(batchID: batchID, kind: kind,
                                 destination: destinationDirectory,
                                 occupants: occupants, inputs: inputs)
    }

    /// Turns the inputs and one filesystem snapshot into the items.
    ///
    /// The `claimed` set is the half a naive implementation forgets: two sources
    /// with the same basename headed for one folder collide with *each other*,
    /// and neither of them is on disk yet. Without it a batch happily plans two
    /// files onto one path and the second silently destroys the first. Recording
    /// *which* of the two kinds a collision is — see
    /// `FileOperationCollision.Kind` — is the other half, and without it
    /// `replace` destroys the first anyway, with both items reporting success.
    private static func derive(batchID: String, kind: FileOperationKind,
                               destination: URL?, occupants: [String: String],
                               inputs: [PlanInput]) -> [PlannedItem] {
        guard let destination, kind == .move || kind == .copy else {
            return inputs.map {
                PlannedItem(recordID: $0.recordID, source: $0.source,
                            companions: $0.companions, destination: nil,
                            companionDestinations: [], collisions: [],
                            resolution: nil, effectiveResolution: nil,
                            replacements: [])
            }
        }

        var claimed: Set<String> = []
        var items: [PlannedItem] = []
        items.reserveCapacity(inputs.count)

        for (index, input) in inputs.enumerated() {
            let files = [input.source] + input.companions
            let names = files.map(\.lastPathComponent)
            // A move out of the destination directory into itself would
            // otherwise report every file as colliding with itself, and a
            // `replace` on that would displace the source before moving it.
            // Exclude a file from its own occupancy check; the item is then
            // detected as already-at-destination and skipped at execute time.
            let ownNames: Set<String> = kind == .move
                ? Set(files.filter { $0.deletingLastPathComponent().path == destination.path }
                           .map { $0.lastPathComponent.lowercased() })
                : []

            func claimKind(_ name: String) -> FileOperationCollision.Kind? {
                let key = name.lowercased()
                if ownNames.contains(key) { return nil }
                // The batch's own claim is tested first: where both are true,
                // the dangerous one governs.
                if claimed.contains(key) { return .claimedInBatch }
                if occupants[key] != nil { return .occupied }
                return nil
            }
            func isOccupied(_ name: String) -> Bool { claimKind(name) != nil }

            let collisions = names.compactMap { name -> FileOperationCollision? in
                guard let claim = claimKind(name) else { return nil }
                let real = occupants[name.lowercased()] ?? name
                return FileOperationCollision(
                    path: destination.appendingPathComponent(claim == .occupied ? real : name),
                    kind: claim)
            }

            var effective = input.resolution
            // **The intra-batch guard.** `replace` may only displace a file that
            // is really on disk. Where the claim came from this batch there is
            // nothing to displace and the file heading there is one of the
            // user's own, so the request is degraded to the policy that keeps
            // both. An item with a mixture degrades too: honouring `replace` for
            // its on-disk half would still put it on top of the batch's.
            if effective == .replace,
               collisions.contains(where: { $0.kind == .claimedInBatch }) {
                effective = .rename
            }

            var chosen = names
            var replacements: [PlannedReplacement] = []
            if !collisions.isEmpty {
                switch effective {
                case nil:
                    // Unresolved: show the plain destinations so the sheet can
                    // name what is in the way, claim nothing, and leave
                    // `needsResolution` true.
                    items.append(PlannedItem(
                        recordID: input.recordID, source: input.source,
                        companions: input.companions,
                        destination: destination.appendingPathComponent(names[0]),
                        companionDestinations: names.dropFirst()
                            .map { destination.appendingPathComponent($0) },
                        collisions: collisions, resolution: input.resolution,
                        effectiveResolution: nil, replacements: []))
                    continue
                case .skip?:
                    items.append(PlannedItem(
                        recordID: input.recordID, source: input.source,
                        companions: input.companions, destination: nil,
                        companionDestinations: [], collisions: collisions,
                        resolution: input.resolution, effectiveResolution: .skip,
                        replacements: []))
                    continue
                case .rename?:
                    chosen = renamed(names, isOccupied: isOccupied)
                case .replace?:
                    // Every one of these is `.occupied` — the guard above ruled
                    // the other kind out — so each names a real file, at the
                    // path it really has.
                    replacements = collisions.enumerated().map { offset, collision in
                        PlannedReplacement(
                            occupant: collision.path,
                            stash: stashURL(for: collision.path, batchID: batchID,
                                            item: index, offset: offset))
                    }
                }
            }

            for name in chosen { claimed.insert(name.lowercased()) }
            let urls = chosen.map { destination.appendingPathComponent($0) }
            items.append(PlannedItem(
                recordID: input.recordID, source: input.source,
                companions: input.companions, destination: urls[0],
                companionDestinations: Array(urls.dropFirst()),
                collisions: collisions, resolution: input.resolution,
                effectiveResolution: effective, replacements: replacements))
        }
        return items
    }

    /// Where a displaced file waits. Deterministic rather than a fresh UUID per
    /// call, because `derive` runs again on every resolution and the path has to
    /// be journalled up front: a name that changed between the sheet and the
    /// batch would journal one path and create another.
    private static func stashURL(for occupant: URL, batchID: String,
                                 item: Int, offset: Int) -> URL {
        let short = batchID.prefix(8)
        return occupant.deletingLastPathComponent()
            .appendingPathComponent(".lightbox-replaced-\(short)-\(item)-\(offset)")
    }

    /// Finder's suffix, applied to the whole set at once: the smallest `n ≥ 2`
    /// for which *every* name in the set is free. One shared `n` is what keeps an
    /// image and its sidecar matched — picking a suffix per file would put
    /// `IMG_0001 2.CR2` next to `IMG_0001 3.xmp` the moment one of the two names
    /// happened to be taken.
    private static func renamed(_ names: [String],
                                isOccupied: (String) -> Bool) -> [String] {
        var suffix = 2
        while true {
            let candidates = names.map { name -> String in
                let url = URL(fileURLWithPath: name)
                let ext = url.pathExtension
                let stem = url.deletingPathExtension().lastPathComponent
                return ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            }
            if !candidates.contains(where: isOccupied) { return candidates }
            suffix += 1
            // No bound is needed: each step consumes a name that exists, and a
            // directory holds finitely many.
        }
    }
}

/// A planning input before the collision policy is applied. Internal: the public
/// face of a plan is `items`.
struct PlanInput: Sendable, Equatable {
    let recordID: Int64?
    let source: URL
    let companions: [URL]
    var resolution: CollisionResolution?
}
