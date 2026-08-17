import Foundation

/// The order entries are put in within one directory.
///
/// **Unicode code-point order, compared over scalars.** Two properties are
/// load-bearing and neither is negotiable:
///
/// - **Locale-independent.** A localized comparison is not a deterministic one:
///   two machines with different locales would produce a different node order
///   and, through it, a different hard-link owner (ticket 03).
/// - **A total order over distinct names.** The traversal order decides which
///   of several names for one inode owns its bytes (spec §3.4), so two names
///   that are not the same name must never compare as equal.
///
/// Swift's `String <` has the first property and *not* the second. It orders by
/// Unicode canonical equivalence, so `"cafe\u{0301}"` and `"caf\u{00E9}"` — two
/// names that a case- and normalization-sensitive volume keeps apart — compare
/// as equal, and their order falls through to whatever order the filesystem
/// listed them in. That is the one input a scan cannot reproduce across
/// machines. Comparing scalars gives them a stable order in both directions:
/// the decomposed name precedes the precomposed one, on every machine, because
/// `U+0065` precedes `U+00E9`.
///
/// It is also what the spec already asks for elsewhere: §6.1 fixes the treemap's
/// name tie-break at code-point order, and `TreemapLayout`'s
/// `PreparedTree.precedes` implements it exactly this way. The two packages
/// cannot depend on each other — `ScanCore` is Foundation-only and knows nothing
/// of layout — so the comparison is written twice, deliberately, and each site
/// names the other.
///
/// **Cost — measured, and not the reason.** The sort is 1.5–2.1 % of a real
/// scan's wall clock and listing is 93–95 %, so nothing here was ever the
/// bottleneck a `sample(1)` of the scan thread appeared to show. This comparison
/// does happen to be 2.2–2.4× cheaper than `String <` on the names a scan holds,
/// for a reason worth knowing: `URL.lastPathComponent` returns a string whose
/// UTF-8 is not contiguous, and canonical comparison of one of those leaves its
/// bitwise fast path for the normalizing one — which is why the field sample
/// showed NFD/NFC frames on a volume with 18 non-ASCII names in 447,367. On
/// natively stored strings the ranking reverses, so a micro-benchmark over
/// string literals will contradict this and be right about a case that never
/// occurs here. `MacDirStatPerformanceTests.DirectorySortCostTests` measures
/// both; the record is at
/// `.plan/maps/macos-disk-visualizer-impl/records/sort-cost.md`.
///
/// **Public**, because the tree view re-sorts the same children by name when a
/// column header is clicked, and a row order that disagreed with the engine's
/// would put a treemap box and its tree row in different places for the same
/// pair of names.
public enum NameOrder {
    /// `true` when `a` sorts before `b` in Unicode code-point order.
    ///
    /// UTF-8 byte order, UTF-16 code-unit order for the BMP, and scalar order
    /// all agree here; scalars are used because they are what §6.1 says and
    /// what the other package compares.
    @inline(__always)
    public static func precedes(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }
}
