import Foundation

/// What a batch does to each of its items.
///
/// The raw values are the `op_journal.kind` column. They are a persisted
/// contract — the launch-time reconcile reads rows written by an earlier build
/// — so a case is added, never renamed.
public enum FileOperationKind: String, Sendable, Codable, Hashable, CaseIterable {
    /// Source is gone from its old path and present at the new one. Within one
    /// volume this is `rename(2)`; across volumes it is a copy followed by a
    /// delete, journalled as one `move` row carrying both paths so the
    /// reconcile can recognise "src exists AND dst exists" as copy-done,
    /// delete-not.
    case move
    /// Source stays; a second file appears at `dst`.
    case copy
    /// Source goes to the Trash. `trash_url` records where, which is what makes
    /// it undoable.
    case trash
    /// Source is unlinked. Not undoable; the UI puts it behind a confirmation
    /// naming the count.
    case delete
}

/// The lifecycle of one `op_journal` row.
///
/// **This is the contract the launch-time reconcile and undo (#6) read.** The
/// raw values are persisted, so a case is added, never renamed, and the meaning
/// of an existing case is never redefined.
///
/// - `in_flight` — the row was written and the filesystem was then touched, or
///   was about to be. **The outcome is unknown.** This is the only state that
///   needs the filesystem consulted: the reconcile re-`stat`s `src` and `dst`
///   and believes what it finds. A batch that was cancelled, crashed, or threw
///   leaves its un-attempted rows here, as does the one genuinely partial case
///   the operator can reach — a cross-volume move whose copy landed and whose
///   source removal failed.
/// - `complete` — the filesystem operation succeeded *and* the index was
///   updated, in that order, with the mark written in the same transaction as
///   the index change. Undo may reverse it; the reconcile never re-examines it.
/// - `failed` — the operation was attempted and failed. **Nothing changed**:
///   no file moved, no partial destination survives, no index row was touched.
///   Terminal. Neither undo nor the reconcile acts on it.
/// - `skipped` — the item was journalled and then deliberately not attempted,
///   because the volume went away before its turn. Nothing changed. Terminal.
///   (An item the user resolved to *skip* at collision time is never journalled
///   at all — the journal records intent, and there was none.)
/// - `reconciled` — **written only by #6.** A row that was `in_flight` and has
///   since been resolved against the filesystem at launch. `FileOperator` never
///   writes it; it is defined here so both sides read one enumeration.
public enum OpJournalState: String, Sendable, Codable, Hashable, CaseIterable {
    case inFlight = "in_flight"
    case complete
    case failed
    case skipped
    case reconciled
}

/// One `op_journal` row, as read back.
public struct OpJournalRow: Sendable, Equatable {
    public let opID: Int64
    public let batchID: String
    public let kind: FileOperationKind
    public let src: String
    public let dst: String?
    public let trashURL: String?
    public let timestamp: Double
    public let state: OpJournalState

    public init(opID: Int64, batchID: String, kind: FileOperationKind, src: String,
                dst: String?, trashURL: String?, timestamp: Double, state: OpJournalState) {
        self.opID = opID; self.batchID = batchID; self.kind = kind; self.src = src
        self.dst = dst; self.trashURL = trashURL; self.timestamp = timestamp
        self.state = state
    }
}

/// Why one item of a batch did nothing.
public enum FileOperationSkip: Sendable, Equatable, Hashable {
    /// The user resolved this item's collision as "skip".
    case collisionResolved
    /// The volume holding the source or the destination stopped answering
    /// before this item's turn. Everything after the first such item is skipped
    /// rather than attempted: a batch that keeps trying on a vanished drive
    /// produces a page of identical failures and, worse, would let a remount of
    /// something *else* at the same path be written to.
    case volumeUnmounted
    /// A move whose resolved destination is where the file already is.
    case alreadyAtDestination
}

