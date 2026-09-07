import Foundation
import ScanCore

/// A node of a scripted filesystem.
///
/// The scripted probe is authoritative for everything a real disk cannot stage
/// reliably in CI (spec §9.2): distinct volume identifiers, a symlink that
/// would loop if anything followed it, metadata that cannot be read, an exact
/// cancellation checkpoint.
public struct ScriptedEntry {
    public var meta: EntryMeta
    public var children: [ScriptedEntry]
    /// Thrown by `list(_:)` for this directory — an unreadable directory.
    public var listFailure: Error?

    public init(meta: EntryMeta, children: [ScriptedEntry] = [], listFailure: Error? = nil) {
        self.meta = meta
        self.children = children
        self.listFailure = listFailure
    }

    /// - Parameter identity: `fileResourceIdentifierKey`. Two directories that
    ///   carry the **same** identity are the same directory reached by two
    ///   paths — the APFS firmlink graft under `/System/Volumes/Data`, which no
    ///   test can stage on a real disk because only the OS may create a
    ///   firmlink. `nil` models an identity that could not be read, which must
    ///   always be descended.
    public static func directory(
        _ name: String,
        volume: FileSystemIdentity? = nil,
        identity: FileSystemIdentity? = nil,
        isPackage: Bool = false,
        listFailure: Error? = nil,
        isUbiquitousItem: Bool = false,
        cloudStatus: CloudDownloadingStatus? = nil,
        children: [ScriptedEntry] = []
    ) -> ScriptedEntry {
        ScriptedEntry(
            meta: EntryMeta(
                name: name,
                isDirectory: true,
                isPackage: isPackage,
                fileIdentity: identity,
                volumeIdentifier: volume,
                isUbiquitousItem: isUbiquitousItem,
                cloudDownloadingStatus: cloudStatus
            ),
            children: children,
            listFailure: listFailure
        )
    }

    /// - Parameters:
    ///   - bytes: the **blocks on disk** — the measure, and what the engine
    ///     attributes. `nil` models a size that could not be read.
    ///   - contentLength: the length carried beside it. Defaults to `bytes`,
    ///     which is what an ordinary file does; pass it to stage the cases
    ///     where the two diverge — a sparse image, a compressed binary, a cloud
    ///     placeholder that is all length and no blocks (ticket 13).
    ///   - linkCount/identity: the two facts hard-link dedup reads (spec §3.4).
    ///     Scripting them is the only way to stage an inode reached by two
    ///     names, a link count of 1 on colliding identities, or two clones that
    ///     must *not* collide.
    ///   - cloudStatus: `nil` models both an ordinary local file and the
    ///     third-party provider whose materialization state cannot be read —
    ///     the case that must degrade to "count what is there".
    public static func file(
        _ name: String,
        bytes: Int64?,
        contentLength: Int64? = nil,
        volume: FileSystemIdentity? = nil,
        linkCount: Int? = nil,
        identity: FileSystemIdentity? = nil,
        isUbiquitousItem: Bool = false,
        cloudStatus: CloudDownloadingStatus? = nil
    ) -> ScriptedEntry {
        ScriptedEntry(meta: EntryMeta(
            name: name,
            isRegularFile: true,
            diskSize: bytes,
            contentLength: contentLength ?? bytes,
            linkCount: linkCount,
            fileIdentity: identity,
            volumeIdentifier: volume,
            isUbiquitousItem: isUbiquitousItem,
            cloudDownloadingStatus: cloudStatus
        ))
    }

    /// A symlink. `looksLikeDirectory` models the real thing: resource values
    /// on a link to a directory report `isDirectory` as well, so an engine that
    /// checked only that flag would follow it. `children` are what the probe
    /// *would* hand back if anything ever listed it — nothing should.
    public static func symlink(
        _ name: String,
        looksLikeDirectory: Bool = false,
        volume: FileSystemIdentity? = nil,
        children: [ScriptedEntry] = []
    ) -> ScriptedEntry {
        ScriptedEntry(
            meta: EntryMeta(
                name: name,
                isDirectory: looksLikeDirectory,
                isSymbolicLink: true,
                // A link "to" a 2 GiB file, reporting blocks and length alike:
                // neither may tempt the walk, because a symlink counts zero.
                diskSize: 1 << 31,
                contentLength: 1 << 31,
                volumeIdentifier: volume
            ),
            children: children
        )
    }
}

