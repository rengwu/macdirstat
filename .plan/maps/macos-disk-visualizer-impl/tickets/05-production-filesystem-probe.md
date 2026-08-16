---
type: task
blocked_by: [04]
undermined_by: []
claimed_by: sc7909dd13048
claimed_at: 2026-08-16T11:22:27Z
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

## Answer

The engine runs on a real filesystem and is proven read-only there. `ScanCore` gained the
production `FileManagerDirectoryProbe`; `ScanCoreTestSupport` gained
`TemporaryFileSystemFixture`, `FilesystemFingerprint` and the §9.2 fixture builder; and
`ScanCoreFileSystemTests` — the placeholder is gone — now holds **61 tests** across five
suites. `Scripts/verify-scaffold.sh` exits 0 with every step PASS, including the
`MacDirStat-CI` plan, the `CI-ThreadSanitizer` plan and the universal Release build; 127
tests across the two packages.

**What was built**

- **`FileManagerDirectoryProbe`** — one `contentsOfDirectory(at:includingPropertiesForKeys:)`
  per directory, which prefetches every key onto the URLs it returns, so the
  `resourceValues` that follows reads what was already fetched: one batched metadata fetch
  per directory, no entry read twice (§8.2). No `.skipsHiddenFiles`, no deep enumerator,
  no package skipping. `volumeInfo` is read once, for the root only.
- **`TemporaryFileSystemFixture`** — a fresh, prefix-named child of the resolved temporary
  directory carrying a UUID sentinel. Cleanup refuses on four counts, each tripped on
  purpose by a test: the path is the temporary directory itself, is outside it, is not
  named like a fixture, has no sentinel, or has another fixture's sentinel. It records the
  mode it took off the `chmod 000` directory and puts it back before removing anything —
  which is why `test_cleanUpRestoresPermissionsBeforeRemoving` succeeding *is* the proof
  that restoration happened, since that tree cannot be removed as it stands.
- **`FilesystemFingerprint`** — relative path, kind, logical length, mode, mtime (to the
  nanosecond), symlink target, inode, link count, and an FNV-1a hash of files ≤ 4 KiB.
  Access time excluded; the multi-GiB sparse files are never read. `differences(from:)`
  names the file that moved instead of dumping two trees.
- **The §9.2 fixture** — a 3 GiB sparse hidden file (allocated ≈ 0), a symlink to it, a
  broken symlink, an ancestor-loop symlink, `link(2)` names `a-owner.bin`/`z-duplicate.bin`
  plus a third in a sibling directory **outside** the scan root, a real `Fixture.app` with
  a 1 GiB sparse resource, a 64-directory chain, a `chmod 000` directory with a file inside
  it and a readable sibling, an empty file, an `.alias`-named ordinary file, one file per
  palette group, an xattr + resource-fork file, two equal-sized names, and a `clonefile`
  clone where the host volume allows one.

**Judgment calls**

1. **The scan root is a *child* of the owned directory, not the owned directory itself.**
   The ownership sentinel and the out-of-scope hard link have to exist somewhere, and
   anywhere inside the scanned tree would have made the expected totals a fiction. Putting
   them beside it costs nothing and buys a stronger proof: the fingerprint covers the whole
   owned directory, so a scan that reached out of scope — or that touched the third name of
   the hard-linked inode — is a difference too.
2. **The fingerprint opens the unreadable directory to look inside, and locks it again.**
   Describing a `chmod 000` directory only from the outside would leave its contents outside
   the read-only proof, which is where a bug would be least visible. It `lstat`s first, so
   the recorded mode is the one the filesystem reported and not one the harness remembered;
   a scan that changed the mode still shows up. The restore is queued behind the whole
   subtree on the walk's own stack, so the window is exactly the subtree and no longer.
3. **The `lstat` fallback leaves identity and volume `nil`.** When an entry's resource
   values cannot be read at all, `lstat` still gives a kind and a length — but a
   `dev`/`inode` identity built by hand would not compare equal to the opaque ones every
   other entry carries, and a hard link that failed to match its owner would be counted
   **twice**. `nil` means "own your bytes, and descend", which is the conservative
   direction in both cases. An entry that has vanished entirely keeps its name, no kind and
   no size: nothing is guessed.
4. **A volume fact that cannot be read is the permissive one.** `volumeIsLocal == nil`
   reads as local and `volumeSupportsHardLinks == nil` as supported. Refusing an eligible
   root over an unreadable key is the worse error, and it is the same reasoning §3.3 already
   applies to an unknown volume identifier at the boundary check.
5. **The fingerprint gets a positive control.** A comparison that cannot fail proves
   nothing about the scan that passed it, so one test changes a byte without changing a
   length, adds a file, removes a file and changes a mode, and asserts all four — plus the
   containing directory's own moved mtime, which is why a scan that wrote *anything* could
   not hide behind an unchanged file list.

**Two findings**

- **`startAccessingSecurityScopedResource()` returns `true` for every ordinary local URL
  here** — the temporary directory, the home directory, `/` — in an unsandboxed process on
  macOS 27. Ticket 03 recorded `false`. Both readings destroy the research asset's rule
  (§2.1: refuse a root whose scope is refused): one would reject most real roots, the other
  would accept everything. Ticket 03's conclusion stands and is now better founded — the
  call reports only whether a *stop* is owed. What a **sandboxed** app answers is still
  unmeasured, and stays with ticket 07; the map's patch has been reworded accordingly.
- **The vanished-file/vanished-directory asymmetry, demonstrated.** With both removed
  immediately after the root's listing, the directory is caught (`.disappeared`, Unreadable,
  ancestors Incomplete) because its own listing is a second call, while the file is still
  counted at the length that listing reported. §3.5 calls live change best-effort, so this
  is the honest reading rather than a defect — and it is now a passing test rather than an
  argument. The map patch it was recorded under is cleared.

**Omitted deliberately**

No real-filesystem case crosses a volume boundary or exercises cloud materialization: one
would need a mount, which this ticket forbids, and the other a provider. Both stay
scripted, where they are already proven, and the clone is the same shape — the real
`clonefile` case skips itself on a volume that cannot clone, while the scripted
distinct-identity case remains mandatory everywhere. The scale rungs and the opt-in
`FixtureBuilder` are ticket 10's; sandbox entitlements and the chooser's root policy are
ticket 07's; nothing here is wired into the app.
