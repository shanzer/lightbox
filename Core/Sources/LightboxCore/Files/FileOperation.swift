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
/// **Replace has its own rows.** The file a `replace` policy displaces is a
/// photo the user did not select, and moving it aside is a filesystem mutation
/// like any other, so it gets a row of its own in the same up-front
/// transaction: `kind = .trash`, `src` = the displaced file's path, `dst` = the
/// dot-prefixed stash it waits in. It reaches `complete` with `trash_url` set
/// once the stash has gone to the Trash, `failed` once the file has been put
/// back, and stays `in_flight` in between — which is the window a crash lands
/// in.
///
/// **How to read an `in_flight` aside row: `stat` `dst` first, then fall back to
/// `trash_url`.** The row covers two moments, and only the filesystem
/// distinguishes them. Before the disposal the photo is at `dst`, the stash;
/// after `trashItem` has returned but before the row could be settled it is at
/// `trash_url` and `dst` is gone. Reading either field alone is wrong half the
/// time — and without the row at all the file is an unreferenced dot-file whose
/// index row the next tier 0 pass prunes.
///
/// **`trash_url` on a row that is not `complete`** is where the file went, not a
/// promise that it is still there. On a `failed` row it is forensic: the file
/// was put back, and the URL records where it briefly was. On an `in_flight` row
/// it is live, and it is the second half of the rule above. The `state` says
/// which.
///
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
    /// A file reached the Trash and where it went could not be written down —
    /// either the system declined to report the destination, or the journal
    /// write failed. **The photo is in the Trash and nothing derivable names
    /// it**: the Trash renames on collision, so the path cannot be reconstructed
    /// from the original. The message carries whatever was known, and the item's
    /// rows are left `in_flight` rather than `failed`, which would claim the
    /// file never moved.
    case trashURLNotRecorded(String)
    /// A rollback could not put things back. **This is the one failure that
    /// does not mean "nothing changed"** — part of the item is at the
    /// destination, or a replaced file is still in its stash, and the journal
    /// rows are deliberately left `in_flight` because only the filesystem knows
    /// what is where. The string names what could not be undone.
    case rollbackIncomplete(String)
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
    /// The batch was cancelled between two items.
    ///
    /// Carries the results of everything already finished, because a cancelled
    /// batch has done real work: files moved, rows rewritten, journal rows
    /// marked. Throwing a bare `CancellationError` would hand the summary sheet
    /// nothing to show for it, and "what did it manage before I stopped it" is
    /// the first question a user asks.
    case cancelled(completed: [FileOperationResult])
    /// `move` and `copy` need somewhere to go.
    case destinationRequired
    /// `trash` and `delete` do not take a destination; passing one is a caller
    /// bug worth surfacing rather than ignoring.
    case destinationNotAllowed
    /// The destination is not a directory that currently exists.
    case destinationUnreadable(String)
    /// A source's own directory could not be listed, so its companions cannot
    /// be found.
    ///
    /// Thrown rather than shrugged off with an empty listing. "No companions"
    /// and "the companions could not be looked for" are different claims, and
    /// acting on the first when the second is true moves a RAW and leaves its
    /// `.xmp` behind — the exact orphaning companion handling exists to
    /// prevent, arrived at silently.
    case sourceDirectoryUnreadable(String)
    /// `execute` was handed a plan with collisions nobody resolved. The item
    /// indices are carried so the caller can say which.
    case unresolvedCollisions([Int])
}

// MARK: - errno mapping

enum FileOperationErrorMap {
    /// The POSIX code underneath a Foundation error, if there is one.
    ///
    /// `FileManager`'s path operations wrap their failures in
    /// `NSCocoaErrorDomain` and keep the real cause in `NSUnderlyingErrorKey`;
    /// `copyfile(3)` is surfaced here as a bare `POSIXError`. Both are unwrapped
    /// in one place so the failure taxonomy is derived from errno.
    ///
    /// **`trashItem` is the exception, and it is why this cannot be the only
    /// lookup.** It is implemented over Carbon File Manager, so it reports
    /// `NSCocoaErrorDomain` with an `NSOSStatusErrorDomain` underlying error —
    /// `-43 fnfErr`, `-5000 afpAccessDenied` — and never a POSIX one. Reading
    /// only errno made every trash failure `.other`, which is a failure taxonomy
    /// that does not classify the operation the user runs most.
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

    /// The failure a Cocoa error code names, for the errors that carry no
    /// errno. Codes are `CocoaError.Code` raw values, spelled numerically
    /// because several of them have no symbol in the Swift overlay.
    static func cocoaFailure(_ code: Int) -> FileOperationFailure? {
        switch code {
        case 4, 260: .sourceVanished          // fileNoSuchFile, fileReadNoSuchFile
        case 257, 513: .permissionDenied      // fileReadNoPermission, fileWriteNoPermission
        case 640: .diskFull                   // fileWriteOutOfSpace
        case 642: .destinationReadOnly        // fileWriteVolumeReadOnly
        case 516: .destinationNotReplaceable  // fileWriteFileExists
        default: nil
        }
    }

    /// The failure an OSStatus names. `trashItem` reports through these.
    static func osStatusFailure(_ code: Int) -> FileOperationFailure? {
        switch code {
        case -43, -120: .sourceVanished           // fnfErr, dirNFErr
        case -54, -49, -5000: .permissionDenied   // permErr, opWrErr, afpAccessDenied
        case -34, -108: .diskFull                 // dskFulErr, memFullErr
        case -44, -46: .destinationReadOnly       // wPrErr, vLckdErr
        case -35, -36, -65: .volumeUnmounted      // nsvErr, ioErr, offLinErr
        default: nil
        }
    }

    /// Walks an error and its underlying chain looking for a domain this knows
    /// how to classify. Nested because `trashItem` buries the OSStatus one level
    /// down, and a `copyfile` failure surfaced through `FileManager` buries the
    /// POSIX one just as deep.
    static func domainFailure(_ error: any Error) -> FileOperationFailure? {
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 4 {
            if ns.domain == NSCocoaErrorDomain, let mapped = cocoaFailure(ns.code) {
                return mapped
            }
            if ns.domain == NSOSStatusErrorDomain, let mapped = osStatusFailure(ns.code) {
                return mapped
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }
}
