import Foundation
import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// Security-scoped access is claimed once at the start of a scan of a real
/// directory and released **exactly once** on every terminal path — success,
/// failure, cancellation, and replacement by a new scan (spec §5.6, §9.2, §10).
///
/// The spy is the proof: a claim released twice is as much a bug as one never
/// released, and neither is visible from the outside any other way.
final class SecurityScopeBalanceTests: RealFixtureTestCase {
    func test_aSuccessfulScanReleasesItsClaimExactlyOnce() async throws {
        let spy = SpySecurityScopedAccess()

        let events = await runProductionScan(root: scanRoot, access: spy)

        XCTAssertEqual(events.result?.reason, .completed)
        XCTAssertEqual(spy.startCount, 1)
        XCTAssertEqual(spy.stopCount, 1)
    }

    func test_aScanThatFailsPreFlightReleasesItsClaimExactlyOnce() async throws {
        let spy = SpySecurityScopedAccess()
        let missing = scanRoot.appendingPathComponent("nothing-here", isDirectory: true)

        let events = await runProductionScan(root: missing, access: spy)

        XCTAssertEqual(events.failure, .rootMissing(missing))
        XCTAssertEqual(spy.startCount, 1)
        XCTAssertEqual(spy.stopCount, 1)
    }

    func test_aScanOfARootThatIsNotADirectoryAlsoReleasesExactlyOnce() async throws {
        let spy = SpySecurityScopedAccess()
        let file = scanRoot.appendingPathComponent("a-owner.bin")

        let events = await runProductionScan(root: file, access: spy)

        XCTAssertEqual(events.failure, .rootNotDirectory(file))
        XCTAssertEqual(spy.startCount, 1)
        XCTAssertEqual(spy.stopCount, 1)
    }

    func test_aCancelledScanReleasesItsClaimExactlyOnce() async throws {
        let spy = SpySecurityScopedAccess()
        let scanner = Scanner()
        // Cancel from inside the traversal, once it is provably part-way
        // through a real tree. The fourth listing rather than the second: the
        // first entry this fixture attributes is `.hidden.bin`, which is three
        // gigabytes of content length occupying **no blocks at all**, so a scan
        // stopped before `Fixture.app/Contents/Info.plist` has a real tree and
        // a legitimately zero total (ticket 13).
        let probe = InterceptingProbe { _, index in
            if index == 4 { scanner.cancel() }
        }

        let stream = await scanner.scan(
            makeProductionRequest(root: scanRoot, probe: probe, access: spy)
        )
        let events = await collectEvents(stream)

        let result = try XCTUnwrap(events.result)
        XCTAssertEqual(result.reason, .cancelled)
        XCTAssertGreaterThan(result.root.subtreeDiskBytes, 0, "everything already discovered is kept")
        XCTAssertEqual(spy.startCount, 1)
        XCTAssertEqual(spy.stopCount, 1, "the cancellation handler and the exit path must not both release")
    }

    /// The replacement case: a second scan cancels the first and starts only
    /// once the first has reached its terminal event. Both claims must balance.
    func test_replacingARunningScanReleasesBothClaimsExactlyOnce() async throws {
        let firstAccess = SpySecurityScopedAccess()
        let secondAccess = SpySecurityScopedAccess()
        let scanner = Scanner()

        // The first scan parks inside its very first listing, so the second
        // scan provably arrives while it is still running.
        let reachedFirstListing = TestFlag()
        let mayContinue = DispatchSemaphore(value: 0)
        let blocking = InterceptingProbe { _, index in
            if index == 1 {
                reachedFirstListing.raise()
                _ = mayContinue.wait(timeout: .now() + 10)
            }
        }

        let firstStream = await scanner.scan(
            makeProductionRequest(root: scanRoot, probe: blocking, access: firstAccess)
        )
        let firstEvents = Task { await collectEvents(firstStream) }
        await waitForFlag(reachedFirstListing)

        let secondStream = await scanner.scan(
            makeProductionRequest(root: scanRoot, access: secondAccess)
        )
        mayContinue.signal()

        let second = await collectEvents(secondStream)
        let first = await firstEvents.value

        XCTAssertEqual(first.result?.reason, .cancelled, "the replaced scan still delivers its partial result")
        XCTAssertEqual(second.result?.reason, .completed)
        XCTAssertEqual(second.result?.root.subtreeDiskBytes, manifest.expectedAttributedDiskBytes,
                       "the replacement ran to completion after the replaced scan ended")

        XCTAssertEqual(firstAccess.startCount, 1)
        XCTAssertEqual(firstAccess.stopCount, 1)
        XCTAssertEqual(secondAccess.startCount, 1)
        XCTAssertEqual(secondAccess.stopCount, 1)
    }

    /// A local URL carries no security scope, so `startAccessingSecurityScopedResource`
    /// reports `false` and **no stop is owed** — the reason a refused scope is
    /// not an eligibility verdict (ticket 03). The scan runs regardless.
    func test_aRootThatCarriesNoScopeIsScannedAndOwesNoStop() async throws {
        let spy = SpySecurityScopedAccess(startSucceeds: false)

        let events = await runProductionScan(root: scanRoot, access: spy)

        XCTAssertEqual(events.result?.reason, .completed)
        XCTAssertEqual(events.result?.root.subtreeDiskBytes, manifest.expectedAttributedDiskBytes)
        XCTAssertEqual(spy.startCount, 1)
        XCTAssertEqual(spy.stopCount, 0)
    }

    /// And the production adapter's verdict is **not** an eligibility verdict —
    /// which is the point, because what it reports for an ordinary local
    /// directory depends on the process.
    ///
    /// Ticket 03 recorded `false` here (an unsandboxed observation of a URL
    /// carrying no scope); on this host, unsandboxed, every ordinary local URL
    /// answers `true` instead. The conclusion is the same either way, and now
    /// rests on the disagreement rather than on one of the two answers: a scan
    /// of a perfectly readable root must succeed whichever it is, and an
    /// unreadable root must fail through the probe, not through this call.
    func test_theSystemAdaptersVerdictIsNotAnEligibilityVerdict() async throws {
        let events = await runProductionScan(root: scanRoot, access: SystemSecurityScopedAccess())

        XCTAssertEqual(events.result?.reason, .completed)
        XCTAssertEqual(events.result?.root.subtreeDiskBytes, manifest.expectedAttributedDiskBytes)

        // Whatever it answers, a matching stop is safe and the pairing holds.
        let access = SystemSecurityScopedAccess()
        if access.startAccessing(scanRoot) {
            access.stopAccessing(scanRoot)
        }
    }
}
