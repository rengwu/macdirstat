import Foundation

/// The production `DirectoryProbe`: macOS packed bulk attributes, with the
/// FileManager resource-value path retained as a compatibility fallback
/// (spec §5.1, §5.4).
///
/// **Read-only, structurally.** It implements a seam that has no write,
/// download or open-data requirement, and it calls no such API itself — the
/// `ScanCoreFileSystemTests` asserts that against this file's own source text,
/// next to the fingerprint proof that a real scan leaves a real tree
/// byte-identical.
///
/// **One batched fetch per directory.** `getattrlistbulk(2)` fills reusable
/// storage with names, kinds, sizes, link counts and identities. Most entries
/// become `EntryMeta` directly from that buffer, avoiding one URL and eleven
/// bridged Foundation values apiece. Package type is resolved once per bounded
/// extension cache. On a filesystem that cannot vend the bulk attributes,
/// `contentsOfDirectory(at:includingPropertiesForKeys:options:)` provides the
/// same facts through the previous implementation.
///
/// **Shallow, never the deep enumerator.** `FileManager.enumerator(at:)`
/// traverses mount points, which would silently leave the root's device; the
/// engine recurses itself so every descent passes the boundary check
/// (spec §3.3, §5.4).
public struct FileManagerDirectoryProbe: PackageSummarizingProbe, ConcurrentDirectoryListingProbe {
    public init() {}

