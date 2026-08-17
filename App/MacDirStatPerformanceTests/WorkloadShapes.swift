import Foundation
import ScanCore

// MARK: - The three size rungs

/// Smoke, Representative and Large: a complete k-ary directory tree with the
/// files spread evenly across it and the sizes spread by
/// ``SizeComposition`` (spec §8.1, §9.2).
///
/// The tree is *complete* rather than random so the shape is a closed-form
/// function of an index: directory `j`'s parent is `(j - 1) / branching` and
/// its children are `j·branching + 1 … j·branching + branching`. That is the
/// whole reason a two-million-entry rung needs no storage — a listing is
/// arithmetic on the last path component, and nothing about the directory has
/// to have been remembered from when its parent was listed.
///
/// `foreignVolumeDirectories` hangs a few decoys off the root carrying a
/// *different* volume identifier. They are real entries the scan must show and
/// must never descend (spec §3.3); if anything ever lists one, the probe counts
/// it and the operation-count test fails.
struct BalancedTreeWorkload: ScaleWorkload {
    let rung: String
    /// Directories in the k-ary tree, including the root.
    let treeDirectoryCount: Int
    let fileCount: Int
    let branching: Int
    let foreignVolumeDirectories: Int
    /// Extra names hung off the root that repeat another directory's file
    /// identity: a firmlink graft, at scale. If the visited-directory guard
    /// ever stops working, listing one of these hands back the real subtree and
    /// the rung's declared entry count and byte total both fail.
    let graftedDirectories: Int
    /// Whether directory entries carry a `fileResourceIdentifier` at all.
    ///
    /// A real filesystem always does, so this is `true` everywhere but in the
    /// one measurement that isolates what the visited-directory index costs.
    /// The identity object is built either way — only whether the entry carries
    /// it changes — so the two variants pay the same allocation and differ only
    /// in what the index retains.
    let identifiesDirectories: Bool
    let composition: SizeComposition

    init(
        rung: String,
        directoryCount: Int,
        fileCount: Int,
        branching: Int,
        totalBytes: Int64,
        rungs: [SizeComposition.Rung],
        foreignVolumeDirectories: Int = 0,
        graftedDirectories: Int = 0,
        identifiesDirectories: Bool = true
    ) {
        precondition(
            directoryCount > foreignVolumeDirectories + graftedDirectories,
            "the tree needs a root"
        )
        precondition(graftedDirectories < directoryCount - foreignVolumeDirectories - graftedDirectories,
                     "every graft must repeat a directory the tree actually has")
        self.rung = rung
        self.treeDirectoryCount = directoryCount - foreignVolumeDirectories - graftedDirectories
        self.fileCount = fileCount
        self.branching = branching
        self.foreignVolumeDirectories = foreignVolumeDirectories
        self.graftedDirectories = graftedDirectories
        self.identifiesDirectories = identifiesDirectories
        self.composition = SizeComposition(fileCount: fileCount, totalBytes: totalBytes, rungs: rungs)
    }

    var manifest: WorkloadManifest {
        WorkloadManifest(
            rung: rung,
            directoryCount: treeDirectoryCount + foreignVolumeDirectories + graftedDirectories,
            fileCount: fileCount,
            logicalBytes: composition.totalBytes,
            attributedBytes: composition.totalBytes,
            unreadableEntries: 0,
            exclusions: foreignVolumeDirectories + graftedDirectories,
            hardLinkDuplicates: 0,
            maximumDepth: depth(of: treeDirectoryCount - 1)
        )
    }

