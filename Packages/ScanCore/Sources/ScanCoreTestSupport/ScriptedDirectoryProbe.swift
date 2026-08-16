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

    public static func directory(
        _ name: String,
        volume: FileSystemIdentity? = nil,
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
                volumeIdentifier: volume,
                isUbiquitousItem: isUbiquitousItem,
                cloudDownloadingStatus: cloudStatus
            ),
            children: children,
            listFailure: listFailure
        )
    }

    /// - Parameters:
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
        volume: FileSystemIdentity? = nil,
        linkCount: Int? = nil,
        identity: FileSystemIdentity? = nil,
        isUbiquitousItem: Bool = false,
        cloudStatus: CloudDownloadingStatus? = nil
    ) -> ScriptedEntry {
        ScriptedEntry(meta: EntryMeta(
            name: name,
            isRegularFile: true,
            fileSize: bytes,
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
                fileSize: 1 << 31,  // a link "to" a 2 GiB file: it must still count zero
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
        beforeRequest: (@Sendable (ProbeRequest) -> Void)? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.root = root
        self.info = volumeInfo
        self.metadataFailure = metadataFailure
        self.volumeInfoFailure = volumeInfoFailure
        self.clock = clock
        self.advancePerRequest = advancePerRequest
        self.beforeRequest = beforeRequest
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
        if let failure = metadataFailure, url.standardizedFileURL == rootURL { throw failure }
        return entry.meta
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
        let full = url.standardizedFileURL.pathComponents
        let base = rootURL.pathComponents
        guard full.count >= base.count, Array(full.prefix(base.count)) == base else {
            return url.standardizedFileURL.path
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
