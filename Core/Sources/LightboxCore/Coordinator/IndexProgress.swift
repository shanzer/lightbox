import Foundation

/// A snapshot of an indexing pass, cheap enough to hand to the UI on every
/// update and `Hashable` so a view can diff it rather than redraw on each one.
public struct IndexProgress: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable {
        /// `hashing` and `paused` belong to the tier 1 pass and the pause
        /// control that land in Task 15; they are declared here so the phase
        /// vocabulary the UI binds against does not change under it.
        case idle, walking, reading, hashing, paused, finished
    }

    public var phase: Phase
    /// Files actually read this pass. Files skipped as unchanged are not
    /// counted, so a rescan of an untouched folder finishes at zero.
    public var completed: Int
    public var total: Int
    /// Files whose metadata could not be read. They are still indexed — a
    /// failure here costs dimensions and camera fields, not the row.
    public var failed: Int
    /// Files and directories the walk could not look at. Their rows are
    /// preserved rather than reconciled away, so this is the count of what the
    /// pass deliberately left alone — non-zero means the index is stale by
    /// choice rather than complete.
    public var skipped: Int

    public init(phase: Phase = .idle, completed: Int = 0, total: Int = 0, failed: Int = 0,
                skipped: Int = 0) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.failed = failed
        self.skipped = skipped
    }

    public var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }
}
