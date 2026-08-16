---
type: task
blocked_by: [03]
undermined_by: []
claimed_by: sc90916fa05ea
claimed_at: 2026-08-16T11:03:54Z
---

# ScanCore: identity, resilience & exclusion semantics

## Question

Complete the scan engine's measurement honesty: the filesystem-identity rules (hard links,
clones, packages) and the resilience/exclusion rules (recoverable errors, cloud gating,
bounded detail, volume capacity/free, live change). All of this is scripted-probe testable
and finishes the engine's semantic contract. Fixed by spec §3.4, §3.5, §5.7.

Add to the scan-engine package, on top of ticket 03's traversal:

**Identity semantics (spec §3.4):**
- **Hard-link dedup by filesystem identity**, with the identity index populated **only for
  `linkCount > 1`** and bypassed when the volume reports no hard-link support. Under the
  deterministic order the first in-scope path owns the bytes; later in-scope paths stay
  visible with **zero** attributed bytes, a "counted elsewhere" marker, and the owner path
  when available. Names outside the root are neither sought nor shown.
- **APFS clones counted separately** — distinct identities each contribute their ordinary
  logical length.
- **Packages measured recursively** during the scan so the aggregate is exact, while
  presented initially as one collapsed item/box (the detailed child hierarchy may be
  materialized lazily without changing the aggregate).

**Resilience & exclusions (spec §3.5, §5.7):**
- **Recoverable errors never abort and never guess sizes**: unreadable dir/entry,
  disappearance, malformed metadata → entry marked Unreadable, every affected ancestor
  Incomplete, size stays zero, siblings continue, `.completed` still reached, exact
  per-category counts. No synthetic "Unknown" derived from physical usage.
- **Bounded error detail**: retain up to 1,000 detailed records, then keep only the exact
  running total with a `truncated` flag.
- **Cloud materialization gating**: only `.downloaded`/`.current` items count; a
  `.notDownloaded` placeholder is omitted, has no node, and increments the exact exclusion
  count, with **no** download/network request; an unavailable/third-party status safely
  counts the present logical file.
- **Volume capacity/free carried separately** in the result — never turned into an
  attributed node byte count.
- **Live change is best-effort**: a vanished already-listed entry becomes a recoverable
  error; no second pass or automatic restart.

## Done when

- `ScanCoreTests` (scripted identities/statuses) prove: first stable path owns bytes;
  duplicate stays visible with owner path and zero bytes; an outside name is absent;
  distinct clone identities both count; the identity index is consulted only when link
  count > 1 and bypassed when unsupported.
- Package rollup is exact while the presentation stays a single item/box.
- Recoverable-error scripts show siblings continuing, Unreadable/Incomplete propagation,
  zero attributed size, `.completed` reached, and exact category counts; injecting 2,500
  failures yields exact total 2,500, first 1,000 detailed records, and `truncated == true`.
- Cloud scripts (`.current`, `.downloaded`, `.notDownloaded`, unavailable) count the first
  two, omit and count the placeholder, and safely count the unavailable one; a spy proves
  no download/open-data call occurs.
- Volume-mode results expose injected capacity/free with no `capacity - free` value
  reaching any node or formatter.
- A barrier probe proves disappearance is recoverable with no second pass or automatic
  restart.

## Answer

The scan engine's semantic contract is finished. `ScanCore` now dedups hard links by
filesystem identity, counts clones apart, measures packages through while presenting them
as one box, records recoverable errors with exact category counts and a bounded detail
list, gates cloud items on materialization without ever touching a placeholder, counts
policy exclusions apart from errors, and carries volume capacity/free as a fact of its own.
**67 tests in `ScanCoreTests`** (26 new), and `Scripts/verify-scaffold.sh` exits 0 with
every step PASS — including the `MacDirStat-CI` plan, the `CI-ThreadSanitizer` plan, and
the universal Release build.

**What was built**

