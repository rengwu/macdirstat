import Foundation
import ScanCore

/// The scale generator's identity (spec §9.2).
///
/// Every record this suite writes carries both, because a memory number is
/// meaningless without the workload that produced it, and a workload is only
/// comparable across runs if the same version and seed rebuild it byte for
/// byte.
enum ScaleGenerator {
    static let version = "fixture-v1"
    /// `0x4D4453` — "MDS".
    static let seed: UInt64 = 0x4D_44_53

    /// SplitMix64's finalizer: a full-avalanche integer hash with no state.
    ///
    /// Stateless matters more here than randomness quality. The whole workload
    /// has to be derivable from an index — that is what lets the probe compute
    /// a listing instead of retaining one — so every "random" fact is a pure
    /// function of `(seed, index)` and no generator object is ever threaded
    /// through the traversal.
    static func hash(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - What a rung declares before anything runs

/// One rung's exact composition, computed before the scan and asserted against
/// the scan's own totals afterwards.
///
/// "Exact" is the point (spec §9.2): the entry count and the byte total are
/// arithmetic, not the sum of whatever a random draw happened to produce, so a
/// rung is reproducible on any machine and a drift in the engine's accounting
/// shows up as a mismatch rather than as a plausible-looking number.
struct WorkloadManifest: Equatable {
    let rung: String
    /// Directories **including the scan root**, which is itself an entry.
    let directoryCount: Int
    let fileCount: Int
    /// The ladder's definition of "entries" (spec §8.1): files + directories.
    var entryCount: Int { directoryCount + fileCount }
    /// The sum of every file's logical length, before hard-link deduplication.
    let logicalBytes: Int64
    /// What the scan should attribute — `logicalBytes` less the bytes a
    /// hard-link non-owner gives up (spec §3.4).
    let attributedBytes: Int64
    /// Entries the scan should report as unreadable (spec §3.5).
    let unreadableEntries: Int
    /// Entries the scan should skip on purpose — a different volume, a
    /// remote-only placeholder (spec §3.4, §3.5).
    let exclusions: Int
    /// Names that should end up attributed to another in-scope path.
    let hardLinkDuplicates: Int
    /// Deepest directory below the root; the root itself is depth 0.
    let maximumDepth: Int

    /// The scan is expected to run to `.completed` with an Exact tree unless
    /// something was deliberately made unreadable.
    var expectsExactTree: Bool { unreadableEntries == 0 }
}

// MARK: - File sizes that add up

/// A file-size composition that hits an exact byte total while storing nothing
/// per file.
///
/// A heavy tail is what makes a treemap interesting and a squarify pass work
/// for its living, so sizes cannot all be equal. But a per-file random draw
/// cannot be made to sum to an exact target without either a prefix-sum table
/// (one `Int64` per file — the "second metadata copy" the ticket forbids) or a
/// single balancing file large enough to distort the picture.
///
/// So the composition is arithmetic instead. A short **ladder** of exact
/// (count, size) rungs carries the tail of the distribution; every remaining
/// file is a **tail file**, and the leftover bytes are divided among them by
/// `divmod`, with the first `tailRemainder` of them one byte larger. The total
/// is then exactly the target by construction, and `size(ofFileAt:)` is O(1)
/// with no storage.
///
/// Which file lands on which rung is decided by an affine permutation of the
/// file index, so the large files are scattered through the tree rather than
/// clustered in the first directory the walk reaches.
struct SizeComposition {
    struct Rung: Equatable {
        let count: Int
        let bytes: Int64
    }

    let fileCount: Int
    let totalBytes: Int64
    let rungs: [Rung]
    let tailCount: Int
    let tailQuotient: Int64
    let tailRemainder: Int

    private let multiplier: UInt64
    private let offset: UInt64

    init(fileCount: Int, totalBytes: Int64, rungs: [Rung], seed: UInt64 = ScaleGenerator.seed) {
        precondition(fileCount > 0, "a composition needs at least one file")
        let laddered = rungs.reduce(0) { $0 + $1.count }
        let ladderBytes = rungs.reduce(Int64(0)) { $0 + Int64($1.count) * $1.bytes }
        precondition(laddered < fileCount, "the ladder must leave tail files behind")
        precondition(ladderBytes < totalBytes, "the ladder must leave tail bytes behind")

        let tailCount = fileCount - laddered
        let tailBytes = totalBytes - ladderBytes
        precondition(tailBytes >= Int64(tailCount), "every tail file must be at least one byte")

        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.rungs = rungs
        self.tailCount = tailCount
        self.tailQuotient = tailBytes / Int64(tailCount)
        self.tailRemainder = Int(tailBytes % Int64(tailCount))

        // `(a·i + b) mod n` permutes `0..<n` exactly when `gcd(a, n) == 1`.
        // `a` is kept under 2^31 and `i` under 2^32 so the product cannot wrap.
        var candidate = (ScaleGenerator.hash(seed ^ 0xA5A5) % 0x7FFF_FFFF) | 1
        while Self.greatestCommonDivisor(candidate, UInt64(fileCount)) != 1 {
            candidate += 2
        }
        self.multiplier = candidate
        self.offset = ScaleGenerator.hash(seed ^ 0x5A5A) % UInt64(fileCount)
    }

    /// The size class file `index` falls into. Pure, O(rungs), no allocation.
    func size(ofFileAt index: Int) -> Int64 {
        var position = permuted(index)
        for rung in rungs {
            if position < rung.count { return rung.bytes }
            position -= rung.count
        }
        return position < tailRemainder ? tailQuotient + 1 : tailQuotient
    }

    /// The declared total, recomputed from the composition itself so a test can
    /// check the arithmetic rather than trust the initializer.
    var recomputedTotalBytes: Int64 {
        rungs.reduce(Int64(0)) { $0 + Int64($1.count) * $1.bytes }
            + tailQuotient * Int64(tailCount)
            + Int64(tailRemainder)
    }

    private func permuted(_ index: Int) -> Int {
        Int((UInt64(index) &* multiplier &+ offset) % UInt64(fileCount))
    }

    private static func greatestCommonDivisor(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}

// MARK: - Names

/// The names the generator hands out.
///
/// Deliberately **over fifteen bytes** for both files and directories. Swift
/// stores a string of fifteen UTF-8 bytes or fewer inline in the `String`
/// value and anything longer on the heap, so short synthetic names would
/// quietly remove one heap allocation per node from a memory measurement whose
/// whole purpose is to be believed. Real filenames are not fifteen bytes.
enum WorkloadNaming {
    static func directoryName(_ index: Int) -> String { "directory-\(index)" }

    static func fileName(_ index: Int) -> String {
        "entry-\(index).\(fileExtension(index))"
    }

    /// One extension per palette group, so a scale rung also exercises the
    /// eleven-hue classification rather than painting everything `.other`.
    static let fileExtensions = [
        "swift", "png", "mp4", "mp3", "pdf", "zip", "pkg", "dmg", "ttf", "bin", "dylib"
    ]

    static func fileExtension(_ index: Int) -> String {
        fileExtensions[Int(ScaleGenerator.hash(ScaleGenerator.seed &+ UInt64(index)) % UInt64(fileExtensions.count))]
    }

    /// Parses `directory-<n>`; `nil` for anything else.
    static func directoryIndex(of component: String) -> Int? {
        guard component.hasPrefix("directory-") else { return nil }
        return Int(component.dropFirst("directory-".count))
    }
}

// MARK: - The workload seam

/// A generated workload, addressed by path and computed on demand.
///
/// The point of the seam is what it does **not** have: no stored tree, no
/// `[EntryMeta]` per directory kept alive for the duration, nothing whose size
/// grows with the rung. `entries(at:)` derives a listing from the path and the
/// seed each time it is asked, which is what makes a two-million-entry rung
/// measurable in the same process that is measuring memory (spec §9.2).
protocol ScaleWorkload: Sendable {
    var manifest: WorkloadManifest { get }
    var volumeInfo: VolumeInfo { get }
    /// The identity every in-scope entry carries; a decoy carries another.
    var rootVolumeIdentity: FileSystemIdentity { get }
    /// The entries of the directory at `components` (empty means the root).
    /// Throws exactly as a real probe would for a directory it cannot list.
    func entries(at components: [String]) throws -> [EntryMeta]
}

extension ScaleWorkload {
    var volumeInfo: VolumeInfo { VolumeInfo(isLocal: true, supportsHardLinks: true, capacity: nil) }
    var rootVolumeIdentity: FileSystemIdentity { FileSystemIdentity("volume-root") }

    /// The scan root's own metadata, read once at pre-flight.
    func rootMetadata(name: String) -> EntryMeta {
        EntryMeta(name: name, isDirectory: true, volumeIdentifier: rootVolumeIdentity)
    }
}
