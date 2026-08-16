import Foundation

/// The small real-filesystem fixture (spec §9.2) and the manifest that says
/// what a correct scan of it must produce.
///
/// The manifest's expected totals are written from the **semantics** — a
/// symlink contributes zero, a second name for an inode contributes zero, an
/// unreadable directory contributes nothing rather than a guess, a package is
/// measured through — and not from anything the engine computed. It is the
/// same shape of independent oracle the scripted suite uses, applied to a tree
/// that really exists.
public struct RealFixtureManifest {
    /// The directory a test scans. A **child** of the fixture's owned
    /// directory, so the ownership sentinel and the out-of-scope hard link are
    /// staged where a correct scan will never see them.
    public let scanRoot: URL
    /// Sibling of `scanRoot`, holding the third name of the hard-linked inode.
    public let outsideDirectory: URL
    public let lockedDirectory: URL
    public let packageDirectory: URL
    /// Whether the host volume could stage an APFS clone. The scripted
    /// distinct-identity clone case is mandatory everywhere; this one is a
    /// supplementary host-capability check (spec §9.2).
    public let supportsCloning: Bool
    /// The byte length actually written to `Fixture.app/Contents/Info.plist`.
    public let infoPlistBytes: Int64

    // MARK: - What was staged

    /// `.hidden.bin` — sparse, so a multi-GiB logical length costs no disk.
    public static let hiddenSparseBytes: Int64 = 3 * 1024 * 1024 * 1024
    /// `Fixture.app/Contents/Resources/Sparse.bin`, likewise sparse.
    public static let packageSparseBytes: Int64 = 1024 * 1024 * 1024
    /// The inode reached by `a-owner.bin`, `z-duplicate.bin` and the name
    /// outside the scan root.
    public static let hardLinkBytes: Int64 = 5
    public static let aliasBytes: Int64 = 12
    /// `equal-a.bin` and `equal-b.bin`, deliberately identical in size.
    public static let equalSizedBytes: Int64 = 64
    /// `xattr.bin`'s data fork. Its extended attributes and resource fork are
    /// **not** content and must not appear in any total.
    public static let xattrDataForkBytes: Int64 = 100
    public static let resourceForkBytes = 1024
    public static let chainLeafBytes: Int64 = 7
    public static let readableSiblingBytes: Int64 = 11
    /// Inside the `chmod 000` directory: real bytes that a correct scan can
    /// neither read nor guess.
    public static let unreadableInsideBytes: Int64 = 3
    /// One file per palette group, sized 1…11 bytes.
    public static let paletteFileNames = [
        "archive.zip", "audio.aiff", "code.swift", "data.json", "disk.dmg",
        "document.pdf", "font.ttf", "image.png", "mystery.xyz", "system.plist",
        "video.mov"
    ]
    /// The number of directories in the chain — deeper than the depth-20 stress
    /// shape, and proof the traversal is iterative rather than recursive.
    public static let chainDepth = 64

    public static var paletteTotalBytes: Int64 {
        (1...Int64(paletteFileNames.count)).reduce(0, +)
    }

    // MARK: - What a correct scan produces

    /// Every byte a correct scan attributes, and no others.
    public var expectedAttributedBytes: Int64 {
        var total: Int64 = 0
        total += Self.hiddenSparseBytes          // logical length, not allocated blocks
        total += Self.hardLinkBytes              // a-owner.bin owns the inode…
                                                 // …z-duplicate.bin adds zero, and the
                                                 // third name is outside the root
        if supportsCloning { total += Self.hardLinkBytes }  // a clone is its own inode
        total += Self.aliasBytes                 // an `.alias`-named ordinary file is ordinary
        total += 2 * Self.equalSizedBytes
        total += Self.xattrDataForkBytes         // xattr/resource-fork bytes are not content
        total += infoPlistBytes + Self.packageSparseBytes   // the package is measured through
        total += Self.chainLeafBytes
        total += Self.paletteTotalBytes
        total += Self.readableSiblingBytes
        // Contributing nothing, on purpose: three symlinks, the empty file, and
        // everything under the unreadable directory.
        return total
    }

