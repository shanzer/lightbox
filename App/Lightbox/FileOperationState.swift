import Foundation
import Observation
import LightboxCore

/// The four batch commands, as one enumeration rather than four hand-written
/// menu items.
///
/// Both the menu and `BrowserModel.isEnabled(_:)` are keyed on these cases, so
/// a command cannot exist in the menu with no rule behind it, or have a rule
/// nothing in the menu consults — which is the shape of the bug that left ⌘A
/// mouse-only for a whole task. `MenuCommandTests` walks `allCases` against the
/// real `NSMenu` for exactly that reason.
enum FileCommand: String, CaseIterable, Sendable {
    case moveTo
    case copyTo
    case trash
    case deletePermanently

    /// The menu title, and the string the tests look the item up by.
    ///
    /// Move To…, Copy To… and Delete Permanently… take an ellipsis because each
    /// opens a panel or a sheet before anything happens; Move to Trash does not,
    /// because it acts immediately. That is macOS's rule, not a preference.
    var title: String {
        switch self {
        case .moveTo: "Move To…"
        case .copyTo: "Copy To…"
        case .trash: "Move to Trash"
        case .deletePermanently: "Delete Permanently…"
        }
    }

    /// The batch this command runs. `deletePermanently` is an ordinary
    /// `.delete`; the confirmation in front of it is a sheet, not a different
    /// operation.
    var kind: FileOperationKind {
        switch self {
        case .moveTo: .move
        case .copyTo: .copy
        case .trash: .trash
        case .deletePermanently: .delete
        }
    }
}

/// How far the batch in this window has got.
///
/// A value, replaced wholesale, so the progress sheet cannot observe a
/// half-updated count. `current` is the file the operator has just finished,
/// which is what `FileOperator`'s handler reports.
struct BatchProgress: Equatable, Sendable {
    let kind: FileOperationKind
    var completed: Int
    var total: Int
    var current: URL?

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    var title: String {
        let noun = total == 1 ? "item" : "items"
        switch kind {
        case .move: return "Moving \(total) \(noun)…"
        case .copy: return "Copying \(total) \(noun)…"
        case .trash: return "Moving \(total) \(noun) to the Trash…"
        case .delete: return "Deleting \(total) \(noun)…"
        }
    }
}

/// The last batch that actually did something, kept so ⌘Z has a subject.
///
/// **This is the hook issue #6 attaches to.** It holds the `batchID` — which is
/// what `op_journal` rows are keyed by, so the undo does not have to trust
/// anything in this process — alongside the per-item results, and it names
/// itself for the menu title.
///
/// A permanent delete is deliberately never recorded: an unlinked file does not
/// come back, and an Undo item offering to reverse one would be a lie with the
/// worst possible payload.
struct CompletedBatch: Sendable, Equatable {
    let batchID: String
    let kind: FileOperationKind
    /// Only the items that reached `.completed`. The rest have nothing to undo.
    let results: [FileOperationResult]

    var completedCount: Int { results.count }

    /// "Undo Move 12 Items" — spec §8's undo, named after what it will reverse,
    /// so the menu says what ⌘Z is about to do rather than just that it can.
    var undoTitle: String {
        let noun = completedCount == 1 ? "Item" : "Items"
        let verb = switch kind {
        case .move: "Move"
        case .copy: "Copy"
        case .trash: "Trash"
        case .delete: "Delete"
        }
        return "Undo \(verb) \(completedCount) \(noun)"
    }
}

/// What the summary sheet shows. Built for every batch and *presented* only
/// when something failed — spec §11: a batch is never all-or-nothing, and the
/// sheet exists to report the exceptions, not to congratulate the rule.
struct OperationSummary: Identifiable, Sendable {
    struct Failure: Identifiable, Sendable {
        let id: String
        let source: URL
        let failure: FileOperationFailure
        /// The sentence shown next to the filename. `Core`'s, not this layer's:
        /// see `FileOperationFailure.explanation`.
        var reason: String { failure.explanation }
    }

    let id = UUID()
    let kind: FileOperationKind
    /// Where the batch was going, so Retry Failed can build the same batch
    /// again. Nil for trash and delete, which need none.
    let destinationDirectory: URL?
    let results: [FileOperationResult]
    let wasCancelled: Bool
    let failures: [Failure]
    /// Set when the batch never started — a destination that could not be read,
    /// a source directory that could not be listed. There are no per-item
    /// results in that case, and nothing to retry.
    let planningFailure: String?

    var completedCount: Int { results.filter(\.isCompleted).count }

    var skippedCount: Int {
        results.filter { if case .skipped = $0.outcome { true } else { false } }.count
    }

    /// Retry rebuilds a plan from the failures alone. Skips are not retried:
    /// the user asked for those, or the volume went away and retrying it in the
    /// same breath would fail the same way.
    var canRetry: Bool { !failures.isEmpty }

    var failedSources: [URL] { failures.map(\.source) }

    var headline: String {
        if let planningFailure { return planningFailure }
        let noun = failures.count == 1 ? "item" : "items"
        let stem = "\(failures.count) \(noun) of \(results.count) failed"
        return wasCancelled ? "\(stem). The batch was cancelled." : "\(stem)."
    }

