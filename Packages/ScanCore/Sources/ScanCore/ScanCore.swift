import Foundation

/// The scan engine's module marker.
///
/// `ScanCore` owns traversal, aggregation, cancellation, progress and errors
/// (spec §3, §5). It is Foundation-only and knows nothing of AppKit or SwiftUI,
/// so it unit-tests headlessly.
///
/// This file is scaffold (ticket 02): it carries no scan behaviour. The
/// `Scanner` actor, `ScanRequest`/`ScanEvent`/`ScanResult` and the
/// `DirectoryProbe` seam land in tickets 03–05.
public enum ScanCore {
    /// The deployment floor this package is built against (spec §4.2).
    public static let minimumSupportedMacOS = "11.0"
}