    func entries(at components: [String]) throws -> [EntryMeta] {
        let directory = try directoryIndex(for: components)
        if directory == nil {
            // A decoy was listed. Handing back plausible children rather than
            // throwing keeps the failure where it belongs: in the assertion
            // that no decoy is ever listed, not in a mystery scan error.
            return [EntryMeta(name: "should-never-be-listed.bin", isRegularFile: true, fileSize: 1)]
        }
        guard let index = directory else { return [] }

        var entries: [EntryMeta] = []
        let firstChild = index * branching + 1
        let lastChild = min(firstChild + branching - 1, treeDirectoryCount - 1)
        if firstChild <= lastChild {
            entries.reserveCapacity(lastChild - firstChild + 1)
            for child in firstChild...lastChild {
                entries.append(directoryEntry(child))
            }
        }
        if index == 0 {
            for decoy in 0..<foreignVolumeDirectories {
                entries.append(EntryMeta(
                    name: "foreign-volume-\(decoy)",
                    isDirectory: true,
                    volumeIdentifier: FileSystemIdentity("volume-elsewhere-\(decoy)")
                ))
            }
            for graft in 0..<graftedDirectories {
                // Same volume, same identity as `directory-(graft + 1)`: one
                // directory under a second name, exactly as the data volume's
                // firmlinks present one under `/System/Volumes/Data`.
                entries.append(EntryMeta(
                    name: "graft-\(graft)",
                    isDirectory: true,
                    fileIdentity: Self.directoryIdentity(graft + 1),
                    volumeIdentifier: rootVolumeIdentity
                ))
            }
        }
        for file in fileRange(of: index) {
            entries.append(fileEntry(file, bytes: composition.size(ofFileAt: file)))
        }
        return entries
    }

    /// `nil` means "this is a decoy on another volume"; a throw means the path
    /// does not name a directory of this workload at all.
    ///
    /// A graft resolves to the directory it repeats, because that is what a
    /// firmlink does: a walk that ignored the guard would find the whole
    /// subtree there and count it twice, which is the failure this shape exists
    /// to make visible.
    private func directoryIndex(for components: [String]) throws -> Int? {
        guard let last = components.last else { return 0 }
        if last.hasPrefix("foreign-volume-") { return nil }
        if last.hasPrefix("graft-"), let graft = Int(last.dropFirst("graft-".count)) {
            return graft + 1
        }
        guard let index = WorkloadNaming.directoryIndex(of: last), index < treeDirectoryCount else {
            throw CocoaError(.fileNoSuchFile)
        }
        return index
    }

    private func fileRange(of directory: Int) -> Range<Int> {
        let base = fileCount / treeDirectoryCount
        let remainder = fileCount % treeDirectoryCount
        let start = directory * base + min(directory, remainder)
        let count = base + (directory < remainder ? 1 : 0)
        return start..<(start + count)
    }

    private func depth(of directory: Int) -> Int {
        var index = directory
        var depth = 0
        while index > 0 {
            index = (index - 1) / branching
            depth += 1
        }
        return depth
    }

    /// The same rung with directory identities withheld — the control for what
    /// the visited-directory index costs (``MemoryCeilingTests``). Same tree,
    /// same entries, same allocations; the engine simply has nothing to index.
    func withoutDirectoryIdentities() -> BalancedTreeWorkload {
        BalancedTreeWorkload(
            rung: rung + "-no-directory-identities",
            directoryCount: manifest.directoryCount,
            fileCount: fileCount,
            branching: branching,
            totalBytes: composition.totalBytes,
            rungs: composition.rungs,
            foreignVolumeDirectories: foreignVolumeDirectories,
            graftedDirectories: graftedDirectories,
            identifiesDirectories: false
        )
    }

    /// One inode per directory, as a real filesystem reports. Built even when
    /// the entry will not carry it, so the two variants of a rung allocate
    /// identically and their footprints differ only by what the engine kept.
    static func directoryIdentity(_ index: Int) -> FileSystemIdentity {
        FileSystemIdentity("directory-inode-\(index)")
    }

    private func directoryEntry(_ index: Int) -> EntryMeta {
        let identity = Self.directoryIdentity(index)
        return EntryMeta(
            name: WorkloadNaming.directoryName(index),
            isDirectory: true,
            fileIdentity: identifiesDirectories ? identity : nil,
            volumeIdentifier: rootVolumeIdentity
        )
    }

    private func fileEntry(_ index: Int, bytes: Int64) -> EntryMeta {
        EntryMeta(
            name: WorkloadNaming.fileName(index),
            isRegularFile: true,
            fileSize: bytes,
            linkCount: 1,
            volumeIdentifier: rootVolumeIdentity
        )
    }
}

