import XCTest
@testable import ScanCore

/// Read-only is structural (spec §10, §9.3): the seam the engine talks to
/// exposes no way to mutate, download, or read file contents, so no
/// implementation of it — production or test — can be asked to.
///
/// This is asserted against the protocol's own source text because Swift has no
/// runtime reflection over protocol requirements. It is a guard against a later
/// session widening the seam by habit, which is exactly when it would happen.
final class ReadOnlySeamTests: XCTestCase {
    private static let bannedInADeclaration = [
        "write", "download", "create", "delete", "remove", "move", "copy",
        "trash", "unlink", "truncate", "replace", "setattribute", "contentsof"
    ]

    private var directoryProbeSource: String {
        get throws {
            let sourceFile = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // ScanCoreTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // ScanCore (package root)
                .appendingPathComponent("Sources/ScanCore/DirectoryProbe.swift")
            return try String(contentsOf: sourceFile, encoding: .utf8)
        }
    }

    func test_theProbeSeamDeclaresNoWriteOrDownloadOrContentsMethod() throws {
        let declarations = try directoryProbeSource
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.isEmpty }
            .joined(separator: "\n")
            .lowercased()

        XCTAssertTrue(declarations.contains("protocol directoryprobe"),
                      "the seam moved; this guard must move with it")

        for banned in Self.bannedInADeclaration {
            XCTAssertFalse(
                declarations.contains(banned),
                "DirectoryProbe declares something matching \"\(banned)\" — the seam must stay listing + metadata only"
            )
        }
    }

    /// The requirements themselves, not the file's `func` lines: the seam ships
    /// a default implementation beside the protocol, and a guard that counted
    /// that too would be asserting something other than the width of the seam.
    func test_theSeamDeclaresExactlyTheFourReadOnlyRequirements() throws {
        let lines = try directoryProbeSource
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(where: { $0.hasPrefix("public protocol DirectoryProbe") }),
              let end = lines[start...].firstIndex(of: "}")
        else { return XCTFail("the seam moved; this guard must move with it") }

        let requirements = lines[start...end].filter { $0.hasPrefix("func ") }

        XCTAssertEqual(requirements, [
            "func list(_ url: URL) throws -> [EntryMeta]",
            "func metadata(of url: URL) throws -> EntryMeta",
            "func volumeInfo(for url: URL) throws -> VolumeInfo",
            // Read once per scan, and only to decide *which* of two paths to a
            // shared subtree keeps it (spec §3.3).
            "func mountPointPaths() -> Set<String>"
        ])
    }

    func test_thePackageStatesItsDeploymentFloor() {
        XCTAssertEqual(ScanCore.minimumSupportedMacOS, "11.0")
    }
}
