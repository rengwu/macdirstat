import XCTest

/// Placeholder for the performance/scale suite (spec §9.1, §8): generated
/// Smoke/Representative/Large/Stress scans, peak RSS, operation counts and
/// relayout bounds.
///
/// Opt-in only: this target is excluded from `MacDirStat-CI` and runs from
/// `MacDirStat-Performance` in Release configuration with no sanitizers, on the
/// reference machine, before an RC. The bars are algorithmic and memory-based —
/// wall-clock time is reported for context only, never pass/fail (spec §8.2).
/// The suite lands with ticket 10.
final class MacDirStatPerformanceScaffoldTests: XCTestCase {
    func test_performanceTargetRunsInReleaseWithoutSanitizers() {
        // Guards the one property of this target that ticket 02 can assert: it
        // is built Release, because a Debug build would invalidate every
        // measurement taken here.
        #if DEBUG
        XCTFail("MacDirStat-Performance must run in Release configuration (spec §9.1).")
        #endif
    }
}