    init(kind: FileOperationKind, destinationDirectory: URL?,
         results: [FileOperationResult], wasCancelled: Bool) {
        self.kind = kind
        self.destinationDirectory = destinationDirectory
        self.results = results
        self.wasCancelled = wasCancelled
        self.planningFailure = nil
        self.failures = results.compactMap { result in
            guard case .failed(let failure) = result.outcome else { return nil }
            return Failure(id: result.source.path, source: result.source, failure: failure)
        }
    }

    /// The batch that never ran.
    init(kind: FileOperationKind, destinationDirectory: URL?, planningFailure: String) {
        self.kind = kind
        self.destinationDirectory = destinationDirectory
        self.results = []
        self.wasCancelled = false
        self.failures = []
        self.planningFailure = planningFailure
    }
}

/// The one sheet this window may be showing.
///
/// One enumeration and one `.sheet(item:)` rather than four independent
/// `isPresented` bindings: the four are mutually exclusive by construction —
/// collisions are answered *before* the progress sheet, and the summary only
/// exists after it — and stacked `.sheet` modifiers on one view are exactly how
/// SwiftUI ends up presenting nothing at all.
enum ActiveSheet: Identifiable {
    case collisions(CollisionSheetModel)
    /// Reads `BrowserModel.batchProgress`, which is replaced as the batch runs.
    /// The case carries nothing so that a progress update does not change the
    /// sheet's identity and re-present it.
    case progress
    case summary(OperationSummary)
    case confirmPermanentDelete(count: Int)

    var id: String {
        switch self {
        case .collisions: "collisions"
        case .progress: "progress"
        case .summary: "summary"
        case .confirmPermanentDelete: "confirmPermanentDelete"
        }
    }
}

/// The collision sheet's state: one plan, and the resolutions applied to it.
///
/// A class rather than a value because the sheet mutates it from four different
/// controls, but the *plan* inside is still a value and is still replaced
/// wholesale — `FileOperationPlan.resolvingCollision(at:with:)` recomputes every
/// destination from one filesystem snapshot, because choosing rename for item 3
/// changes which names item 4 finds free. Nothing here second-guesses that; this
/// type only decides what to ask and what to call it.
@MainActor
@Observable
final class CollisionSheetModel: Identifiable {
    nonisolated let id = UUID()

    private(set) var plan: FileOperationPlan

    init(plan: FileOperationPlan) {
        self.plan = plan
    }

    /// Every item with a collision, answered or not. The sheet lists all of
    /// them, so a choice can be changed before Continue.
    var collidingIndices: [Int] {
        plan.items.indices.filter { !plan.items[$0].collisions.isEmpty }
    }

    /// The ones still waiting on the user.
    var pendingIndices: [Int] { plan.unresolvedCollisionIndices }

    /// **Nothing runs until this is true.** `FileOperator.execute` refuses a
    /// plan with an open collision, so this is a restatement of its contract
    /// rather than a second rule.
    var isFullyResolved: Bool { !plan.hasUnresolvedCollisions }

    func resolve(itemAt index: Int, with resolution: CollisionResolution) {
        plan = plan.resolvingCollision(at: index, with: resolution)
    }

    func resolveAll(with resolution: CollisionResolution) {
        plan = plan.resolvingAllCollisions(with: resolution)
    }

    func resolution(forItemAt index: Int) -> CollisionResolution? {
        plan.items.indices.contains(index) ? plan.items[index].resolution : nil
    }

    func name(forItemAt index: Int) -> String {
        plan.items.indices.contains(index)
            ? plan.items[index].source.lastPathComponent : ""
    }

    /// Whether Replace means anything for this item.
    ///
    /// It does not when the claim came from the batch itself: there is no file
    /// on disk to displace, and the file that *is* going there is one of the
    /// user's own. `Core` degrades the request to `rename` rather than honouring
    /// it (`PlannedItem.effectiveResolution`), so offering the button would be
    /// offering an outcome that cannot happen.
    func offersReplace(forItemAt index: Int) -> Bool {
        guard plan.items.indices.contains(index) else { return false }
        return !plan.items[index].hasIntraBatchCollision
    }

    /// What is in the way, in the user's words.
    ///
    /// The two kinds are described differently on purpose. "Already exists at
    /// the destination" is false for an intra-batch claim — nothing is there
    /// yet — and a user told that would go looking in the destination folder
    /// for a file that is not in it.
    func describeCollision(forItemAt index: Int) -> String {
        guard plan.items.indices.contains(index) else { return "" }
        let item = plan.items[index]
        let names = item.collisions.map(\.path.lastPathComponent)
        let list = names.joined(separator: ", ")
        if item.hasIntraBatchCollision {
            return "\(list) — another file in this batch is going to that name."
        }
        return "\(list) — already exists at the destination."
    }

    /// What each item will be called once the choice is applied. Read off the
    /// rebuilt plan rather than predicted, so the sheet and the batch cannot
    /// disagree about the suffix.
    func destinationName(forItemAt index: Int) -> String? {
        guard plan.items.indices.contains(index) else { return nil }
        return plan.items[index].destination?.lastPathComponent
    }
}
