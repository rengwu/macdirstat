import Foundation

/// What a fixture refuses to do, and why.
public enum FixtureError: Error, Equatable, CustomStringConvertible {
    /// The one that matters: cleanup would have deleted something the fixture
    /// does not own.
    case refusedToDelete(path: String, because: Refusal)
    case couldNotStage(path: String, errno: Int32)
    case couldNotFingerprint(path: String, errno: Int32)

    public enum Refusal: String, Equatable {
        case notInsideTheTemporaryDirectory
        case isTheTemporaryDirectoryItself
        case notNamedLikeAFixture
        case sentinelMissing
        case sentinelBelongsToAnotherFixture
    }

    public var description: String {
        switch self {
        case .refusedToDelete(let path, let because):
            return "refused to delete \(path): \(because.rawValue)"
        case .couldNotStage(let path, let code):
            return "could not stage \(path): errno \(code) (\(String(cString: strerror(code))))"
        case .couldNotFingerprint(let path, let code):
            return "could not fingerprint \(path): errno \(code) (\(String(cString: strerror(code))))"
        }
    }
}

/// A disposable, uniquely owned directory tree for the production-probe suite
/// (spec §9.2).
///
/// It creates a fresh child of the test temporary directory, writes an
/// **ownership sentinel** into it, and hands out that directory as the only
/// place a test may stage files. Nothing here ever touches an existing user
/// directory, and cleanup **refuses** any path that is not provably this
/// fixture's own — a four-part check, each part of which a test can trip on
/// purpose.
///
/// Permission bits changed for a fixture case (the `chmod 000` directory) are
/// recorded and restored before removal, including after a failed test, so a
/// failure never leaves an undeletable tree behind.
public final class TemporaryFileSystemFixture {
    /// The file whose presence and contents mark a directory as this fixture's.
    public static let sentinelName = ".macdirstat-fixture-sentinel"
    /// Every fixture directory carries this prefix, so an accidental path is
    /// rejected on its name alone before anything else is inspected.
    public static let namePrefix = "MacDirStatFixture-"

    /// The owned directory. Fully resolved, so no `/var` → `/private/var`
    /// mismatch can make an ownership check ambiguous.
    public let directory: URL
    private let token: String
    /// Directories whose mode this fixture changed, with the mode to put back.
    private var modesToRestore: [(url: URL, mode: mode_t)] = []
    private var isCleanedUp = false

    public init(label: String = "fixture") throws {
        let base = Self.temporaryDirectory
        let token = UUID().uuidString
        let directory = base.appendingPathComponent(
            Self.namePrefix + label + "-" + token, isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        self.directory = directory
        self.token = token
        try Data(token.utf8).write(to: directory.appendingPathComponent(Self.sentinelName))
    }

    deinit {
        // A test that never reached its teardown still must not leave a
        // mode-000 directory behind.
        restorePermissions()
    }

    /// The base every fixture lives under, fully resolved — the boundary
    /// cleanup refuses to step outside of.
    public static var temporaryDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).resolvingSymlinksInPath()
    }

    // MARK: - Staging

    /// Removes a directory's permission bits, remembering what they were.
    ///
    /// This is the only mutation a fixture makes outside creating its own
    /// files, and it is the reason cleanup restores before it removes.
    public func makeUnreadable(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw FixtureError.couldNotStage(path: url.path, errno: errno)
        }
        modesToRestore.append((url, status.st_mode & 0o7777))
        guard chmod(url.path, 0o000) == 0 else {
            throw FixtureError.couldNotStage(path: url.path, errno: errno)
        }
    }

    /// Puts back every mode this fixture changed. Idempotent, and safe to call
    /// from a teardown that runs after a failure.
    public func restorePermissions() {
        for (url, mode) in modesToRestore {
            _ = chmod(url.path, mode)
        }
    }

    // MARK: - Fingerprinting

    /// The before/after read-only proof (spec §9.2). Covers the whole owned
    /// directory — including anything staged *outside* the scan root, so a
    /// scan that reached out of scope would show up here too.
    public func fingerprint() throws -> FilesystemFingerprint {
        try FilesystemFingerprint.take(of: directory)
    }

    // MARK: - Cleanup

    public func cleanUp() throws {
        guard !isCleanedUp else { return }
        isCleanedUp = true
        restorePermissions()
        try Self.removeOwnedDirectory(at: directory, sentinelToken: token)
    }

    /// Deletes a directory **only** if it is provably a fixture's own.
    ///
    /// Four independent checks, in order of how cheap they are to state: the
    /// resolved path is inside the temporary directory and is not the
    /// temporary directory itself; the name carries the fixture prefix; a
    /// sentinel file is present; and that sentinel names this very fixture. A
    /// recursive delete is the one genuinely destructive thing this suite does,
    /// so it is guarded by the fixture's identity rather than by the caller
    /// having passed the right path.
    public static func removeOwnedDirectory(at url: URL, sentinelToken: String) throws {
        let resolved = url.resolvingSymlinksInPath()
        let temporary = temporaryDirectory

        func refuse(_ because: FixtureError.Refusal) -> FixtureError {
            .refusedToDelete(path: resolved.path, because: because)
        }

        guard resolved.path != temporary.path else {
            throw refuse(.isTheTemporaryDirectoryItself)
        }
        guard resolved.path.hasPrefix(temporary.path + "/") else {
            throw refuse(.notInsideTheTemporaryDirectory)
        }
        guard resolved.lastPathComponent.hasPrefix(namePrefix) else {
            throw refuse(.notNamedLikeAFixture)
        }

        let sentinel = resolved.appendingPathComponent(sentinelName)
        guard let contents = try? Data(contentsOf: sentinel) else {
            throw refuse(.sentinelMissing)
        }
        guard String(data: contents, encoding: .utf8) == sentinelToken else {
            throw refuse(.sentinelBelongsToAnotherFixture)
        }

        try FileManager.default.removeItem(at: resolved)
    }
}
