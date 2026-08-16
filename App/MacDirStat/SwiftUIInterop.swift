import AppKit
import SwiftUI

/// Proof that SwiftUI is linked and usable at the macOS 11.0 floor, in the one
/// shape the spec permits: a self-contained leaf pane hosted by
/// `NSHostingController` (spec §4.1). SwiftUI never appears on the hot path —
/// the tree is an `NSOutlineView` and the treemap a Core Graphics `NSView`.
///
/// Scaffold (ticket 02): the inspector, progress panel, error/exclusion summary
/// and empty states replace this placeholder in tickets 07–09.
enum SwiftUIInterop {
    /// A hosting controller wrapping an empty leaf view.
    ///
    /// `NSHostingController` is macOS 10.15+, below the floor, so no
    /// availability guard is needed. Everything inside the hosted view must
    /// stay Big Sur-compatible — `Table`, `Canvas`, `NavigationSplitView` and
    /// `searchable` are all above the floor (spec §4.4) and are flagged by
    /// `Scripts/check-post-bigsur-apis.sh`.
    static func makeLeafHostingController() -> NSHostingController<some View> {
        NSHostingController(rootView: EmptyView())
    }
}
