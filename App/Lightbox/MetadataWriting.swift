import Foundation
import LightboxCore

/// The window's seam onto `MetadataWriter`.
///
/// **It exists so the App suite can run on a machine with no exiftool.** CI is
/// a clean `macos-26` runner and has none, and `MetadataWriter.availability`
/// consults `PATH` — so a test that asserted "with the writer unavailable no
/// field is editable" against the real writer would pass on CI for the wrong
/// reason and fail on the developer's machine, which is the shape of a test
/// that proves nothing. Everything the window decides — how many batches a
/// commit becomes, what a refusal does, whether the grid reloads — is asserted
/// against a stub through this protocol, and the one test that actually writes
/// bytes skips on `MetadataWriter.availability`, the same lookup the writer
/// itself performs.
protocol MetadataWriting: Sendable {
    /// Resolved off the main actor and cached by the caller. Not a property:
    /// the first call forks `exiftool -ver`.
    func availability() async -> ExiftoolAvailability
    /// Re-runs the lookup, for the *Try Again* the explanation invites. A
    /// cached answer plus "install it, then try again" is how a user who has
    /// just installed exiftool concludes the app is broken.
    func recheckAvailability() async -> ExiftoolAvailability
    /// One batch. Never throws — the per-item results are the report (spec §11).
    /// `progress` is called once per finished item with `(completed, total)`.
    func write(_ edit: MetadataEdit, to urls: [URL],
               progress: @escaping @Sendable (Int, Int) -> Void) async -> [WriteOutcome]
}

/// The real one: a `MetadataWriter` and the index it updates.
///
/// An actor, so the two pieces of mutable state it caches — the writer and its
/// resolved availability — are not touched from two windows at once. The actor
/// itself does no blocking work: `MetadataWriter` runs its body on a dispatch
/// queue of its own (#28), and the availability probe, which forks a process,
/// is pushed onto the *global* queue rather than left on the cooperative pool.
/// `DispatchQueue.global` grows under load; the cooperative pool is exactly
/// `activeProcessorCount` threads wide and never does, so a fork parked on one
/// of its threads is a thread the process has lost.
actor LiveMetadataWriter: MetadataWriting {
    private let store: IndexStore
    private var writer: MetadataWriter?
    private var resolved: ExiftoolAvailability?

    init(store: IndexStore) {
        self.store = store
    }

    func availability() async -> ExiftoolAvailability {
        if let resolved { return resolved }
        let fresh = await Self.probe(recheck: false)
        resolved = fresh
        return fresh
    }

    func recheckAvailability() async -> ExiftoolAvailability {
        let fresh = await Self.probe(recheck: true)
        resolved = fresh
        // The writer captured the *old* answer at init and would keep refusing
        // every item with it. Dropped, so the next write builds one that has
        // heard about the install that just happened.
        writer = nil
        return fresh
    }

    func write(_ edit: MetadataEdit, to urls: [URL],
               progress: @escaping @Sendable (Int, Int) -> Void) async -> [WriteOutcome] {
        let live = await liveWriter()
        return await live.write(edit, to: urls, options: WriteOptions(),
                                updating: store, progress: progress)
    }

    /// Built with an availability that has already been resolved, so
    /// `MetadataWriter.init`'s default argument — which is the probe — is never
    /// evaluated on whatever thread happens to be constructing this.
    private func liveWriter() async -> MetadataWriter {
        if let writer { return writer }
        let made = MetadataWriter(availability: await availability())
        writer = made
        return made
    }

    private static func probe(recheck: Bool) async -> ExiftoolAvailability {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: recheck
                    ? MetadataWriter.recheckAvailability()
                    : MetadataWriter.availability)
            }
        }
    }
}