// MARK: - Stress shape 1: one enormous flat directory

/// A single directory holding `fileCount` entries (spec §8.1).
///
/// The shape that finds an engine which sorts, allocates or checks
/// cancellation per *directory* rather than per batch: one listing here is
/// larger than the whole Smoke rung.
struct FlatDirectoryWorkload: ScaleWorkload {
    let fileCount: Int
    let composition: SizeComposition

    init(fileCount: Int, totalBytes: Int64, rungs: [SizeComposition.Rung]) {
        self.fileCount = fileCount
        self.composition = SizeComposition(fileCount: fileCount, totalBytes: totalBytes, rungs: rungs)
    }

    var manifest: WorkloadManifest {
        WorkloadManifest(
            rung: "stress-flat-directory",
            directoryCount: 1,
            fileCount: fileCount,
            logicalBytes: composition.totalBytes,
            attributedBytes: composition.totalBytes,
            unreadableEntries: 0,
            exclusions: 0,
            hardLinkDuplicates: 0,
            maximumDepth: 0
        )
    }

    func entries(at components: [String]) throws -> [EntryMeta] {
        guard components.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        var entries: [EntryMeta] = []
        entries.reserveCapacity(fileCount)
        for index in 0..<fileCount {
            entries.append(EntryMeta(
                name: WorkloadNaming.fileName(index),
                isRegularFile: true,
                fileSize: composition.size(ofFileAt: index),
                linkCount: 1,
                volumeIdentifier: rootVolumeIdentity
            ))
        }
        return entries
    }
}

// MARK: - Stress shape 2: a deep chain

/// A chain `depth` directories long with a handful of files at each level
/// (spec §8.1: "≥20-level chain"; §9.2 fixes 64).
///
/// It is the shape that would put a recursive traversal on the stack, and the
/// shape the map's recorded teardown bound is measured against: releasing a
/// `ScanNode` chain is a recursive ARC teardown, so a rung this deep also has
/// to be *released* without overflowing the releasing thread's stack.
struct DeepChainWorkload: ScaleWorkload {
    let depth: Int
    let filesPerLevel: Int
    let composition: SizeComposition

    init(depth: Int, filesPerLevel: Int, totalBytes: Int64, rungs: [SizeComposition.Rung]) {
        self.depth = depth
        self.filesPerLevel = filesPerLevel
        self.composition = SizeComposition(
            fileCount: filesPerLevel * (depth + 1),
            totalBytes: totalBytes,
            rungs: rungs
        )
    }

    var manifest: WorkloadManifest {
        WorkloadManifest(
            rung: "stress-deep-chain",
            directoryCount: depth + 1,
            fileCount: filesPerLevel * (depth + 1),
            logicalBytes: composition.totalBytes,
            attributedBytes: composition.totalBytes,
            unreadableEntries: 0,
            exclusions: 0,
            hardLinkDuplicates: 0,
            maximumDepth: depth
        )
    }

    func entries(at components: [String]) throws -> [EntryMeta] {
        let level: Int
        if let last = components.last {
            guard let parsed = WorkloadNaming.directoryIndex(of: last), parsed <= depth else {
                throw CocoaError(.fileNoSuchFile)
            }
            level = parsed
        } else {
            level = 0
        }

        var entries: [EntryMeta] = []
        if level < depth {
            entries.append(EntryMeta(
                name: WorkloadNaming.directoryName(level + 1),
                isDirectory: true,
                fileIdentity: BalancedTreeWorkload.directoryIdentity(level + 1),
                volumeIdentifier: rootVolumeIdentity
            ))
        }
        for offset in 0..<filesPerLevel {
            let index = level * filesPerLevel + offset
            entries.append(EntryMeta(
                name: WorkloadNaming.fileName(index),
                isRegularFile: true,
                fileSize: composition.size(ofFileAt: index),
                linkCount: 1,
                volumeIdentifier: rootVolumeIdentity
            ))
        }
        return entries
    }
}

// MARK: - Stress shape 3: one huge file beside thousands of tiny ones