    /// Regular files, counted the way the engine counts them — a deduplicated
    /// name is still one item, a symlink is not a file, and nothing inside the
    /// unreadable directory was ever seen.
    public var expectedFileCount: Int64 {
        var count: Int64 = 8    // .hidden.bin a-owner.bin z-duplicate.bin empty.bin
                                // equal-a.bin equal-b.bin legacy.alias xattr.bin
        if supportsCloning { count += 1 }
        count += 2              // Info.plist, Sparse.bin
        count += 1              // the chain's leaf
        count += Int64(Self.paletteFileNames.count)
        count += 1              // readable-sibling/sibling.bin
        return count
    }

    /// Directories the traversal enters or names, including the root and the
    /// package it measures through.
    public var expectedDirectoryCount: Int64 {
        1                               // scan-root
            + 3                         // Fixture.app / Contents / Resources
            + Int64(Self.chainDepth)    // chain-01 … chain-64
            + 1                         // kinds
            + 1                         // locked
            + 1                         // readable-sibling
    }

    /// The owning path of the hard-linked inode, as `ScanNode.pathComponents()`
    /// reports it: root first.
    public var hardLinkOwnerPath: [String] {
        [scanRoot.lastPathComponent, "a-owner.bin"]
    }

    public var chainLeafRelativePath: String {
        (1...Self.chainDepth).map { String(format: "chain-%02d", $0) }.joined(separator: "/")
            + "/leaf.bin"
    }
}

/// Builds the fixture of spec §9.2 beneath a `TemporaryFileSystemFixture`.
public enum RealFilesystemFixture {
    public static func build(in fixture: TemporaryFileSystemFixture) throws -> RealFixtureManifest {
        let owned = fixture.directory
        let root = owned.appendingPathComponent("scan-root", isDirectory: true)
        let outside = owned.appendingPathComponent("outside", isDirectory: true)
        try makeDirectory(root)
        try makeDirectory(outside)

        // --- a sparse hidden file, and the three symlinks -------------------
        // Sparse: `ftruncate` gives a multi-GiB *logical* length with no
        // allocated blocks, which is exactly the case that separates "logical
        // content bytes" from "space on disk" (spec §3.1).
        let hidden = root.appendingPathComponent(".hidden.bin")
        try makeSparseFile(hidden, length: RealFixtureManifest.hiddenSparseBytes)

        try makeSymlink(at: root.appendingPathComponent("link-to-hidden"), to: hidden.path)
        try makeSymlink(at: root.appendingPathComponent("broken-link"),
                        to: root.appendingPathComponent("nothing-here.bin").path)
        // Points back at its own ancestor: if anything ever followed a link,
        // the traversal would not terminate.
        try makeSymlink(at: root.appendingPathComponent("loop-link"), to: root.path)

        // --- hard links: two in scope, one outside --------------------------
        let owner = root.appendingPathComponent("a-owner.bin")
        try makeFile(owner, length: RealFixtureManifest.hardLinkBytes)
        try makeHardLink(at: root.appendingPathComponent("z-duplicate.bin"), to: owner)
        try makeHardLink(at: outside.appendingPathComponent("x-outside-link.bin"), to: owner)

        // --- an APFS clone, where the host volume can make one ---------------
        let clone = root.appendingPathComponent("clone.bin")
        let supportsCloning = clonefile(owner.path, clone.path, 0) == 0

        // --- a real package, measured through, presented as one item --------
        let package = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let contents = package.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try makeDirectory(package)
        try makeDirectory(contents)
        try makeDirectory(resources)
        let infoPlist = Data(Self.infoPlistText.utf8)
        try infoPlist.write(to: contents.appendingPathComponent("Info.plist"))
        try makeSparseFile(resources.appendingPathComponent("Sparse.bin"),
                           length: RealFixtureManifest.packageSparseBytes)

        // --- a 64-directory chain -------------------------------------------
        var chain = root
        for level in 1...RealFixtureManifest.chainDepth {
            chain = chain.appendingPathComponent(String(format: "chain-%02d", level), isDirectory: true)
            try makeDirectory(chain)
        }
        try makeFile(chain.appendingPathComponent("leaf.bin"),
                     length: RealFixtureManifest.chainLeafBytes)

        // --- the remaining leaves --------------------------------------------
        try makeFile(root.appendingPathComponent("empty.bin"), length: 0)
        try makeFile(root.appendingPathComponent("legacy.alias"),
                     length: RealFixtureManifest.aliasBytes)
        try makeFile(root.appendingPathComponent("equal-a.bin"),
                     length: RealFixtureManifest.equalSizedBytes)
        try makeFile(root.appendingPathComponent("equal-b.bin"),
                     length: RealFixtureManifest.equalSizedBytes)

        let xattrFile = root.appendingPathComponent("xattr.bin")
        try makeFile(xattrFile, length: RealFixtureManifest.xattrDataForkBytes)
        try setExtendedAttribute("com.macdirstat.fixture", on: xattrFile, byteCount: 32)
        try setExtendedAttribute("com.apple.ResourceFork", on: xattrFile,
                                 byteCount: RealFixtureManifest.resourceForkBytes)

        let kinds = root.appendingPathComponent("kinds", isDirectory: true)
        try makeDirectory(kinds)
        for (index, name) in RealFixtureManifest.paletteFileNames.enumerated() {
            try makeFile(kinds.appendingPathComponent(name), length: Int64(index + 1))
        }

        // --- an unreadable directory next to a readable sibling -------------
        let sibling = root.appendingPathComponent("readable-sibling", isDirectory: true)
        try makeDirectory(sibling)
        try makeFile(sibling.appendingPathComponent("sibling.bin"),
                     length: RealFixtureManifest.readableSiblingBytes)

        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try makeDirectory(locked)
        try makeFile(locked.appendingPathComponent("unreachable.bin"),
                     length: RealFixtureManifest.unreadableInsideBytes)
        // Last, so everything beneath it is already staged. The fixture records
        // the mode and puts it back at cleanup.
        try fixture.makeUnreadable(locked)

        return RealFixtureManifest(
            scanRoot: root,
            outsideDirectory: outside,
            lockedDirectory: locked,
            packageDirectory: package,
            supportsCloning: supportsCloning,
            infoPlistBytes: Int64(infoPlist.count)
        )
    }

