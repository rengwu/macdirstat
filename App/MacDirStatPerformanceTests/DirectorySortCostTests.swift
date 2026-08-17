import Foundation
import ScanCore
import XCTest

/// What the within-directory sort actually costs (ticket 15).
///
/// A `sample(1)` taken on the scan thread during a whole-volume run showed
/// `_StringGutsSlice._slowCompare` → `Unicode._NFDNormalizer._resume`, which
/// proves those frames are *hot*, not that they own any share of the run. This
/// suite answers the second question two ways:
///
/// - **The comparator alone**, over name mixes chosen so the fast and slow paths
///   of Swift's canonical `String <` are each exercised on their own. Runs
///   always; it needs no disk.
/// - **The share of a real scan**, through the production probe on a real
///   directory-heavy tree, with `list` and the sort timed separately. Opt-in,
///   because it wants a tree the harness did not build — a generated fixture has
///   uniform ASCII names and would answer a question nobody asked.
///
/// **Nothing here asserts on wall-clock.** The spec commits algorithmic and
/// memory bars only and explicitly refuses a throughput SLA (§8.2), so these
/// print and the numbers are transcribed into
/// `.plan/maps/macos-disk-visualizer-impl/records/sort-cost.md`. What *is*
/// asserted is the property the choice of comparator was made for: the order is
/// total, and on ASCII names it is the same order as before.
final class DirectorySortCostTests: XCTestCase {
    /// What the scanner used before ticket 15: Unicode canonical equivalence.
    private static func canonical(_ a: String, _ b: String) -> Bool { a < b }

    /// What it uses now — the same comparison `ScanCore.NameOrder` makes.
    private static func codePoint(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }

    // MARK: - The comparator on its own

    func test_theComparatorsAreTimedOverTheNameMixesARealVolumeHolds() {
        for mix in NameMix.all {
            let canonical = Self.bestSortSeconds(mix.listings, by: Self.canonical)
            let codePoint = Self.bestSortSeconds(mix.listings, by: Self.codePoint)
            print(String(
                format: "[performance] sort comparator %@: canonical %.4f s, code-point %.4f s (%.2fx), %d names in %d directories [diagnostic]",
                mix.name, canonical, codePoint, canonical / codePoint, mix.nameCount, mix.listings.count
            ))
        }
    }

    /// The ASCII mixes are the overwhelming majority of a real volume's names,
    /// and there the change is not a change: both comparators produce the same
    /// array. Where a name is not ASCII the orders may differ, which is the
    /// behaviour `NameOrderTests` pins down name by name.
    func test_bothComparatorsAgreeWhereverEveryNameIsASCII() {
        for mix in NameMix.all where mix.isASCII {
            for listing in mix.listings {
                XCTAssertEqual(
                    listing.sorted(by: Self.canonical),
                    listing.sorted(by: Self.codePoint),
                    "\(mix.name) sorted differently under the two comparators"
                )
            }
        }
    }

    // MARK: - The share of a real scan

