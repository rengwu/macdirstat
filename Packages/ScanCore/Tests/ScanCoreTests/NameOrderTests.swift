import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// The within-directory order (spec §3.4, §6.1, ticket 03): locale-independent,
/// identical on every machine, and a **total** order — because it is what
/// decides which of several names for one inode owns its bytes.
///
/// The comparison is code-point order over Unicode scalars, not Swift's
/// `String <`. `String <` orders by canonical equivalence, which is
/// locale-independent and stable but leaves two spellings of one name *tied*,
/// and a tie is broken by the order the filesystem happened to list them in.
/// These tests hold that distinction in place from both ends: the comparator's
/// own algebra, and the owner a scan actually picks.
final class NameOrderTests: XCTestCase {
    private let volumeA = FileSystemIdentity("volume-A")
    private let inode7 = FileSystemIdentity("inode-7")

    /// Two spellings of one name, both of which a normalization-sensitive
    /// volume (a case-sensitive APFS volume, an exFAT stick) keeps as separate
    /// entries in one directory.
    private let precomposed = "caf\u{00E9}.bin"      // …fé
    private let decomposed = "cafe\u{0301}.bin"      // …fe + combining acute

    // MARK: - The comparator

    /// The names on a real volume are overwhelmingly ASCII, and there the two
    /// orders are the same order. Nothing about the change moves them.
    func test_codePointOrderAgreesWithStringComparisonOnASCIINames() {
        let names = [
            "Applications", "System", "Users", "bin", "etc", "usr", "var",
            ".DS_Store", ".git", ".nofollow", "node_modules", "README.md",
            "index.js", "index.test.js", "Info.plist", "z", "Z", "0", "9", "~snapshot"
        ]
        for a in names {
            for b in names {
                XCTAssertEqual(NameOrder.precedes(a, b), a < b, "\(a) vs \(b)")
            }
        }
    }

    /// The reason for the change, stated as an assertion: `String <` cannot
    /// separate these two names, and the comparator we use can.
    func test_twoSpellingsOfOneNameAreTiedUnderStringComparisonAndOrderedUnderThisOne() {
        XCTAssertFalse(precomposed < decomposed, "canonical equivalence: neither precedes")
        XCTAssertFalse(decomposed < precomposed, "canonical equivalence: neither precedes")
        XCTAssertTrue(precomposed == decomposed, "String equality is canonical equivalence too")

        XCTAssertTrue(NameOrder.precedes(decomposed, precomposed),
                      "U+0065 precedes U+00E9, so the decomposed spelling sorts first")
        XCTAssertFalse(NameOrder.precedes(precomposed, decomposed))
    }

    /// Where the two orders differ on names that are *not* canonically
    /// equivalent — recorded because it is the whole of the behavioural
    /// difference, not because anything depends on this pair.
    func test_theTwoOrdersDivergeWhereComposingWouldChangeTheFirstScalar() {
        let composing = "e\u{0301}clair"   // composes to "éclair"
        let plain = "f"

        XCTAssertTrue(NameOrder.precedes(composing, plain), "U+0065 < U+0066")
        XCTAssertFalse(composing < plain, "composed, U+00E9 > U+0066")
    }

    /// Irreflexive, asymmetric, transitive, and never equal for distinct names:
    /// the four properties a sort may rely on and an owner rule needs.
    func test_theOrderIsTotalOverACorpusThatIncludesEveryAwkwardCase() {
        let corpus = [
            "a", "A", "b", "z", "Z", "0", "_", ".hidden", "café", precomposed, decomposed,
            "cafe", "文書", "документ", "🍎", "🍏", "e\u{0301}clair", "éclair", "", " "
        ]

        for a in corpus {
            XCTAssertFalse(NameOrder.precedes(a, a), "irreflexive: \(a)")
            for b in corpus {
                if NameOrder.precedes(a, b) {
                    XCTAssertFalse(NameOrder.precedes(b, a), "asymmetric: \(a) vs \(b)")
                }
                let distinct = !a.unicodeScalars.elementsEqual(b.unicodeScalars)
                if distinct {
                    XCTAssertTrue(NameOrder.precedes(a, b) || NameOrder.precedes(b, a),
                                  "distinct names are never tied: \(a) vs \(b)")
                }
                for c in corpus where NameOrder.precedes(a, b) && NameOrder.precedes(b, c) {
                    XCTAssertTrue(NameOrder.precedes(a, c), "transitive: \(a) < \(b) < \(c)")
                }
            }
        }
    }