    private static let infoPlistText = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
    \t<key>CFBundleIdentifier</key>
    \t<string>com.macdirstat.fixture</string>
    </dict>
    </plist>

    """

    // MARK: - Staging primitives

    private static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// Content varies with length, so a fingerprint's content hash would notice
    /// a file whose bytes changed while its length did not.
    private static func makeFile(_ url: URL, length: Int64) throws {
        let filler = UInt8(truncatingIfNeeded: length &+ 1)
        try Data(repeating: filler, count: Int(length)).write(to: url)
    }

    private static func makeSparseFile(_ url: URL, length: Int64) throws {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            throw FixtureError.couldNotStage(path: url.path, errno: errno)
        }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(length)) == 0 else {
            throw FixtureError.couldNotStage(path: url.path, errno: errno)
        }
    }

    private static func makeSymlink(at url: URL, to target: String) throws {
        guard symlink(target, url.path) == 0 else {
            throw FixtureError.couldNotStage(path: url.path, errno: errno)
        }
    }

    /// `link(2)` — a second name for one inode, which is the only way to stage
    /// the case hard-link deduplication exists for.
    private static func makeHardLink(at url: URL, to target: URL) throws {
        guard link(target.path, url.path) == 0 else {
            throw FixtureError.couldNotStage(path: url.path, errno: errno)
        }
    }

    private static func setExtendedAttribute(_ name: String, on url: URL, byteCount: Int) throws {
        let bytes = [UInt8](repeating: 0xA5, count: byteCount)
        guard setxattr(url.path, name, bytes, byteCount, 0, 0) == 0 else {
            throw FixtureError.couldNotStage(path: url.path, errno: errno)
        }
    }
}