    /// The fallback prefetch key set — exactly the facts `EntryMeta` carries.
    static let entryKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        // The measure, and the one carried beside it. Both ride the same
        // batched prefetch: three alternating warm passes over
        // `/System/Library/Frameworks` measured ten keys at 5.153 s and these
        // eleven plus the extra read at 5.160 s — 0.1%, inside the noise
        // (ticket 13).
        .fileAllocatedSizeKey,
        .fileSizeKey,
        .linkCountKey,
        .fileResourceIdentifierKey,
        .volumeIdentifierKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey
    ]

    /// The set form used by fallback `resourceValues(forKeys:)` and root
    /// metadata.
    ///
    /// Building this set in `entryMeta(of:)` used to hash the same eleven keys
    /// once per filesystem entry. A whole-volume scan calls that helper
    /// millions of times; the key set is immutable, so build it once.
    static let entryKeySet = Set(entryKeys)

    /// The volume facts pre-flight reads, once, for the root only.
    static let volumeKeys: Set<URLResourceKey> = [
        .volumeIsLocalKey,
        .volumeSupportsHardLinksKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey
    ]

    // MARK: - DirectoryProbe

    public func list(_ url: URL) throws -> [EntryMeta] {
        // `getattrlistbulk` returns the whole directory as packed records from
        // one reusable buffer: no URL/resource-value object graph per entry.
        // Filesystems that do not vend the requested attributes fall back to
        // the exact Foundation path below.
        if let packed = BulkDirectoryReader.list(
            url,
            isPackage: { name in Self.isPackageDirectory(named: name, below: url) }
        ) {
            return packed
        }
        return try foundationList(url)
    }

    private func foundationList(_ url: URL) throws -> [EntryMeta] {
        // No `.skipsHiddenFiles`: hidden entries are included, deliberately
        // (spec §3.4). No `.skipsPackageDescendants` either — a package is
        // measured *through* and only presented collapsed (spec §3.4).
        //
        // **The pool is the memory ceiling.** `contentsOfDirectory` returns one
        // `URL` per entry, each carrying the eleven prefetched resource values as
        // Foundation objects, and every one of them is autoreleased. The
        // traversal is a single long synchronous run inside a detached task
        // with no suspension point in it, so it is one job on the cooperative
        // pool and the thread's pool is not drained until that job ends — which
        // is when the whole scan ends. Without this pool the process holds
        // every listing it has ever made: `MacDirStatPerformanceTests` measured
        // **13,615 bytes of resident footprint per entry** on a real 65,536-entry
        // tree, against **158** with it, and the field report that prompted the
        // measurement saw 28 GB on a 2.4-million-file volume (spec §8.4).
        return try autoreleasepool {
            let children = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Self.entryKeys,
                options: []
            )
            return children.map(Self.entryMeta(of:))
        }
    }

    public func metadata(of url: URL) throws -> EntryMeta {
        // Unlike a child, the root has no listing to have described it, so this
        // read is allowed to throw: a root that is missing or unreadable is the
        // one thing that fails a scan outright (spec §5.3).
        let values = try url.resourceValues(forKeys: Self.entryKeySet)
        var meta = Self.entryMeta(name: url.lastPathComponent, values: values)
        var status = stat()
        if lstat(url.path, &status) == 0 {
            meta.fileIdentity = BulkDirectoryReader.fileIdentity(
                fileID: UInt64(status.st_ino),
                volumeObject: values.volumeIdentifier as? NSObject
            )
        }
        return meta
    }

    public func volumeInfo(for url: URL) throws -> VolumeInfo {
        let values = try url.resourceValues(forKeys: Self.volumeKeys)
        return VolumeInfo(
            // A key that could not be read is not evidence of a network volume
            // or of a volume without hard links, and refusing an eligible root
            // is the worse error — so an unreadable fact reads as the
            // permissive one (spec §3.3).
            isLocal: values.volumeIsLocal ?? true,
            supportsHardLinks: values.volumeSupportsHardLinks ?? true,
            capacity: Self.capacity(from: values)
        )
    }

    /// `getmntinfo_r_np(3)` — the mount table, in one call, with no
    /// per-directory `statfs` anywhere.
    ///
    /// The `_r_np` variant, not plain `getmntinfo`: that one answers out of a
    /// static buffer shared by the whole process, which two scans running at
    /// once would race on. This one hands back a buffer that is ours to free.
    ///
    /// `MNT_NOWAIT` deliberately: the cached figures are what is wanted, and a
    /// scan must not block on a stalled network mount to learn where the mount
    /// points are.
    public func mountPointPaths() -> Set<String> {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        defer { free(buffer) }
        guard count > 0, let mounts = buffer else { return [] }
        var paths = Set<String>(minimumCapacity: Int(count))
        for index in 0..<Int(count) {
            var mount = mounts[index]
            let path = withUnsafeBytes(of: &mount.f_mntonname) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            paths.insert(path)
        }
        return paths
    }

    /// Measures a package as a flat aggregate. Unlike the detailed scanner,
    /// this pass requests only the metadata needed for the two totals and
    /// counts, does not sort directory listings, and creates no node per
    /// descendant. Files still have to be visited because macOS does not store
    /// a reliable recursive size on a directory.
    public func summarizePackage(
        _ url: URL,
        onVolume rootVolume: FileSystemIdentity?,
        shouldStop: @Sendable () -> Bool
    ) -> PackageSummary? {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .linkCountKey,
            .fileResourceIdentifierKey,
            .volumeIdentifierKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        let keySet = Set(keys)

        var encounteredError = false
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                encounteredError = true
                return true
            }
        ) else { return nil }

        var diskBytes: Int64 = 0
        var contentBytes: Int64 = 0
        var fileCount: Int64 = 0
        var directoryCount = 0
        var remoteOnlyItems = 0
        var crossedVolumeBoundaries = 0
        var hardLinkOwners: [FileSystemIdentity: PackageSummary.HardLink] = [:]

        for case let child as URL in enumerator {
            if shouldStop() { return nil }

            let values: URLResourceValues
            do {
                values = try child.resourceValues(forKeys: keySet)
            } catch {
                encounteredError = true
                continue
            }

            if values.isSymbolicLink == true { continue }

            if values.ubiquitousItemDownloadingStatus == .notDownloaded {
                remoteOnlyItems += 1
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }

            if let rootVolume,
               let itemVolume = values.volumeIdentifier as? NSObject,
               FileSystemIdentity(itemVolume) != rootVolume {
                crossedVolumeBoundaries += 1
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }

            if values.isDirectory == true {
                directoryCount += 1
                continue
            }
            guard values.isRegularFile == true else { continue }
            // Count names, including weightless duplicates, just as the
            // detailed scanner does. Byte ownership is a separate concern.
            fileCount += 1

            guard let allocation = values.fileAllocatedSize else {
                encounteredError = true
                continue
            }

            let measured = Int64(max(0, allocation))
            let contentLength = Int64(max(0, values.fileSize ?? allocation))
            if let links = values.linkCount, links > 1,
               let object = values.fileResourceIdentifier as? NSObject {
                let identity = FileSystemIdentity(object)
                // The enumerator may canonicalize /var to /private/var, so
                // derive the relative path from depth, not absolute prefixes.
                let path = Array(child.pathComponents.suffix(enumerator.level))
                if let owner = hardLinkOwners[identity] {
                    // Enumeration order is unspecified. Keep the same owner
                    // path a detailed walk would encounter first.
                    if Self.packagePathPrecedes(path, owner.relativePath) {
                        hardLinkOwners[identity]?.relativePath = path
                    }
                    continue
                }
                hardLinkOwners[identity] = PackageSummary.HardLink(
                    identity: identity,
                    relativePath: path,
                    diskBytes: measured,
                    contentBytes: contentLength
                )
            }

            diskBytes += measured
            contentBytes += contentLength
        }

        return PackageSummary(
            diskBytes: diskBytes,
            contentBytes: contentBytes,
            fileCount: fileCount,
            directoryCount: directoryCount,
            isComplete: !encounteredError,
            remoteOnlyItems: remoteOnlyItems,
            crossedVolumeBoundaries: crossedVolumeBoundaries,
            hardLinks: hardLinkOwners.values.sorted {
                Self.packagePathPrecedes($0.relativePath, $1.relativePath)
            }
        )
    }

    /// Mirrors the detailed cursor: name order, with hidden directories
    /// deferred until their visible siblings have finished. Hidden files are
    /// not deferred. Only the paths of hard links need this comparison.
    private static func packagePathPrecedes(_ lhs: [String], _ rhs: [String]) -> Bool {
        for index in 0..<min(lhs.count, rhs.count) {
            let left = lhs[index]
            let right = rhs[index]
            if left.utf8.elementsEqual(right.utf8) { continue }
            let leftDeferred = index < lhs.count - 1 && left.hasPrefix(".")
            let rightDeferred = index < rhs.count - 1 && right.hasPrefix(".")
            if leftDeferred != rightDeferred { return !leftDeferred }
            return NameOrder.precedes(left, right)
        }
        return lhs.count < rhs.count
    }

    // MARK: - Building an `EntryMeta`

    /// The child case: the URL already carries its prefetched values.
    static func entryMeta(of url: URL) -> EntryMeta {
        let name = url.lastPathComponent
        if let values = try? url.resourceValues(forKeys: entryKeySet) {
            return entryMeta(name: name, values: values)
        }
        // Defensive, and reached only by live change: the entry was listed with
        // its parent and was gone (or became unreadable) before its values were
        // read. It is still an entry the user had, so it stays visible.
        return entryMeta(name: name, byStattingPathAt: url.path)
    }

    static func entryMeta(name: String, values: URLResourceValues) -> EntryMeta {
        EntryMeta(
            name: name,
            // Order matters nowhere here — the engine classifies symlinks
            // first — but note that on macOS these values do *not* follow a
            // link: a symlink to a directory reports `isDirectory == false`.
            isDirectory: values.isDirectory ?? false,
            isRegularFile: values.isRegularFile ?? false,
            isSymbolicLink: values.isSymbolicLink ?? false,
            isPackage: values.isPackage ?? false,
            // `fileAllocatedSizeKey` is the blocks on disk — the measure
            // (spec §3.1). It is absent for a directory, and absent rather
            // than guessed when it could not be read (spec §3.5).
            diskSize: values.fileAllocatedSize.map(Int64.init),
            // `fileSizeKey`, carried beside it and driving nothing. Extended
            // attributes and resource forks are not content and are not in it.
            contentLength: values.fileSize.map(Int64.init),
            linkCount: values.linkCount,
            fileIdentity: (values.fileResourceIdentifier as? NSObject).map { FileSystemIdentity($0) },
            volumeIdentifier: (values.volumeIdentifier as? NSObject).map { FileSystemIdentity($0) },
            isUbiquitousItem: values.isUbiquitousItem ?? false,
            cloudDownloadingStatus: cloudStatus(values.ubiquitousItemDownloadingStatus)
        )
    }

    /// The fallback when a listed entry's resource values cannot be read at all.
    ///
    /// `lstat` — never `stat` — so a symlink is described as itself rather than
    /// as whatever it points at. Identity and volume are deliberately left
    /// `nil`: a `dev`/`inode` pair built here would not compare equal to the
    /// opaque identities every other entry carries, and a hard link that failed
    /// to match its owner would be counted **twice**. `nil` makes this entry
    /// own its own bytes and descend, which is the conservative direction.
    static func entryMeta(name: String, byStattingPathAt path: String) -> EntryMeta {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            // Gone entirely. Kept as a named, kindless, zero-byte entry: live
            // change is best-effort and nothing here is guessed (spec §3.5).
            return EntryMeta(name: name)
        }
        let format = status.st_mode & S_IFMT
        let isRegularFile = format == S_IFREG
        return EntryMeta(
            name: name,
            isDirectory: format == S_IFDIR,
            isRegularFile: isRegularFile,
            isSymbolicLink: format == S_IFLNK,
            // `st_blocks` is counted in 512-byte units by definition, whatever
            // the filesystem's own block size — the same quantity
            // `fileAllocatedSizeKey` reports, reached the other way.
            diskSize: isRegularFile ? Int64(status.st_blocks) * 512 : nil,
            contentLength: isRegularFile ? Int64(status.st_size) : nil
        )
    }

    static func cloudStatus(_ status: URLUbiquitousItemDownloadingStatus?) -> CloudDownloadingStatus? {
        guard let status = status else { return nil }
        if status == .notDownloaded { return .notDownloaded }
        if status == .downloaded { return .downloaded }
        if status == .current { return .current }
        // A status macOS does not recognise — the third-party provider case.
        // `nil` means "count the present logical file" (spec §3.4).
        return nil
    }

    /// Package-ness is a filename-type property on macOS. Resolve an extension
    /// once through Foundation, then reuse that answer for every directory of
    /// the same type across the scan. Extensionless directories are ordinary
    /// unless a future bulk attribute says otherwise.
    private static let packageExtensions = PackageExtensionCache()

    static func isPackageDirectory(named name: String, below parent: URL) -> Bool {
        let pathExtension = (name as NSString).pathExtension.lowercased()
        guard !pathExtension.isEmpty else { return false }
        return packageExtensions.isPackage(extension: pathExtension) {
            let child = parent.appendingPathComponent(name, isDirectory: true)
            return (try? child.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        }
    }

    static func capacity(from values: URLResourceValues) -> VolumeCapacity? {
        guard let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity
        else { return nil }
        return VolumeCapacity(totalBytes: Int64(total), availableBytes: Int64(available))
    }
}