    // MARK: - What the scan does with it

    /// The tree shows both names, in code-point order, whichever order the
    /// filesystem listed them in.
    func test_theScannerOrdersTwoSpellingsOfOneNameByCodePoint() async {
        for reversed in [false, true] {
            var children: [ScriptedEntry] = [
                .file(precomposed, bytes: 10, volume: volumeA),
                .file(decomposed, bytes: 20, volume: volumeA)
            ]
            if reversed { children.reverse() }
            let probe = ScriptedDirectoryProbe(
                rootURL: scanRootURL,
                root: .directory("scan-root", volume: volumeA, children: children)
            )

            guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

            // Compared as bytes, not as `String`: `==` is canonical equivalence
            // too, so an assertion written the obvious way would hold whichever
            // spelling came first and prove nothing.
            XCTAssertEqual(result.root.children.map { Self.spelling($0.name) },
                           [Self.spelling(decomposed), Self.spelling(precomposed)],
                           "listed \(reversed ? "reversed" : "in order")")
            XCTAssertEqual(result.root.subtreeDiskBytes, 30, "two names, two files, both counted")
        }
    }

    /// **The output difference this change makes.** Two names for one inode that
    /// differ only in normalization: the decomposed spelling owns the bytes, and
    /// it owns them no matter which name the filesystem listed first.
    ///
    /// Under `String <` the two names compare equal, so the sort left them in
    /// listing order and the owner followed the filesystem — the one input that
    /// is not the same on two machines holding the same tree.
    func test_hardLinkOwnershipBetweenTwoSpellingsOfOneNameDoesNotFollowListingOrder() async {
        func run(reversed: Bool) async -> (owner: [UInt8]?, duplicate: [UInt8]?, total: Int64) {
            var children: [ScriptedEntry] = [
                .file(precomposed, bytes: 4_096, volume: volumeA, linkCount: 2, identity: inode7),
                .file(decomposed, bytes: 4_096, volume: volumeA, linkCount: 2, identity: inode7)
            ]
            if reversed { children.reverse() }
            let probe = ScriptedDirectoryProbe(
                rootURL: scanRootURL,
                root: .directory("scan-root", volume: volumeA, children: children)
            )
            guard let result = await runScan(probe).result else { return (nil, nil, -1) }
            return (
                owner: result.root.children.first { $0.attribution == .owned }.map { Self.spelling($0.name) },
                duplicate: result.root.children.first { $0.attribution != .owned }.map { Self.spelling($0.name) },
                total: result.root.subtreeDiskBytes
            )
        }

        let asListed = await run(reversed: false)
        let reversed = await run(reversed: true)

        XCTAssertEqual(asListed.owner, Self.spelling(decomposed))
        XCTAssertEqual(asListed.duplicate, Self.spelling(precomposed))
        XCTAssertEqual(asListed.owner, reversed.owner, "the owner does not follow the listing order")
        XCTAssertEqual(asListed.duplicate, reversed.duplicate)
        XCTAssertEqual(asListed.total, 4_096, "one inode's bytes, counted once")
        XCTAssertEqual(asListed.total, reversed.total)
    }

    /// A name as its bytes. `String ==` is canonical equivalence, so it cannot
    /// tell the two spellings apart — an assertion about *which* spelling won
    /// has to leave `String` behind to say anything at all.
    private static func spelling(_ name: String) -> [UInt8] { Array(name.utf8) }
}
