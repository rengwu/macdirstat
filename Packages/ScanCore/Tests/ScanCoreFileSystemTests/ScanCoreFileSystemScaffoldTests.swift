import XCTest
@testable import ScanCore

/// Placeholder for the production-probe suite (spec §9.1): the real
/// `FileManager` probe run against a small temporary tree.
///
/// The suite is read-only by construction (spec §9.2). Every case here must
/// stage a fresh, uniquely owned child of the test temp directory and must
/// never touch an existing user directory. `TemporaryFileSystemFixture` — the
/// sentinel-owned, fingerprint-before-and-after adapter — lands with ticket 05.
final class ScanCoreFileSystemScaffoldTests: XCTestCase {
    func test_temporaryDirectoryIsWritableForFixtureStaging() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ScanCoreFileSystemScaffold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }
}
