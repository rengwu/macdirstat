import Foundation

/// An opaque filesystem identity — a volume identifier or a file identifier.
///
/// `URLResourceKey.volumeIdentifierKey` and `.fileResourceIdentifierKey` both
/// vend an opaque object that Apple documents as comparable **only** with
/// `isEqual(_:)`, and that is not persistent across restarts. This wrapper
/// keeps that contract (equality forwards to `isEqual`, hashing forwards to
/// `hash`) while giving `EntryMeta` a `Hashable`, `Sendable` field.
///
/// It is `@unchecked Sendable` because the wrapped object is an immutable
/// value handed out by Foundation; nothing here mutates it.
public struct FileSystemIdentity: Hashable, @unchecked Sendable {
    private let object: NSObject

    /// Wraps an identity object read from a URL resource value.
    public init(_ object: NSObject) {
        self.object = object
    }

    /// Wraps a token as an identity — the shape tests use to model distinct
    /// volumes and inodes without a real filesystem.
    public init(_ token: String) {
        self.object = token as NSString
    }

    public static func == (lhs: FileSystemIdentity, rhs: FileSystemIdentity) -> Bool {
        lhs.object.isEqual(rhs.object)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(object.hash)
    }
}

/// The materialization state of a cloud / file-provider item
/// (`URLResourceKey.ubiquitousItemDownloadingStatusKey`).
///
/// Ticket 03 carries the field so the probe seam mirrors the full prefetch key
/// set; the attribution rules that read it (omit remote-only items, count them
/// as exclusions, never trigger a download) land in ticket 04.
public enum CloudDownloadingStatus: Sendable, Equatable {
    case notDownloaded
    case downloaded
    case current
}

/// One directory entry's metadata, as prefetched by a single shallow listing.
///
/// This mirrors the engine's prefetch key set (`isDirectoryKey`,
/// `isRegularFileKey`, `isSymbolicLinkKey`, `isPackageKey`, `fileSizeKey`,
/// `linkCountKey`, `fileResourceIdentifierKey`, `volumeIdentifierKey`,
/// `isUbiquitousItemKey`, `ubiquitousItemDownloadingStatusKey`), so a listing
/// costs one batched metadata fetch per directory and the traversal never
/// re-reads an entry it has already seen (spec §5.4, §8.2).
///
/// `fileSize` is optional on purpose: a size that could not be read is
/// **never** guessed (spec §3.1, §3.5).
public struct EntryMeta: Sendable, Equatable {
    /// Last path component only. Absolute URLs are rebuilt from the parent
    /// chain on demand (spec §5.2).
    public var name: String
    public var isDirectory: Bool
    public var isRegularFile: Bool
    public var isSymbolicLink: Bool
    public var isPackage: Bool
    /// `fileSizeKey` — the logical content length, the engine's one measure.
    /// `nil` means unreadable; it is never replaced with an estimate.
    public var fileSize: Int64?
    /// `linkCountKey`. Read by ticket 04's hard-link dedup; `1` cannot be a
    /// hard link.
    public var linkCount: Int?
    /// `fileResourceIdentifierKey`. Read by ticket 04's hard-link dedup.
    public var fileIdentity: FileSystemIdentity?
    /// `volumeIdentifierKey` — the device-boundary check (spec §3.3, §5.4).
    public var volumeIdentifier: FileSystemIdentity?
    public var isUbiquitousItem: Bool
    /// Read by ticket 04's cloud-materialization rule.
    public var cloudDownloadingStatus: CloudDownloadingStatus?

    public init(
        name: String,
        isDirectory: Bool = false,
        isRegularFile: Bool = false,
        isSymbolicLink: Bool = false,
        isPackage: Bool = false,
        fileSize: Int64? = nil,
        linkCount: Int? = nil,
        fileIdentity: FileSystemIdentity? = nil,
        volumeIdentifier: FileSystemIdentity? = nil,
        isUbiquitousItem: Bool = false,
        cloudDownloadingStatus: CloudDownloadingStatus? = nil
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.isRegularFile = isRegularFile
        self.isSymbolicLink = isSymbolicLink
        self.isPackage = isPackage
        self.fileSize = fileSize
        self.linkCount = linkCount
        self.fileIdentity = fileIdentity
        self.volumeIdentifier = volumeIdentifier
        self.isUbiquitousItem = isUbiquitousItem
        self.cloudDownloadingStatus = cloudDownloadingStatus
    }
}

/// Volume-level facts read once, at pre-flight.
public struct VolumeInfo: Sendable, Equatable {
    /// `volumeIsLocalKey`. `false` means network-mounted, which is an
    /// ineligible root (spec §3.3).
    public var isLocal: Bool
    /// `volumeSupportsHardLinksKey`. When `false`, ticket 04 skips the
    /// hard-link identity index entirely.
    public var supportsHardLinks: Bool
    /// Capacity/free for a whole-volume scan. Reported **separately** and
    /// never turned into an attributed node byte count (spec §3.5).
    public var capacity: VolumeCapacity?

    public init(isLocal: Bool, supportsHardLinks: Bool = true, capacity: VolumeCapacity? = nil) {
        self.isLocal = isLocal
        self.supportsHardLinks = supportsHardLinks
        self.capacity = capacity
    }
}

/// A volume's capacity and free space — shown as separate volume facts, never
/// as bytes attributed to a node (spec §3.5).
public struct VolumeCapacity: Sendable, Equatable {
    public var totalBytes: Int64
    public var availableBytes: Int64

    public init(totalBytes: Int64, availableBytes: Int64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    /// The denominator of a whole-volume scan's explicitly approximate
    /// completion fraction (spec §5.5).
    public var usedBytes: Int64 {
        max(0, totalBytes - availableBytes)
    }
}
