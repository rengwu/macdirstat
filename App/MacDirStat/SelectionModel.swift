import Foundation
import ScanCore

/// One directory's merge bucket, as a *selection* rather than a node.
///
/// §7.2: "selecting an aggregate box describes the bucket **without inventing an
/// individual node**." So this carries the bucket's own facts — which directory
/// it belongs to, how many entries it folded, their exact combined bytes — and
/// never a stand-in `ScanNode`.
///
/// The bucket's contents depend on the viewport: a wider treemap folds fewer
/// children. ``directory`` is therefore the stable half of its identity and
/// ``refersToSameBucket(as:)`` is what "still the same selection" means across a
/// relayout; the numbers are refreshed from the new layout by the view.
struct AggregateDescriptor {
    /// The directory whose children were folded.
    let directory: ScanNode
    /// Entries folded in, counted recursively over everything that would
    /// otherwise have had a rectangle.
    var itemCount: Int
    /// Exact sum of the folded subtrees' attributed bytes.
    var bytes: Int64
    /// The folded subtree roots' names, in merge order — the inspector lists
    /// the first few of these.
    var mergedRootNames: [String]

    func refersToSameBucket(as other: AggregateDescriptor) -> Bool {
        directory === other.directory
    }
}

extension AggregateDescriptor: Equatable {
    /// Full-field equality, so a relayout that changes what the bucket holds
    /// counts as a change and repaints the inspector. Identity across a
    /// relayout is ``refersToSameBucket(as:)``, not this.
    static func == (lhs: AggregateDescriptor, rhs: AggregateDescriptor) -> Bool {
        lhs.directory === rhs.directory
            && lhs.itemCount == rhs.itemCount
            && lhs.bytes == rhs.bytes
            && lhs.mergedRootNames == rhs.mergedRootNames
    }
}

/// What the one shared selection can refer to: a node identity, or an
/// aggregate-box descriptor (spec §10).
enum WorkspaceSelection {
    case node(ScanNode)
    case aggregate(AggregateDescriptor)

    var node: ScanNode? {
        if case .node(let node) = self { return node }
        return nil
    }

    var aggregate: AggregateDescriptor? {
        if case .aggregate(let descriptor) = self { return descriptor }
        return nil
    }
}

extension WorkspaceSelection: Equatable {
    static func == (lhs: WorkspaceSelection, rhs: WorkspaceSelection) -> Bool {
        switch (lhs, rhs) {
        case let (.node(left), .node(right)):
            // Node identity, never name or size: two siblings can share both.
            return left === right
        case let (.aggregate(left), .aggregate(right)):
            return left == right
        default:
            return false
        }
    }
}

/// Which pane wrote the selection. The writer needs to know so it does not
/// answer its own change — a treemap click scrolls the tree to the row, a tree
/// click must not scroll it again underneath the user.
enum SelectionSource {
    case tree
    case treemap
    /// Set by code rather than a click: a fresh scan clearing it, or the
    /// treemap refreshing an aggregate's numbers after a relayout.
    case programmatic
}

struct SelectionChange {
    let selection: WorkspaceSelection?
    let source: SelectionSource
}

/// The single source of truth for selection, shared by the tree, the treemap
/// and the inspector (spec §7.2, §10).
///
/// Every pane both observes and writes this one object; none of them holds a
/// selection of its own, which is what makes "bidirectional" a property of the
/// wiring rather than two hand-synchronized copies that can drift.
@MainActor
final class SelectionModel {
    private(set) var selection: WorkspaceSelection?
    private var observers: [(SelectionChange) -> Void] = []

    func addObserver(_ observer: @escaping (SelectionChange) -> Void) {
        observers.append(observer)
    }

    /// Writes the selection and notifies every pane — including the writer,
    /// which is free to recognize its own `source` and do nothing.
    ///
    /// A write that does not change the selection notifies nobody: re-clicking
    /// the same rectangle must not re-scroll the tree, and the tree's own
    /// echo of a treemap-driven change must not bounce back.
    func select(_ newSelection: WorkspaceSelection?, source: SelectionSource) {
        guard newSelection != selection else { return }
        selection = newSelection
        let change = SelectionChange(selection: newSelection, source: source)
        for observer in observers {
            observer(change)
        }
    }

    func clear(source: SelectionSource = .programmatic) {
        select(nil, source: source)
    }
}