/// One request the engine made of the filesystem.
public struct ProbeRequest: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case list
        case metadata
        case volumeInfo
    }

    public let kind: Kind
    /// Path relative to the scan root; `""` is the root itself.
    public let path: String

    public var description: String { "\(kind) \(path.isEmpty ? "." : path)" }
}

/// A `DirectoryProbe` over a scripted tree that **records every request**.
///
/// The record is the proof for two claims the engine cannot demonstrate any
/// other way (spec §9.3): that nothing beneath a differing-volume child is ever
/// listed, and that no entry is read twice.
public final class ScriptedDirectoryProbe: DirectoryProbe, @unchecked Sendable {
    private let rootURL: URL
    private let root: ScriptedEntry
    private let info: VolumeInfo
    private let metadataFailure: Error?
    private let volumeInfoFailure: Error?
    private let clock: VirtualClock?
    private let advancePerRequest: TimeInterval
    private let beforeRequest: (@Sendable (ProbeRequest) -> Void)?
    private let mountPoints: Set<String>

    private let lock = NSLock()
    private var log: [ProbeRequest] = []

    public init(
        rootURL: URL,
        root: ScriptedEntry,
        volumeInfo: VolumeInfo = VolumeInfo(isLocal: true),
        metadataFailure: Error? = nil,
        volumeInfoFailure: Error? = nil,
        clock: VirtualClock? = nil,
        advancePerRequest: TimeInterval = 0,
        beforeRequest: (@Sendable (ProbeRequest) -> Void)? = nil,
        /// Absolute paths this scripted filesystem calls mount points — how a
        /// test stages the `/System/Volumes/Data` shape, where one mounted
        /// filesystem is presented as part of the root's own volume.
        mountPoints: Set<String> = []
    ) {
        self.rootURL = rootURL
        self.root = root
        self.info = volumeInfo
        self.metadataFailure = metadataFailure
        self.volumeInfoFailure = volumeInfoFailure
        self.clock = clock
        self.advancePerRequest = advancePerRequest
        self.beforeRequest = beforeRequest
        self.mountPoints = mountPoints
    }

    // MARK: - The request log

    public var requests: [ProbeRequest] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    public var listedPaths: [String] {
        requests.filter { $0.kind == .list }.map(\.path)
    }

    // MARK: - DirectoryProbe

    public func list(_ url: URL) throws -> [EntryMeta] {
        let entry = try record(.list, url)
        if let failure = entry.listFailure { throw failure }
        // Deliberately handed back in an order the engine must not rely on.
        return entry.children.map(\.meta).reversed()
    }

    public func metadata(of url: URL) throws -> EntryMeta {
        let entry = try record(.metadata, url)
        if let failure = metadataFailure, relativePath(of: url).isEmpty { throw failure }
        return entry.meta
    }

    public func mountPointPaths() -> Set<String> {
        mountPoints
    }

    public func volumeInfo(for url: URL) throws -> VolumeInfo {
        note(ProbeRequest(kind: .volumeInfo, path: relativePath(of: url)))
        if let failure = volumeInfoFailure { throw failure }
        return info
    }

    // MARK: - Internals

    private func record(_ kind: ProbeRequest.Kind, _ url: URL) throws -> ScriptedEntry {
        let path = relativePath(of: url)
        note(ProbeRequest(kind: kind, path: path))
        guard let entry = entry(atRelativePath: path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return entry
    }

    private func note(_ request: ProbeRequest) {
        beforeRequest?(request)
        clock?.advance(by: advancePerRequest)
        lock.lock()
        log.append(request)
        lock.unlock()
    }

    private func relativePath(of url: URL) -> String {
        // These paths describe a virtual filesystem, including test chains
        // longer than PATH_MAX. Filesystem normalization can truncate them
        // on macOS 15; compare URL components without consulting the host.
        let full = url.pathComponents
        let base = rootURL.pathComponents
        guard full.count >= base.count, Array(full.prefix(base.count)) == base else {
            return url.path
        }
        return full.dropFirst(base.count).joined(separator: "/")
    }

    private func entry(atRelativePath path: String) -> ScriptedEntry? {
        var current = root
        guard !path.isEmpty else { return current }
        for component in path.split(separator: "/") {
            guard let next = current.children.first(where: { $0.meta.name == String(component) }) else {
                return nil
            }
            current = next
        }
        return current
    }
}
