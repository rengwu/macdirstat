import Foundation
import ScanCore
import TreemapLayout

/// A `ScanNode` seen through `TreemapLayout`'s input seam.
///
/// **This is a second copy of the app's `TreemapNodeRef`, deliberately.** The
/// app's adapter is `internal`, and `@testable import MacDirStat` cannot work
/// here: this target builds Release, and the app module is compiled without
/// `-enable-testing` there (turning it on would perturb the very Release binary
/// the suite exists to measure). Duplicating twenty lines of switch is the
/// cheaper of the two prices.
///
/// It costs nothing in coverage, because the adapter is not what these tests
/// are about. The claim under test is `TreemapLayout.layout`'s — a bounded
/// visible-box count on a scan-sized tree — and that code is the production
/// code, in its own package. `MacDirStatTests` owns the proof that the app's
/// adapter reports the same things this one does, including package drill-in,
/// which no generated rung contains.
struct ScanNodeTreemapRef: TreemapInputNode, Sendable {
    let node: ScanNode

    var treemapName: String { node.name }

    var treemapKind: TreemapEntryKind {
        switch node.kind {
        case .directory: return .directory
        case .package: return .package
        case .file: return .file
        case .symbolicLink: return .symbolicLink
        case .other: return .other
        }
    }

    var treemapReadState: TreemapReadState {
        switch node.readState {
        case .complete: return .complete
        case .incomplete: return .incomplete
        case .unreadable: return .unreadable
        }
    }

    var treemapAttributedBytes: Int64 { node.subtreeDiskBytes }

    /// Packages present collapsed until drilled into (spec §3.4). No generated
    /// rung builds one, so this is the collapsed half only.
    var treemapPresentedChildren: [ScanNodeTreemapRef] {
        node.kind == .package ? [] : node.children.map(ScanNodeTreemapRef.init(node:))
    }

    /// Constant time, from the count `ScanCore` rolls up during the scan — the
    /// reason a folded subtree never has to be walked (ticket 14). The app's
    /// adapter answers the same way; the walking default in the protocol would
    /// reintroduce exactly the cost these tests measure the absence of.
    var treemapPresentedItemCount: Int {
        node.kind == .package ? (node.subtreeDiskBytes > 0 ? 1 : 0) : node.attributedNodeCount
    }
}

extension TreemapLayoutStatistics {
    /// The count §6.2 says relayout cost is bounded by, against the bound the
    /// merge policy actually implies.
    ///
    /// Every surviving box is at least `mergeThresholdPoints` on both sides, so
    /// no more than `area / threshold²` of them can fit in the viewport. That
    /// is a real ceiling and not a tautology: an implementation that merged by
    /// *area* rather than by both sides, or that stopped iterating after one
    /// pass, would leave sub-threshold strips behind and exceed it.
    static func visibleBoxBound(forViewportArea area: Double) -> Int {
        Int((area / (TreemapMetrics.mergeThresholdPoints * TreemapMetrics.mergeThresholdPoints)).rounded(.up))
    }
}