/// One ~40 GiB file and 10,000 tiny ones in the same directory (spec §9.2).
///
/// The treemap's worst case, not the scanner's: at any ordinary viewport the
/// huge file takes essentially the whole rectangle and every tiny file falls
/// under 2×2 pt, so the merge fixpoint has to fold ten thousand children into
/// one aggregate box without leaving a sliver behind (spec §6.2).
struct HugeFileWorkload: ScaleWorkload {
    let hugeBytes: Int64
    let tinyCount: Int
    let tinyBytes: Int64

    var manifest: WorkloadManifest {
        let total = hugeBytes + Int64(tinyCount) * tinyBytes
        return WorkloadManifest(
            rung: "stress-huge-file",
            directoryCount: 1,
            fileCount: tinyCount + 1,
            logicalBytes: total,
            attributedBytes: total,
            unreadableEntries: 0,
            exclusions: 0,
            hardLinkDuplicates: 0,
            maximumDepth: 0
        )
    }

    func entries(at components: [String]) throws -> [EntryMeta] {
        guard components.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        var entries: [EntryMeta] = []
        entries.reserveCapacity(tinyCount + 1)
        entries.append(EntryMeta(
            name: "one-enormous-archive.dmg",
            isRegularFile: true,
            fileSize: hugeBytes,
            linkCount: 1,
            volumeIdentifier: rootVolumeIdentity
        ))
        for index in 0..<tinyCount {
            entries.append(EntryMeta(
                name: WorkloadNaming.fileName(index),
                isRegularFile: true,
                fileSize: tinyBytes,
                linkCount: 1,
                volumeIdentifier: rootVolumeIdentity
            ))
        }
        return entries
    }
}

// MARK: - Stress shape 4: thousands of hard links

/// `inodeCount` inodes reached by `namesPerInode` in-scope names each, beside
/// `ordinaryFileCount` files that are not links at all (spec §9.2: 10,000
/// links).
///
/// The ordinary files are not padding. The memory claim in §5.7 is that the
/// identity index is proportional to *multiply-linked* inodes rather than to
/// the tree, and a workload made only of links could not tell the two apart.
/// Here the index should hold `inodeCount` entries while the directory holds
/// many times that many files.
///
/// Names are zero-padded so the lexicographic order the engine sorts by is
/// also the numeric one, which makes "copy 0 owns the bytes" a fact the test
/// can state rather than a coincidence of string comparison.
struct HardLinkWorkload: ScaleWorkload {
    let inodeCount: Int
    let namesPerInode: Int
    let linkedBytes: Int64
    let ordinaryFileCount: Int
    let ordinaryBytes: Int64
    /// Pairs of files that share an identity but report `linkCount == 1`.
    ///
    /// The only way to *observe* that the index skipped an entry. A link count
    /// of one cannot be a hard link, so both names must own their bytes; an
    /// engine that indexed every readable identity would zero the second one
    /// out, and the attributed total would come in short by exactly this many
    /// files' worth.
    let singleLinkIdentityCollisions: Int

    var linkedNameCount: Int { inodeCount * namesPerInode }
    var collidingNameCount: Int { singleLinkIdentityCollisions * 2 }

    var manifest: WorkloadManifest {
        let collidingBytes = Int64(collidingNameCount) * ordinaryBytes
        let logical = Int64(linkedNameCount) * linkedBytes
            + Int64(ordinaryFileCount) * ordinaryBytes + collidingBytes
        let attributed = Int64(inodeCount) * linkedBytes
            + Int64(ordinaryFileCount) * ordinaryBytes + collidingBytes
        return WorkloadManifest(
            rung: "stress-hard-links",
            directoryCount: 1,
            fileCount: linkedNameCount + ordinaryFileCount + collidingNameCount,
            logicalBytes: logical,
            attributedBytes: attributed,
            unreadableEntries: 0,
            exclusions: 0,
            hardLinkDuplicates: inodeCount * (namesPerInode - 1),
            maximumDepth: 0
        )
    }