    /// Point `MACDIRSTAT_SORT_COST_TREE` — `TEST_RUNNER_MACDIRSTAT_SORT_COST_TREE`
    /// when running through `xcodebuild` — at a directory-heavy tree. The record
    /// was taken on `/System/Library` (447,367 entries in 156,701 directories,
    /// read-only, present on every Mac) and on a `node_modules`-heavy projects
    /// folder.
    ///
    /// The measurement is a decorator over the production probe: it times the
    /// underlying `list`, then sorts a private copy of the same entries with the
    /// comparator under test and times that. The copy is made outside the timer,
    /// and one comparator is measured per scan — timing several inside one
    /// listing charges the first for every cache miss the others then avoid,
    /// which is exactly the mistake that made an early run of this rank the two
    /// comparators backwards.
    func test_theSortShareOfARealDirectoryHeavyScanIsMeasured() async throws {
        let root = try XCTSkipIfUnset()

        // The first scan warms the metadata cache; a cold cache would put the
        // whole measurement in `list` and answer nothing.
        _ = await Self.scan(root, probe: FileManagerDirectoryProbe())
        let plain = await Self.scan(root, probe: FileManagerDirectoryProbe())
        print(String(format: "[performance] sort share, plain scan of %@: %.2f s [diagnostic]",
                     root.path, plain.seconds))

        for (name, comparator) in [
            ("canonical(String <)", Self.canonical), ("code-point", Self.codePoint)
        ] {
            let probe = SortTimingProbe(comparator: comparator)
            let run = await Self.scan(root, probe: probe)
            // The scan's own wall clock, less the sorts this probe added to it.
            let scanSeconds = run.seconds - probe.sortSeconds
            print(String(
                format: """
                    [performance] sort share, %@: sort %.3f s = %.2f%% of a %.2f s scan; \
                    list %.2f s = %.1f%%; %d entries in %d directories, %d non-ASCII names [diagnostic]
                    """,
                name, probe.sortSeconds, 100 * probe.sortSeconds / scanSeconds, scanSeconds,
                probe.listSeconds, 100 * probe.listSeconds / scanSeconds,
                probe.entries, probe.listings, probe.nonASCIINames
            ))
            let measured = try XCTUnwrap(run.result, "the instrumented scan failed pre-flight")
            if measured.root.subtreeBytes != plain.result?.root.subtreeBytes {
                // Not a failure: a tree somebody is using changes under a scan,
                // and the share this test reports is unaffected by that. It is
                // worth saying out loud, because it explains a wobble between
                // two passes that would otherwise look like measurement noise.
                print("[performance] sort share: the tree changed between passes [diagnostic]")
            }
        }
    }

    // MARK: - Helpers

    private static func bestSortSeconds(
        _ listings: [[String]],
        by comparator: @escaping (String, String) -> Bool
    ) -> Double {
        var best = Double.infinity
        for _ in 0..<7 {
            var copies = listings
            let began = Date()
            for index in copies.indices { copies[index].sort(by: comparator) }
            best = min(best, Date().timeIntervalSince(began))
            XCTAssertFalse(copies.isEmpty)
        }
        return best
    }

    private static func scan(
        _ root: URL, probe: DirectoryProbe
    ) async -> (result: ScanResult?, seconds: Double) {
        let scanner = Scanner()
        let began = Date()
        var result: ScanResult?
        for await event in await scanner.scan(ScanRequest(
            root: root,
            mode: .folder,
            probe: probe,
            options: ScanOptions(progressCadence: .terminalOnly, treeCadence: .terminalOnly)
        )) {
            if case .finished(let finished) = event { result = finished }
        }
        return (result, Date().timeIntervalSince(began))
    }

    private func XCTSkipIfUnset() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["MACDIRSTAT_SORT_COST_TREE"] else {
            throw XCTSkip("""
                The sort-share measurement reads a real tree the harness did not build. \
                Set MACDIRSTAT_SORT_COST_TREE to one — /System/Library is the tree the \
                record was taken on, and nothing here writes anything. Through xcodebuild \
                the variable needs the runner prefix: \
                TEST_RUNNER_MACDIRSTAT_SORT_COST_TREE=/System/Library.
                """)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw XCTSkip("MACDIRSTAT_SORT_COST_TREE is not a directory: \(path)") }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

// MARK: - Name mixes

/// Synthetic listings whose name mix is chosen, not harvested: each one isolates
/// one path through Swift's canonical comparison. Fourteen names per directory
/// is the mean directory size measured on a `node_modules`-heavy tree; ASCII
/// under and over the fifteen-byte small-string boundary are separate mixes,
/// because that boundary is where `String <` stops comparing raw bits.
struct NameMix {
    let name: String
    let listings: [[String]]
    let isASCII: Bool

    var nameCount: Int { listings.reduce(0) { $0 + $1.count } }

