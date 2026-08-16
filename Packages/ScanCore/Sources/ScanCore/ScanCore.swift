import Foundation

/// The scan engine's module marker.
///
/// `ScanCore` owns traversal, aggregation, cancellation, progress and errors
/// (spec §3, §5). It is Foundation-only and knows nothing of AppKit or SwiftUI,
/// so it unit-tests headlessly.
///
/// The entry point is ``Scanner`` (spec §5.1); ``DirectoryProbe`` is the
/// read-only filesystem seam it talks to. The production `FileManager` probe
/// lands in ticket 05.
public enum ScanCore {
    /// The deployment floor this package is built against (spec §4.2).
    public static let minimumSupportedMacOS = "11.0"
}
