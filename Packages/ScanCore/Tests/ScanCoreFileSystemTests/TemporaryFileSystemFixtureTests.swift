import Foundation
import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// The fixture harness testing itself (spec §9.2).
///
/// A recursive delete is the one genuinely destructive thing this suite does,
/// so the guard around it gets its own cases — each refusal is tripped on
/// purpose — and the fingerprint gets a positive control, because a comparison
/// that cannot fail proves nothing about the scan that passed it.
final class TemporaryFileSystemFixtureTests: XCTestCase {
    private var fixtures: [TemporaryFileSystemFixture] = []

    private func makeFixture(label: String = "self-test") throws -> TemporaryFileSystemFixture {
        let fixture = try TemporaryFileSystemFixture(label: label)
        fixtures.append(fixture)
        return fixture
    }

    override func tearDownWithError() throws {
        for fixture in fixtures {
            try? fixture.cleanUp()
        }
        fixtures = []
        try super.tearDownWithError()
    }

    private func mode(of url: URL) throws -> UInt16 {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw FixtureError.couldNotStage(path: url.path, errno: errno)
        }
        return UInt16(status.st_mode & 0o7777)
    }

    // MARK: - Ownership

    func test_aFixtureOwnsAFreshMarkedChildOfTheTemporaryDirectory() throws {
        let fixture = try makeFixture()

        XCTAssertTrue(fixture.directory.path.hasPrefix(
            TemporaryFileSystemFixture.temporaryDirectory.path + "/"
        ))
        XCTAssertTrue(fixture.directory.lastPathComponent.hasPrefix(TemporaryFileSystemFixture.namePrefix))

        let sentinel = fixture.directory.appendingPathComponent(TemporaryFileSystemFixture.sentinelName)
        let token = try String(data: Data(contentsOf: sentinel), encoding: .utf8)
        XCTAssertEqual(token?.isEmpty, false)

        // Fresh: nothing but the sentinel.
        let contents = try FileManager.default.contentsOfDirectory(
            at: fixture.directory, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(contents.map(\.lastPathComponent), [TemporaryFileSystemFixture.sentinelName])
    }

    func test_twoFixturesDoNotShareADirectory() throws {
        XCTAssertNotEqual(try makeFixture().directory, try makeFixture().directory)
    }

    func test_cleanUpRemovesTheOwnedDirectory() throws {
        let fixture = try makeFixture()
        let directory = fixture.directory
        _ = try RealFilesystemFixture.build(in: fixture)

        try fixture.cleanUp()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - What cleanup refuses

    private func assertRefuses(
        _ url: URL,
        token: String,
        because expected: FixtureError.Refusal,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try TemporaryFileSystemFixture.removeOwnedDirectory(at: url, sentinelToken: token),
            file: file, line: line
        ) { error in
            guard case .refusedToDelete(_, let because)? = error as? FixtureError else {
                return XCTFail("not a refusal: \(error)", file: file, line: line)
            }
            XCTAssertEqual(because, expected, file: file, line: line)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "a refused path must still be there", file: file, line: line)
    }

    func test_cleanUpRefusesTheTemporaryDirectoryItself() {
        assertRefuses(TemporaryFileSystemFixture.temporaryDirectory,
                      token: "any", because: .isTheTemporaryDirectoryItself)
    }

    func test_cleanUpRefusesADirectoryOutsideTheTemporaryDirectory() {
        // The user's home directory — named, never created or touched.
        assertRefuses(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                      token: "any", because: .notInsideTheTemporaryDirectory)
    }

    func test_cleanUpRefusesADirectoryThatIsNotNamedLikeAFixture() throws {
        let stranger = TemporaryFileSystemFixture.temporaryDirectory
            .appendingPathComponent("not-a-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stranger) }

        assertRefuses(stranger, token: "any", because: .notNamedLikeAFixture)
    }

    func test_cleanUpRefusesAFixtureNamedDirectoryWithNoSentinel() throws {
        let impostor = TemporaryFileSystemFixture.temporaryDirectory
            .appendingPathComponent(TemporaryFileSystemFixture.namePrefix + UUID().uuidString,
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: impostor, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: impostor) }

        assertRefuses(impostor, token: "any", because: .sentinelMissing)
    }

    func test_cleanUpRefusesAnotherFixturesDirectory() throws {
        let mine = try makeFixture(label: "mine")
        let theirs = try makeFixture(label: "theirs")
        let myToken = try XCTUnwrap(String(
            data: Data(contentsOf: mine.directory.appendingPathComponent(TemporaryFileSystemFixture.sentinelName)),
            encoding: .utf8
        ))

        assertRefuses(theirs.directory, token: myToken, because: .sentinelBelongsToAnotherFixture)
    }

    // MARK: - Permission bits

    func test_permissionBitsAreRestoredAfterAFailedTest() throws {
        let fixture = try makeFixture()
        let manifest = try RealFilesystemFixture.build(in: fixture)
        XCTAssertEqual(try mode(of: manifest.lockedDirectory), 0o000)

        // Whatever the test did or did not do, teardown restores.
        fixture.restorePermissions()

        XCTAssertEqual(try mode(of: manifest.lockedDirectory), 0o755)
        XCTAssertNoThrow(try FileManager.default.contentsOfDirectory(
            at: manifest.lockedDirectory, includingPropertiesForKeys: nil
        ))
    }

    func test_cleanUpRestoresPermissionsBeforeRemoving() throws {
        let fixture = try makeFixture()
        _ = try RealFilesystemFixture.build(in: fixture)
        let directory = fixture.directory

        // A mode-000 directory with contents cannot be removed as it stands, so
        // this succeeding *is* the proof that restoration happened first.
        try fixture.cleanUp()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - The fingerprint has teeth

    func test_theFingerprintNoticesEveryKindOfChange() throws {
        let fixture = try makeFixture()
        let manifest = try RealFilesystemFixture.build(in: fixture)
        let before = try fixture.fingerprint()

        // A byte changed without the length changing.
        let equalA = manifest.scanRoot.appendingPathComponent("equal-a.bin")
        var bytes = try Data(contentsOf: equalA)
        bytes[0] = bytes[0] &+ 1
        try bytes.write(to: equalA)
        // Something appeared.
        try Data([0]).write(to: manifest.scanRoot.appendingPathComponent("appeared.bin"))
        // Something disappeared.
        try FileManager.default.removeItem(at: manifest.scanRoot.appendingPathComponent("empty.bin"))
        // A mode changed.
        XCTAssertEqual(chmod(manifest.scanRoot.appendingPathComponent("legacy.alias").path, 0o600), 0)

        let differences = try fixture.fingerprint().differences(from: before)

        XCTAssertTrue(differences.contains { $0.hasPrefix("appeared:") && $0.contains("appeared.bin") })
        XCTAssertTrue(differences.contains { $0.hasPrefix("disappeared:") && $0.contains("empty.bin") })
        XCTAssertTrue(differences.contains { $0.hasPrefix("changed:") && $0.contains("equal-a.bin") })
        XCTAssertTrue(differences.contains { $0.hasPrefix("changed:") && $0.contains("legacy.alias") })
        // And the containing directory, whose own modification time moved when
        // its contents did — which is why a scan that wrote *anything* could
        // not hide behind an unchanged file list.
        XCTAssertTrue(differences.contains {
            $0.hasPrefix("changed:") && $0.contains("\(manifest.scanRoot.lastPathComponent) [directory]")
        })
        XCTAssertEqual(differences.count, 5, differences.joined(separator: "\n"))
    }

    func test_theFingerprintRecordsSymlinkTargetsWithoutFollowingThem() throws {
        let fixture = try makeFixture()
        let manifest = try RealFilesystemFixture.build(in: fixture)
        let root = manifest.scanRoot.lastPathComponent

        let entries = Dictionary(uniqueKeysWithValues:
            try fixture.fingerprint().entries.map { ($0.relativePath, $0) })

        let loop = try XCTUnwrap(entries["\(root)/loop-link"])
        XCTAssertEqual(loop.kind, .symbolicLink)
        XCTAssertEqual(loop.symlinkTarget, manifest.scanRoot.path)
        XCTAssertNil(loop.contentHash, "a link's contents are never read")
        // Following it would have produced paths beneath it.
        XCTAssertFalse(entries.keys.contains { $0.contains("loop-link/") })
    }

    func test_theFingerprintCoversAnUnreadableDirectoryAndLeavesItLocked() throws {
        let fixture = try makeFixture()
        let manifest = try RealFilesystemFixture.build(in: fixture)
        let root = manifest.scanRoot.lastPathComponent

        let entries = Dictionary(uniqueKeysWithValues:
            try fixture.fingerprint().entries.map { ($0.relativePath, $0) })

        // Its recorded mode is the one the filesystem reported, before the
        // fingerprint opened it to look inside…
        XCTAssertEqual(entries["\(root)/locked"]?.mode, 0o000)
        // …the file within it is covered, so a scan that changed it would show…
        XCTAssertEqual(entries["\(root)/locked/unreachable.bin"]?.logicalLength,
                       RealFixtureManifest.unreadableInsideBytes)
        // …and it is locked again afterwards, so the case still stands.
        XCTAssertEqual(try mode(of: manifest.lockedDirectory), 0o000)
    }

    func test_theFingerprintSkipsTheContentsOfLargeSparseFiles() throws {
        let fixture = try makeFixture()
        let manifest = try RealFilesystemFixture.build(in: fixture)
        let root = manifest.scanRoot.lastPathComponent

        let entries = Dictionary(uniqueKeysWithValues:
            try fixture.fingerprint().entries.map { ($0.relativePath, $0) })

        let hidden = try XCTUnwrap(entries["\(root)/.hidden.bin"])
        XCTAssertEqual(hidden.logicalLength, RealFixtureManifest.hiddenSparseBytes)
        XCTAssertNil(hidden.contentHash, "3 GiB is never read to fingerprint it")
        XCTAssertNotNil(entries["\(root)/equal-a.bin"]?.contentHash)
    }
}