- **`HardLinkIndex`** — its own type rather than a dictionary inside the session, because
  the load-bearing claim about it is a *memory* claim ("only multiply-linked inodes are
  indexed", §5.7) and no end-to-end assertion can see an index's size. `claim(_:for:)`
  returns `.notALink` / `.owner` / `.duplicate(of:)`, and returns `.notALink` without
  touching storage unless `linkCount > 1`, an identity is readable, and the volume supports
  hard links at all. Tested both ways: directly, for what it holds; and through a whole
  scan, for who owns the bytes.
- **`ScanDiagnostics`** with `ErrorSummary` (exact `byCategory` + `total`, the first
  `maxDetailedErrors` records, `truncated`) and `ExclusionSummary` (`byReason`). The
  budget is checked *before* a path is built, so past the cap an error costs one integer
  increment and no allocation — which is the entire point of capping it. `ScanResult` now
  carries both, and `ScanOptions.maxDetailedErrors` defaults to 1,000.
- **Three error categories, told apart by the error itself**: a listing that throws
  "no such file" is `.disappeared` (live change), anything else is `.unreadableDirectory`,
  and an unreadable `fileSize` is `.unreadableEntry`. The `isMissing` predicate that
  splits them is the same one pre-flight already used to tell `.rootMissing` from
  `.rootAccessDenied`, now shared.
- **Cloud gating in the entry loop**, before a node exists: a `.notDownloaded` entry gets
  no node, increments `exclusions[.remoteOnlyCloud]`, and is never named in another probe
  request. A `nil` status — the third-party provider that surfaces nothing on macOS 11 —
  counts the present logical file, as §3.4 asks.
- **`ScanNode.initiallyPresentedChildren`** — `[]` for a package, `children` otherwise.
  That one line is how "measured through, presented as one box" is expressed without
  putting UI policy in the engine: the real children are in the tree and already summed, so
  materializing them later cannot move the aggregate. The test asserts exactly that.

**Judgment calls**

1. **Errors and exclusions are different things, and only errors touch completeness.** A
   crossed volume boundary and an omitted remote-only placeholder leave every ancestor
   `.complete` and the result `.exact`. Nothing went wrong — a policy chose to skip them —
   and a result that cried Incomplete over a mounted volume the user never asked about
   would be the dishonest one. This is the asset's §8 reading, made explicit in code.
2. **An entry whose size cannot be read never enters the identity index.** If it did, it
   would own the inode at zero bytes and zero out a *later* name whose size reads fine —
   turning one unreadable entry into a lost file. It is recorded as `.unreadableEntry` and
   left out of the index instead.
3. **A deduplicated name is still one item.** It rolls up zero bytes and one file, so the
   tree's Items column counts both names of an inode while its Size column counts the
   bytes once. Zero bytes is the spec's rule; invisibility is not.
4. **Cloud gating applies to directories too.** A dataless folder placeholder is omitted
   and never listed — listing it is precisely what would fetch it. Uniform, and proven by
   the request log.
5. **`ErrorRecord.message` is diagnostic text, not UI copy.** The engine hands back the
   filesystem's own `localizedDescription` where there was an error object and a short
   English fallback where there was not. `category` is the field the UI branches on and
   localizes from; ticket 09 owns the wording.

**One consequence worth knowing**

A vanished *file* is not detectable. An entry is described entirely by its parent's
listing and never read twice (§8.2), so only a directory — whose listing is a second call
— can come back "no such file". A file that disappears after being listed is still counted
at its listed size. §3.5 calls live change best-effort and explicitly does not promise a
snapshot, so this is the honest reading of the rule rather than a gap in it; it is recorded
on the map for ticket 05, where a real filesystem can demonstrate it.

**Omitted deliberately**

The production `FileManager` probe and real-filesystem fixtures stay ticket 05's;
`ScanCoreFileSystemTests` still holds only its scaffold placeholder. `ProgressSnapshot`
gained no error or exclusion counters — the summaries are terminal facts per §5.3, and
progress-card copy is ticket 09's. Whether a *root* that is itself a dataless placeholder
should be refused is the chooser's question, not the engine's, and stays with ticket 07.
