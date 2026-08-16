import XCTest
@testable import ScanCore

/// Placeholder for the pure-scanner suite (spec §9.1). The real cases —
/// scripted `DirectoryProbe`, virtual clock, event/state machine, aggregation,
/// error bounds, cancellation checkpoints — arrive with tickets 03–05.
final class ScanCoreScaffoldTests: XCTestCase {
    func test_moduleBuildsAgainstTheDeploymentFloor() {
        XCTAssertEqual(ScanCore.minimumSupportedMacOS, "11.0")
    }
}
