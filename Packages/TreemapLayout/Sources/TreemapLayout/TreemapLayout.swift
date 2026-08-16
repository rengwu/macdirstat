import Foundation

/// The treemap layout's module marker.
///
/// `TreemapLayout` is the pure rectangle layout (spec §6): a function of
/// `(tree, viewport size)` producing individual and per-directory aggregate
/// boxes. It is Foundation-only and never mutates the tree, so it is
/// snapshot/geometry-testable without a window.
///
/// This file is scaffold (ticket 02): it carries no layout behaviour. The
/// squarified algorithm, the merge rule and hit testing land in ticket 06.
public enum TreemapLayout {
    /// The deployment floor this package is built against (spec §4.2).
    public static let minimumSupportedMacOS = "11.0"
}
