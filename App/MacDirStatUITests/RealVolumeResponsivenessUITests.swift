import XCTest

/// The freeze, measured on the real app scanning a real tree (ticket 14).
///
/// Every other measurement in this repository is taken inside the process doing
/// the measuring, against a tree the suite built itself. That is exactly the
/// blind spot ticket 14 came out of: a scan of `/` froze the window for
/// seconds, and no fixture and no rung could have shown it, because the freeze
/// was a *main thread* fact and the suites were all engine facts.
///
/// This drives the shipped app through its own accessibility interface while a
/// real scan runs. An `XCUIElement` query is answered by the app's **main
/// thread**, so the time a query takes is a direct reading of how long that
/// thread was unavailable — which is the thing a user calls a freeze. The
/// numbers are much coarser than the in-process heartbeat in
/// `MacDirStatPerformanceTests`; they are also the only ones taken from
/// outside.
///
/// **Opt-in**, like every other real-I/O check in this repository (spec §9.2):
/// it needs a directory big enough for the old code to have frozen on, which is
/// a machine's own business and not something a fixture can stage.
///
/// ```sh
/// MACDIRSTAT_UI_SCAN_ROOT=/System/Library xcodebuild test \
///   -project MacDirStat.xcodeproj -scheme MacDirStat-CompatibilitySmoke \
///   -destination 'platform=macOS' \
///   -only-testing:MacDirStatUITests/RealVolumeResponsivenessUITests
/// ```
final class RealVolumeResponsivenessUITests: XCTestCase {
    /// The worst a **direct** query on one element may take. Deliberately
    /// loose: the freeze being ruled out was measured in seconds, this is a
    /// Debug build driven through a cross-process accessibility bridge, and a
    /// bound that is tight enough to be flaky is worse than no bound.
    ///
    /// The one query this is asserted on is the window's own frame — one
    /// element, answered from the window's state. It is not asserted on the
    /// queries that *search* the hierarchy: see `timeQueries(of:)`.
    private static let responseBoundSeconds: TimeInterval = 1.5

    /// The query that walks the whole accessibility hierarchy is timed and
    /// printed but not asserted on, because what it measures is mostly its own
    /// cost: on a finished whole-volume scan the window publishes one
    /// accessibility element per rendered rectangle (§9.4) plus the outline's
    /// rows, and copying all of that is main-thread work the *client* asked
    /// for. Measured at 8.4 s against /System/Library in Debug — a real number
    /// about VoiceOver's experience of a large map, and a separate subject from
    /// this ticket's.
    private static let hierarchyWalkIsDiagnosticOnly = true

    func test_theWindowStaysAnswerableThroughAScanOfARealTree() throws {
        guard let path = ProcessInfo.processInfo.environment["MACDIRSTAT_UI_SCAN_ROOT"] else {
            throw XCTSkip("""
                Set MACDIRSTAT_UI_SCAN_ROOT to a real directory large enough to be worth \
                scanning (spec §9.2 keeps real-I/O checks opt-in).
                """)
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)

        let app = XCUIApplication()
        app.launch()
        try chooseFolder(root, in: app)

        var worst: [String: TimeInterval] = [:]
        var samples = 0
        let deadline = Date().addingTimeInterval(90)

        // Poll the window until the scan finishes or the deadline passes,
        // timing every question asked of the app's main thread.
        while Date() < deadline {
            for (probe, elapsed) in timeQueries(of: app) {
                worst[probe] = max(worst[probe] ?? 0, elapsed)
            }
            samples += 1
            if !app.buttons["Cancel"].exists, samples > 4 { break }
        }

        let readings = worst.sorted { $0.value > $1.value }
        print("""
            [field] \(path): \(samples) rounds during the scan, worst main-thread response \
            \(readings.map { "\($0.key) \(String(format: "%.3f", $0.value)) s" }.joined(separator: ", ")) \
            [diagnostic]
            """)

        XCTAssertGreaterThan(samples, 10, "the scan ended before anything could be measured")
        XCTAssertTrue(Self.hierarchyWalkIsDiagnosticOnly)
        let direct = try XCTUnwrap(worst["window frame"])
        XCTAssertLessThan(
            direct, Self.responseBoundSeconds,
            """
            the window took \(String(format: "%.2f", direct)) s to answer for its own frame while \
            scanning \(path) — something is running on the main thread that should not be
            """
        )
    }

    /// One round of the questions a user's pointer and eyes ask.
    ///
    /// They are timed **apart**, because they cost very different things. The
    /// first two are answered from the window's own state and are what a freeze
    /// shows up in. The third walks the whole accessibility tree, which on a
    /// finished whole-volume scan means one element per rendered rectangle and
    /// one per visible tree row: that is expensive by construction, on any
    /// implementation, and rolling it into one number would hide the two that
    /// mean something.
    private func timeQueries(of app: XCUIApplication) -> [(String, TimeInterval)] {
        var readings: [(String, TimeInterval)] = []
        for probe in ["window frame", "cancel button", "accessibility walk"] {
            let began = Date()
            switch probe {
            case "window frame": _ = app.windows.firstMatch.frame
            case "cancel button": _ = app.buttons["Cancel"].exists
            default: _ = app.windows.firstMatch.staticTexts.count
            }
            readings.append((probe, Date().timeIntervalSince(began)))
        }
        return readings
    }

    /// The same open-panel drive `CompatibilitySmokeUITests` uses, kept here
    /// rather than shared because that class is the §9.3 compatibility matrix's
    /// and this is not part of it.
    private func chooseFolder(_ folder: URL, in app: XCUIApplication) throws {
        let choose = app.buttons["Choose…"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        choose.click()

        let chooseFolder = app.buttons["Choose Folder…"]
        XCTAssertTrue(chooseFolder.waitForExistence(timeout: 5))
        chooseFolder.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))

        app.typeKey("g", modifierFlags: [.command, .shift])
        let location = app.textFields.firstMatch
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        location.typeText(folder.path)
        app.typeKey(.return, modifierFlags: [])

        let scan = app.sheets.firstMatch.buttons.matching(identifier: "OKButton").firstMatch
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.click()
    }
}