    static let all: [NameMix] = [
        NameMix(name: "short ASCII", isASCII: true) { directory, entry in
            "f\(scramble(directory, entry)).js"
        },
        NameMix(name: "long ASCII", isASCII: true) { directory, entry in
            "react-dom-server-legacy.browser.development-\(scramble(directory, entry)).js"
        },
        NameMix(name: "precomposed", isASCII: false) { directory, entry in
            "\(accented[scramble(directory, entry) % accented.count])-\(scramble(directory, entry)).txt"
        },
        NameMix(name: "decomposed", isASCII: false) { directory, entry in
            "\(accented[scramble(directory, entry) % accented.count])-\(scramble(directory, entry)).txt"
                .decomposedStringWithCanonicalMapping
        },
        NameMix(name: "CJK", isASCII: false) { directory, entry in
            "文書-\(scramble(directory, entry))-资料.pdf"
        }
    ]

    private static let accented = ["café", "naïve", "über", "Ångström", "résumé", "piñata", "façade"]

    /// A fixed pseudo-random spread, so every mix sorts the same permutation on
    /// every machine and two records are comparable.
    private static func scramble(_ directory: Int, _ entry: Int) -> Int {
        (entry &* 7_919 &+ directory &* 104_729) % 100_000
    }

    private init(
        name: String,
        directories: Int = 4_000,
        perDirectory: Int = 14,
        isASCII: Bool,
        makeName: (Int, Int) -> String
    ) {
        self.name = name
        self.isASCII = isASCII
        self.listings = (0..<directories).map { directory in
            (0..<perDirectory).map { entry in makeName(directory, entry) }
        }
    }
}

// MARK: - The timing probe

/// The production probe, with a stopwatch on each half of what a scan does per
/// directory: the listing, and the sort that follows it.
final class SortTimingProbe: DirectoryProbe, @unchecked Sendable {
    private let inner = FileManagerDirectoryProbe()
    private let comparator: (String, String) -> Bool
    private let lock = NSLock()

    private var listSecondsStorage: Double = 0
    private var sortSecondsStorage: Double = 0
    private var listingsStorage = 0
    private var entriesStorage = 0
    private var nonASCIIStorage = 0

    init(comparator: @escaping (String, String) -> Bool) {
        self.comparator = comparator
    }

    var listSeconds: Double { locked { listSecondsStorage } }
    var sortSeconds: Double { locked { sortSecondsStorage } }
    var listings: Int { locked { listingsStorage } }
    var entries: Int { locked { entriesStorage } }
    var nonASCIINames: Int { locked { nonASCIIStorage } }

    func list(_ url: URL) throws -> [EntryMeta] {
        let listBegan = Date()
        let entries = try inner.list(url)
        let listed = Date().timeIntervalSince(listBegan)

        // A genuine copy, made before the stopwatch starts, so what is timed is
        // the sort and not the copy-on-write duplication it would trigger.
        var copy = [EntryMeta]()
        copy.reserveCapacity(entries.count)
        copy.append(contentsOf: entries)
        let sortBegan = Date()
        copy.sort { comparator($0.name, $1.name) }
        let sorted = Date().timeIntervalSince(sortBegan)

        var nonASCII = 0
        for entry in entries where !entry.name.allSatisfy(\.isASCII) { nonASCII += 1 }

        lock.lock()
        listSecondsStorage += listed
        sortSecondsStorage += sorted
        listingsStorage += 1
        entriesStorage += entries.count
        nonASCIIStorage += nonASCII
        if copy.count != entries.count { preconditionFailure("the timed copy lost entries") }
        lock.unlock()
        return entries
    }

    func metadata(of url: URL) throws -> EntryMeta { try inner.metadata(of: url) }
    func volumeInfo(for url: URL) throws -> VolumeInfo { try inner.volumeInfo(for: url) }
    func mountPointPaths() -> Set<String> { inner.mountPointPaths() }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
