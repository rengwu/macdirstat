import Foundation

/// A structural snapshot of a real directory tree, taken before and after a
/// scan to prove the scan changed nothing (spec §9.2).
///
/// It compares relative path, item kind, logical length, mode, modification
/// time, symlink target, inode and link count, plus a content hash of the
/// small non-sparse files. **Access time is excluded**: the OS may update it
/// merely because something read the directory, which is precisely what a scan
/// does and is not a change to the tree.
public struct FilesystemFingerprint: Equatable {
    public enum Kind: String, Equatable {
        case directory
        case file
        case symbolicLink
        case other
    }

    public struct Entry: Equatable, CustomStringConvertible {
        /// Path relative to the fingerprinted root; `""` is the root itself.
        public let relativePath: String
        public let kind: Kind
        /// `st_size`: the logical length, and for a symlink the length of its
        /// target path. Zero for a directory, whose size is not a fact about
        /// its contents.
        public let logicalLength: Int64
        /// Permission bits only.
        public let mode: UInt16
        public let modifiedSeconds: Int64
        public let modifiedNanoseconds: Int64
        /// The link's target text, read with `readlink` — never followed.
        public let symlinkTarget: String?
        public let inode: UInt64
        public let linkCount: UInt64
        /// FNV-1a over the contents of a small file. `nil` for anything that is
        /// not a small regular file — a multi-gigabyte sparse file is never
        /// read, which is the whole point of staging it sparse.
        public let contentHash: UInt64?

        public var description: String {
            let target = symlinkTarget.map { " -> \($0)" } ?? ""
            let hash = contentHash.map { String(format: " hash:%016llx", $0) } ?? ""
            return "\(relativePath.isEmpty ? "." : relativePath) [\(kind.rawValue)] "
                + "len:\(logicalLength) mode:\(String(mode, radix: 8)) "
                + "mtime:\(modifiedSeconds).\(modifiedNanoseconds) "
                + "ino:\(inode) links:\(linkCount)\(target)\(hash)"
        }
    }

    /// Sorted by relative path, so two fingerprints compare directly.
    public let entries: [Entry]

    /// Files at or below this length have their contents hashed. Everything
    /// larger is described by its metadata alone — the fixture's multi-GiB
    /// files are sparse and must never be read.
    public static let maximumHashedLength: Int64 = 4096

    // MARK: - Taking a fingerprint

    /// Walks `root` iteratively, without following symlinks.
    ///
    /// A directory whose mode denies listing is opened by **temporarily**
    /// restoring `0o700` and put back to the mode `lstat` just reported, so the
    /// unreadable directory's own contents are covered by the comparison too.
    /// The recorded mode is the one read from the filesystem before that
    /// happens, so a scan that changed it would still show up as a difference.
    public static func take(of root: URL) throws -> FilesystemFingerprint {
        var entries: [Entry] = []
        // Iterative, because the fixture's chain is 64 levels deep. `.restore`
        // is pushed *before* a subtree's children, so it pops only once that
        // whole subtree has been walked — which is what keeps an unreadable
        // directory open long enough for its contents to be described, and no
        // longer.
        enum Step {
            case visit(url: URL, relativePath: String)
            case restore(url: URL, mode: UInt16)
        }
        var stack: [Step] = [.visit(url: root, relativePath: "")]

        while let step = stack.popLast() {
            switch step {
            case .restore(let url, let mode):
                _ = chmod(url.path, mode_t(mode))

            case .visit(let url, let relativePath):
                let entry = try self.entry(at: url, relativePath: relativePath)
                entries.append(entry)
                guard entry.kind == .directory else { continue }

                let listing: [URL]
                if let readable = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: []
                ) {
                    listing = readable
                } else {
                    // Unreadable by mode. Open it just long enough to look, and
                    // queue putting the mode back exactly as it was found.
                    guard chmod(url.path, 0o700) == 0 else {
                        throw FixtureError.couldNotFingerprint(path: url.path, errno: errno)
                    }
                    stack.append(.restore(url: url, mode: entry.mode))
                    listing = try FileManager.default.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: nil, options: []
                    )
                }

                for child in listing {
                    let name = child.lastPathComponent
                    stack.append(.visit(
                        url: child,
                        relativePath: relativePath.isEmpty ? name : relativePath + "/" + name
                    ))
                }
            }
        }

        entries.sort { $0.relativePath < $1.relativePath }
        return FilesystemFingerprint(entries: entries)
    }

    private static func entry(at url: URL, relativePath: String) throws -> Entry {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw FixtureError.couldNotFingerprint(path: url.path, errno: errno)
        }

        let format = status.st_mode & S_IFMT
        let kind: Kind
        switch format {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .symbolicLink
        default: kind = .other
        }

        let length = Int64(status.st_size)
        return Entry(
            relativePath: relativePath,
            kind: kind,
            logicalLength: kind == .directory ? 0 : length,
            mode: UInt16(status.st_mode & 0o7777),
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            symlinkTarget: kind == .symbolicLink ? readLink(at: url.path) : nil,
            inode: UInt64(status.st_ino),
            linkCount: UInt64(status.st_nlink),
            contentHash: kind == .file && length <= maximumHashedLength
                ? contentHash(of: url)
                : nil
        )
    }

    private static func readLink(at path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(path, &buffer, buffer.count - 1)
        guard length >= 0 else { return nil }
        buffer[length] = 0
        return String(cString: buffer)
    }

    /// FNV-1a, so the hash is a plain deterministic function of the bytes with
    /// no dependency beyond Foundation.
    private static func contentHash(of url: URL) -> UInt64? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    // MARK: - Comparing

    /// The differences from `other`, one readable line each — so a failed
    /// read-only assertion names the file that moved rather than dumping two
    /// trees.
    public func differences(from other: FilesystemFingerprint) -> [String] {
        var lines: [String] = []
        let mine = Dictionary(entries.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let theirs = Dictionary(other.entries.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })

        for path in Set(mine.keys).union(theirs.keys).sorted() {
            switch (theirs[path], mine[path]) {
            case (nil, .some(let after)):
                lines.append("appeared: \(after)")
            case (.some(let before), nil):
                lines.append("disappeared: \(before)")
            case (.some(let before), .some(let after)) where before != after:
                lines.append("changed:\n  before: \(before)\n  after:  \(after)")
            default:
                break
            }
        }
        return lines
    }
}
