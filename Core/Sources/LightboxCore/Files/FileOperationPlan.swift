import Foundation

/// What to do about a destination that is already occupied.
public enum CollisionResolution: String, Sendable, Codable, Hashable, CaseIterable {
    /// Leave this item alone. It is not journalled and not attempted.
    case skip
    /// Give it a free name. The suffix goes on the *basename*, so an item and
    /// its companions stay a matched set: `IMG_0001 2.CR2` beside
    /// `IMG_0001 2.xmp`, never `IMG_0001 2.CR2` beside `IMG_0001.xmp`.
    case rename
    /// Overwrite what is there. The existing file is moved aside first and
    /// removed only once the operation has succeeded, so a failure mid-item
    /// cannot leave the user with neither file.
    case replace
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
    /// Destination paths that are already occupied. **A companion whose own
    /// destination collides is a collision on the parent item** — the whole set
    /// travels together or not at all, so it is resolved together.
    public let collisions: [URL]
    /// What the user chose, or nil if they have not been asked yet.
    public let resolution: CollisionResolution?

    /// Every file this item will touch, the selected one first.
    public var files: [URL] { [source] + companions }

    public var needsResolution: Bool { !collisions.isEmpty && resolution == nil }
}

/// The plan the UI shows and `FileOperator.execute` runs.
///
/// A plan is a value, and resolving a collision produces a *new* plan rather
/// than mutating this one, because the destination names depend on the
/// resolutions of every earlier item: choosing `rename` for item 3 changes
/// which names item 4 finds free. Recomputing the whole thing from one
/// filesystem snapshot is the only way those stay consistent, and it is why the
/// snapshot is taken once, at plan time, and never re-read.
public struct FileOperationPlan: Sendable, Equatable {
    /// The `batch_id` every journal row for this plan carries.
    public let batchID: String
    public let kind: FileOperationKind
    /// Nil for `trash` and `delete`.
    public let destinationDirectory: URL?
    public let includeCompanions: Bool
    public let items: [PlannedItem]

    /// What planning found, kept so a resolution can be applied without going
    /// back to the disk. Lowercased names, because occupancy is decided
    /// case-insensitively (see `CompanionFiles`).
    let occupiedNames: Set<String>
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
                          occupiedNames: occupiedNames, inputs: inputs)
    }

    init(batchID: String, kind: FileOperationKind, destinationDirectory: URL?,
         includeCompanions: Bool, occupiedNames: Set<String>, inputs: [PlanInput]) {
        self.batchID = batchID
        self.kind = kind
        self.destinationDirectory = destinationDirectory
        self.includeCompanions = includeCompanions
        self.occupiedNames = occupiedNames
        self.inputs = inputs
        self.items = Self.derive(kind: kind, destination: destinationDirectory,
                                 occupiedNames: occupiedNames, inputs: inputs)
    }

    /// Turns the inputs and one filesystem snapshot into the items.
    ///
    /// The `claimed` set is the half a naive implementation forgets: two
    /// sources with the same basename headed for one folder collide with *each
    /// other*, and neither of them is on disk yet. Without it a batch happily
    /// plans two files onto one path and the second silently destroys the
    /// first.
    private static func derive(kind: FileOperationKind, destination: URL?,
                               occupiedNames: Set<String>,
                               inputs: [PlanInput]) -> [PlannedItem] {
        guard let destination, kind == .move || kind == .copy else {
            return inputs.map {
                PlannedItem(recordID: $0.recordID, source: $0.source,
                            companions: $0.companions, destination: nil,
                            companionDestinations: [], collisions: [],
                            resolution: nil)
            }
        }

        var claimed: Set<String> = []
        var items: [PlannedItem] = []
        items.reserveCapacity(inputs.count)

        for input in inputs {
            let files = [input.source] + input.companions
            let names = files.map(\.lastPathComponent)
            // A move out of the destination directory into itself would
            // otherwise report every file as colliding with itself, and a
            // `replace` on that would unlink the source before moving it.
            // Exclude a file from its own occupancy check; the item is then
            // detected as already-at-destination and skipped at execute time.
            let ownNames: Set<String> = kind == .move
                ? Set(files.filter { $0.deletingLastPathComponent().path == destination.path }
                           .map { $0.lastPathComponent.lowercased() })
                : []

            func isOccupied(_ name: String) -> Bool {
                let key = name.lowercased()
                if ownNames.contains(key) { return false }
                return occupiedNames.contains(key) || claimed.contains(key)
            }

            let collisions = names.filter(isOccupied)
                .map { destination.appendingPathComponent($0) }

            var chosen = names
            if !collisions.isEmpty {
                switch input.resolution {
                case nil:
                    // Unresolved: show the plain destinations so the sheet can
                    // name what would be overwritten, claim nothing, and leave
                    // `needsResolution` true.
                    items.append(PlannedItem(
                        recordID: input.recordID, source: input.source,
                        companions: input.companions,
                        destination: destination.appendingPathComponent(names[0]),
                        companionDestinations: names.dropFirst()
                            .map { destination.appendingPathComponent($0) },
                        collisions: collisions, resolution: nil))
                    continue
                case .skip?:
                    items.append(PlannedItem(
                        recordID: input.recordID, source: input.source,
                        companions: input.companions, destination: nil,
                        companionDestinations: [], collisions: collisions,
                        resolution: .skip))
                    continue
                case .rename?:
                    chosen = renamed(names, isOccupied: isOccupied)
                case .replace?:
                    break
                }
            }

            for name in chosen { claimed.insert(name.lowercased()) }
            let urls = chosen.map { destination.appendingPathComponent($0) }
            items.append(PlannedItem(
                recordID: input.recordID, source: input.source,
                companions: input.companions, destination: urls[0],
                companionDestinations: Array(urls.dropFirst()),
                collisions: collisions, resolution: input.resolution))
        }
        return items
    }

    /// Finder's suffix, applied to the whole set at once: the smallest `n ≥ 2`
    /// for which *every* name in the set is free. One shared `n` is what keeps
    /// an image and its sidecar matched — picking a suffix per file would put
    /// `IMG_0001 2.CR2` next to `IMG_0001 3.xmp` the moment one of the two
    /// names happened to be taken.
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

/// A planning input before the collision policy is applied. Internal: the
/// public face of a plan is `items`.
struct PlanInput: Sendable, Equatable {
    let recordID: Int64?
    let source: URL
    let companions: [URL]
    var resolution: CollisionResolution?
}
