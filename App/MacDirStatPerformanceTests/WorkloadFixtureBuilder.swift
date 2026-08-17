import Darwin
import Foundation
import ScanCore

/// Materializes a generated workload onto a real disk, as sparse files.
///
/// The lazy probe answers a listing from arithmetic, which is what makes the
/// heavy rungs measurable at all — but it also means the heavy rungs never
/// touch `FileManager`, never build a `URL` with cached resource values, and
/// never allocate a single Foundation object per entry. Those are exactly the
/// costs a real scan pays, so a suite made only of scripted rungs can be green
/// while the shipping app is not.
///
/// Hence this: the same manifest, on the same generator and seed, written to a
/// directory the caller **explicitly supplies**, and scanned through the
/// production `FileManagerDirectoryProbe`. Sparse files give multi-gigabyte
/// content lengths for no allocated blocks (spec §9.2), so the disk cost is
/// inodes and directory entries rather than bytes.
///
/// Since ticket 13 that has a second consequence worth stating: a materialized
/// rung is a tree that **occupies nothing**. The engine measures blocks, so its
/// attributed total here is zero by construction and the manifest's byte total
/// appears in the content length carried beside it. That is not a limitation of
/// the fixture — it is the sparse case at two hundred thousand entries.
///
/// It is opt-in and out of the normal loop, because it writes to a disk and a
/// test suite that writes to a disk should have been asked to.
enum WorkloadFixtureBuilder {
    /// Written into the supplied directory and checked again before anything is
    /// removed. Ticket 05's discipline, restated here because
    /// `ScanCoreTestSupport` is a package-internal target with no product and
    /// the app's test targets cannot link it.
    static let sentinelName = ".macdirstat-performance-fixture"

    struct Refusal: Error, CustomStringConvertible {
        let description: String
    }

    /// A materialized fixture that knows how to unmake itself, and refuses to
    /// unmake anything else.
    final class Fixture {
        /// The directory the caller supplied, which holds the sentinel.
        let container: URL
        /// The scan root — a *child* of the container, so the sentinel is never
        /// inside the tree whose totals are being asserted.
        let root: URL
        let sentinel: UUID
        let manifest: WorkloadManifest

        init(container: URL, root: URL, sentinel: UUID, manifest: WorkloadManifest) {
            self.container = container
            self.root = root
            self.sentinel = sentinel
            self.manifest = manifest
        }

        /// Removes the materialized tree, after re-reading the sentinel it
        /// wrote. A directory that no longer carries this fixture's UUID is
        /// somebody else's and is left exactly where it is.
        func remove() throws {
            let sentinelURL = container.appendingPathComponent(WorkloadFixtureBuilder.sentinelName)
            let recorded = try? String(contentsOf: sentinelURL, encoding: .utf8)
            guard recorded?.trimmingCharacters(in: .whitespacesAndNewlines) == sentinel.uuidString else {
                throw Refusal(description: """
                    refusing to remove \(container.path): its sentinel is \
                    \(recorded ?? "missing"), not \(sentinel.uuidString)
                    """)
            }
            try FileManager.default.removeItem(at: root)
            try FileManager.default.removeItem(at: sentinelURL)
        }
    }

    /// - Parameter container: an existing, **empty** directory the caller
    ///   chose. It is never created here: naming the directory is the caller's
    ///   act of consent, and a builder that created its own would make that
    ///   consent theoretical.
    static func materialize(_ workload: ScaleWorkload, into container: URL) throws -> Fixture {
        try refuseUnsuitable(container)

        let sentinel = UUID()
        try sentinel.uuidString.write(
            to: container.appendingPathComponent(sentinelName),
            atomically: true,
            encoding: .utf8
        )

        let manifest = workload.manifest
        let root = container.appendingPathComponent("scan-root-\(manifest.rung)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        // Iterative, for the same reason the engine is: the deep-chain rung is
        // 64 levels and nothing here should be bounded by the stack.
        var stack: [[String]] = [[]]
        while let components = stack.popLast() {
            var directory = root
            for component in components { directory.appendPathComponent(component) }

            for entry in try workload.entries(at: components) {
                let url = directory.appendingPathComponent(entry.name)
                if entry.isDirectory {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                    stack.append(components + [entry.name])
                } else {
                    try createSparseFile(at: url, logicalLength: entry.contentLength ?? 0)
                }
            }
        }

        return Fixture(container: container, root: root, sentinel: sentinel, manifest: manifest)
    }

    /// A file with a content length and (on a filesystem that supports holes)
    /// no allocated blocks. `ftruncate` is the whole mechanism: nothing is
    /// written, so nothing is stored, `fileSizeKey` still reports the length the
    /// manifest declared, and `fileAllocatedSizeKey` reports zero.
    private static func createSparseFile(at url: URL, logicalLength: Int64) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        }
        guard descriptor >= 0 else {
            throw Refusal(description: "could not create \(url.path): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        if logicalLength > 0, ftruncate(descriptor, off_t(logicalLength)) != 0 {
            throw Refusal(description: "could not size \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Four refusals, each of which has to hold before a single file is
    /// written: the directory exists, is a directory, is not one of the places
    /// nothing should ever be staged, and is empty.
    private static func refuseUnsuitable(_ container: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: container.path, isDirectory: &isDirectory) else {
            throw Refusal(description: "\(container.path) does not exist — create it yourself first")
        }
        guard isDirectory.boolValue else {
            throw Refusal(description: "\(container.path) is not a directory")
        }

        let resolved = container.resolvingSymlinksInPath().standardizedFileURL.path
        let forbidden = [
            "/",
            NSHomeDirectory(),
            manager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        ]
        guard !forbidden.contains(resolved) else {
            throw Refusal(description: "refusing to stage a fixture directly in \(resolved)")
        }

        let existing = try manager.contentsOfDirectory(atPath: container.path)
        guard existing.isEmpty else {
            throw Refusal(description: """
                refusing to stage a fixture in \(container.path): it already holds \
                \(existing.count) item(s). Supply an empty directory.
                """)
        }
    }
}
