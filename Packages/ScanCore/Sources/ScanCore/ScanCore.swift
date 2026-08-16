import Foundation

/// The scan engine's module marker.
///
/// `ScanCore` owns traversal, aggregation, cancellation, progress and errors
/// (spec §3, §5). It is Foundation-only and knows nothing of AppKit or SwiftUI,
/// so it unit-tests headlessly.
///
/// The entry point is ``Scanner`` (spec §5.1); ``DirectoryProbe`` is the
/// read-only filesystem seam it talks to. Hard-link, clone, package, cloud and
/// error-summary semantics land in ticket 04; the production `FileManager`
/// probe in ticket 05.
public enum ScanCore {
    /// The deployment floor this package is built against (spec §4.2).
    public static let minimumSupportedMacOS = "11.0"
}
