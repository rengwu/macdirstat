---
type: task
blocked_by: [04]
undermined_by: []
---

# Production FileManager probe + real-filesystem proof

## Question

Make the engine run against a real filesystem and prove it is read-only and correct there.
This is the production adapter behind the `DirectoryProbe` seam plus the disposable
real-tree fixture harness that validates every settled semantic on actual files. Fixed by
spec §5.1, §9.2 and the traceability tables in the planning map's ticket 07.

Build:

- The **production `FileManager` probe** implementing `DirectoryProbe` with prefetched URL
  resource keys, exposing listing and metadata only — no write/download/open-data method.
- **Security-scoped access** started at pre-flight root eligibility and released **exactly
  once** on every terminal path (success, failure, cancellation, replacement), provable by
  a spy adapter.
- **`TemporaryFileSystemFixture`**: creates a fresh child of the test temp directory,
  writes an ownership sentinel, scans with the production probe, and fingerprints
  before/after. Cleanup verifies both sentinel and resolved path, refuses any other
  directory, and restores permission bits even after a failed test.
- The **small real-filesystem fixture** (spec §9.2): sparse hidden file with a known
  logical length; a symlink to it, a broken symlink, and an ancestor-loop symlink; two
  `link(2)` hard links plus a third outside the root; a real package with sparse
  resources; a 64-directory chain; a `chmod 000` unreadable directory with a readable
  sibling (asserting non-root user and that listing really fails); an empty file, an
  `.alias`-named ordinary file, one file per palette group, an xattr/resource-fork file,
  equal-sized names for stable sorting; and, where supported, a `clonefile` APFS clone
  (host-capability supplementary; the scripted distinct-identity clone remains mandatory).

Run this as `ScanCoreFileSystemTests`, the "every change on macOS" gate.

## Done when

- The production probe drives a full scan of the real fixture and the before/after
  fingerprint (relative path, kind, logical length, mode, mtime, symlink target,
  inode/link count, small-content hashes; access time excluded) is **unchanged** — the
  read-only proof.
- Real fixtures confirm the ticket-03/04 semantics on actual files: sparse/hidden logical
  sizes, symlink zero-byte non-traversal and loop termination, hard-link ownership with
  owner path and the outside name absent, exact package rollup as one presented item, the
  64-chain traversing iteratively, and the `chmod 000` directory producing Unreadable +
  Incomplete without aborting the readable sibling.
- The security-scope spy shows access balanced exactly once on success, failure,
  cancellation, and replacement by a new scan.
- No test reads file contents through the scanner, invokes a cloud download, or
  mounts/unmounts a volume; the fixture cleanup provably refuses any non-owned path.