    func entries(at components: [String]) throws -> [EntryMeta] {
        guard components.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        var entries: [EntryMeta] = []
        entries.reserveCapacity(linkedNameCount + ordinaryFileCount + collidingNameCount)
        for inode in 0..<inodeCount {
            for copy in 0..<namesPerInode {
                entries.append(EntryMeta(
                    name: String(format: "linked-%07d-%03d.bin", inode, copy),
                    isRegularFile: true,
                    fileSize: linkedBytes,
                    linkCount: namesPerInode,
                    fileIdentity: FileSystemIdentity("inode-\(inode)"),
                    volumeIdentifier: rootVolumeIdentity
                ))
            }
        }
        for index in 0..<ordinaryFileCount {
            entries.append(EntryMeta(
                name: String(format: "ordinary-%07d.bin", index),
                isRegularFile: true,
                fileSize: ordinaryBytes,
                linkCount: 1,
                fileIdentity: FileSystemIdentity("inode-ordinary-\(index)"),
                volumeIdentifier: rootVolumeIdentity
            ))
        }
        for pair in 0..<singleLinkIdentityCollisions {
            for side in ["a", "b"] {
                entries.append(EntryMeta(
                    name: String(format: "unlinked-collision-%05d-\(side).bin", pair),
                    isRegularFile: true,
                    fileSize: ordinaryBytes,
                    linkCount: 1,
                    fileIdentity: FileSystemIdentity("inode-collision-\(pair)"),
                    volumeIdentifier: rootVolumeIdentity
                ))
            }
        }
        return entries
    }
}

// MARK: - Stress shape 5: an error storm

/// 2,500 injected failures split between directories that refuse to list and
/// files whose size cannot be read (spec §9.2, §9.3).
///
/// Both categories are recoverable, so the bar is that the scan still reaches
/// a terminal result with an **exact** total of 2,500, at most 1,000 detailed
/// records, and `truncated == true` — the error path must cost one integer
/// past the cap, not one allocation (spec §5.7).
struct InjectedFailureWorkload: ScaleWorkload {
    let unreadableDirectories: Int
    let unreadableFiles: Int
    let ordinaryFileCount: Int
    let ordinaryBytes: Int64

    var injectedFailures: Int { unreadableDirectories + unreadableFiles }

    var manifest: WorkloadManifest {
        WorkloadManifest(
            rung: "stress-injected-failures",
            directoryCount: 1 + unreadableDirectories,
            fileCount: unreadableFiles + ordinaryFileCount,
            logicalBytes: Int64(ordinaryFileCount) * ordinaryBytes,
            attributedBytes: Int64(ordinaryFileCount) * ordinaryBytes,
            unreadableEntries: injectedFailures,
            exclusions: 0,
            hardLinkDuplicates: 0,
            maximumDepth: 1
        )
    }

    func entries(at components: [String]) throws -> [EntryMeta] {
        if let last = components.last {
            guard last.hasPrefix("refuses-to-list-") else { throw CocoaError(.fileNoSuchFile) }
            // Permission denied, not "no such file": the engine counts a
            // refusal and a disappearance apart (spec §3.5).
            throw CocoaError(.fileReadNoPermission)
        }

        var entries: [EntryMeta] = []
        entries.reserveCapacity(unreadableDirectories + unreadableFiles + ordinaryFileCount)
        for index in 0..<unreadableDirectories {
            entries.append(EntryMeta(
                name: String(format: "refuses-to-list-%05d", index),
                isDirectory: true,
                volumeIdentifier: rootVolumeIdentity
            ))
        }
        for index in 0..<unreadableFiles {
            entries.append(EntryMeta(
                name: String(format: "size-unreadable-%05d.bin", index),
                isRegularFile: true,
                // A size that could not be read is `nil` and is never guessed
                // (spec §3.1, §3.5).
                fileSize: nil,
                linkCount: 1,
                volumeIdentifier: rootVolumeIdentity
            ))
        }
        for index in 0..<ordinaryFileCount {
            entries.append(EntryMeta(
                name: WorkloadNaming.fileName(index),
                isRegularFile: true,
                fileSize: ordinaryBytes,
                linkCount: 1,
                volumeIdentifier: rootVolumeIdentity
            ))
        }
        return entries
    }
}
