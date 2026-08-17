import Foundation

/// The production `DirectoryProbe`: `FileManager` plus prefetched URL resource
/// values (spec §5.1, §5.4).
///
/// **Read-only, structurally.** It implements a seam that has no write,
/// download or open-data requirement, and it calls no such API itself — the
/// whole adapter is one `contentsOfDirectory` and one `resourceValues` per
/// directory. `ScanCoreFileSystemTests` asserts that against this file's own
/// source text, next to the fingerprint proof that a real scan leaves a real
/// tree byte-identical.
///
/// **One batched fetch per directory.** `contentsOfDirectory(at:
/// includingPropertiesForKeys:options:)` populates every key in
/// `entryKeys` on the URLs it returns, so the `resourceValues` call that
/// follows reads the values already fetched rather than going back to the disk.
/// That is what makes "no entry is read twice" (spec §8.2) true of the
/// production adapter and not just of the engine.
///
/// **Shallow, never the deep enumerator.** `FileManager.enumerator(at:)`
/// traverses mount points, which would silently leave the root's device; the
/// engine recurses itself so every descent passes the boundary check
/// (spec §3.3, §5.4).
public struct FileManagerDirectoryProbe: DirectoryProbe {
    public init() {}

    /// The prefetch key set — exactly the facts `EntryMeta` carries.
    static let entryKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .fileSizeKey,
        .linkCountKey,
        .fileResourceIdentifierKey,
        .volumeIdentifierKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey
    ]

    /// The volume facts pre-flight reads, once, for the root only.
    static let volumeKeys: Set<URLResourceKey> = [
        .volumeIsLocalKey,
        .volumeSupportsHardLinksKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey
    ]

    // MARK: - DirectoryProbe

    public func list(_ url: URL) throws -> [EntryMeta] {
        // No `.skipsHiddenFiles`: hidden entries are included, deliberately
        // (spec §3.4). No `.skipsPackageDescendants` either — a package is
        // measured *through* and only presented collapsed (spec §3.4).
        //
        // **The pool is the memory ceiling.** `contentsOfDirectory` returns one
        // `URL` per entry, each carrying the ten prefetched resource values as
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
        let values = try url.resourceValues(forKeys: Set(Self.entryKeys))
        return Self.entryMeta(name: url.lastPathComponent, values: values)
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

    // MARK: - Building an `EntryMeta`

    /// The child case: the URL already carries its prefetched values.
    static func entryMeta(of url: URL) -> EntryMeta {
        let name = url.lastPathComponent
        if let values = try? url.resourceValues(forKeys: Set(entryKeys)) {
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
            // `fileSizeKey` is the logical content length — the one measure
            // (spec §3.1). It is absent for a directory, and absent rather
            // than guessed when it could not be read (spec §3.5). Extended
            // attributes and resource forks are not content and are not in it;
            // neither is allocated size.
            fileSize: values.fileSize.map(Int64.init),
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
            fileSize: isRegularFile ? Int64(status.st_size) : nil
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

    static func capacity(from values: URLResourceValues) -> VolumeCapacity? {
        guard let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity
        else { return nil }
        return VolumeCapacity(totalBytes: Int64(total), availableBytes: Int64(available))
    }
}