/// Why one item of a batch failed. Every case means the same thing about state:
/// nothing on disk and nothing in the index changed — except
/// `sourceRemovalFailed`, which says so itself.
public enum FileOperationFailure: Error, Sendable, Equatable, Hashable {
    /// The source was gone by the time the item ran. The realistic cause is the
    /// gap between planning and executing, which a pre-flight cannot close.
    case sourceVanished
    /// `EACCES`/`EPERM` — the source could not be read or unlinked, or the
    /// destination directory could not be written to. macOS reports a
    /// directory the user cannot write and a file the user cannot remove
    /// through the same errno; the path in the result says which.
    case permissionDenied
    /// `EROFS` — the destination is on a filesystem mounted read-only. Distinct
    /// from `permissionDenied` because no `chmod` fixes it.
    case destinationReadOnly
    /// `ENOSPC`/`EDQUOT`.
    case diskFull
    /// The volume stopped answering while this item was running.
    case volumeUnmounted
    /// The copy returned success but the destination is not the size of the
    /// source. The partial destination has been removed. **This is the guard
    /// that keeps hash carry-over honest**: a short copy that inherited the
    /// original's `content_hash` would be a permanently wrong digest on a file
    /// nothing would ever re-hash.
    case copyIncomplete
    /// A cross-volume move whose copy landed and whose source removal failed.
    /// **Both paths now exist.** The journal row is deliberately left
    /// `in_flight` for this case alone, because it is the one outcome the
    /// operator genuinely does not know how to describe — #6's reconcile
    /// re-`stat`s both and decides.
    case sourceRemovalFailed
    /// The `replace` policy could not clear the existing destination.
    case destinationNotReplaceable
    /// The index transaction failed after the filesystem operation succeeded.
    /// The files moved; the rows did not. The journal row stays `in_flight`.
    case indexWriteFailed(String)
    /// Anything else, described by the underlying error.
    case other(String)
}

public enum FileOperationOutcome: Sendable, Equatable, Hashable {
    case completed
    case skipped(FileOperationSkip)
    case failed(FileOperationFailure)
}

/// What happened to one item of a batch. One result per *item*, not per file:
/// companions ride with their image and share its verdict, which is what makes
/// the summary sheet a list of photos rather than a list of sidecars.
public struct FileOperationResult: Sendable, Equatable {
    public let source: URL
    /// Where it ended up, for `move` and `copy`.
    public let destination: URL?
    /// Where `trashItem` put it. Nil for every other kind.
    public let trashURL: URL?
    /// The companion files that travelled with `source`.
    public let companions: [URL]
    public let outcome: FileOperationOutcome

    public init(source: URL, destination: URL?, trashURL: URL?, companions: [URL],
                outcome: FileOperationOutcome) {
        self.source = source; self.destination = destination; self.trashURL = trashURL
        self.companions = companions; self.outcome = outcome
    }

    public var isCompleted: Bool { outcome == .completed }
}

public enum FileOperatorError: Error, Equatable, Sendable {
    /// `move` and `copy` need somewhere to go.
    case destinationRequired
    /// `trash` and `delete` do not take a destination; passing one is a caller
    /// bug worth surfacing rather than ignoring.
    case destinationNotAllowed
    /// The destination is not a directory that currently exists.
    case destinationUnreadable(String)
    /// `execute` was handed a plan with collisions nobody resolved. The item
    /// indices are carried so the caller can say which.
    case unresolvedCollisions([Int])
}

// MARK: - errno mapping

enum FileOperationErrorMap {
    /// The POSIX code underneath a Foundation error, if there is one.
    ///
    /// `FileManager` wraps its failures in `NSCocoaErrorDomain` and keeps the
    /// real cause in `NSUnderlyingErrorKey`; `copyfile(3)` is surfaced here as
    /// a bare `POSIXError`. Both are unwrapped in one place so the failure
    /// taxonomy is derived from errno rather than from Cocoa's coarser codes.
    static func posixCode(_ error: any Error) -> Int32? {
        if let posix = error as? POSIXError { return posix.code.rawValue }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return nil
    }
}
