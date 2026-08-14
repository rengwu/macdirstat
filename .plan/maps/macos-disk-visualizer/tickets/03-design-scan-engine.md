---
type: research
blocked_by: [01, 02]
undermined_by: []
assets: [03-scan-engine-design.md]
claimed_by: see633094ffc9
claimed_at: 2026-08-14T07:01:56Z
---

# Design the cancellable scan engine

## Question

How should the scanner traverse large directory trees, compute aggregate sizes, publish useful progress before the total workload is known, remain responsive, and stop promptly without violating the settled filesystem semantics? Define ownership and lifetime of scan state, bounded concurrency or serialization, error collection, incremental result delivery, and cancellation checkpoints.

## Done when

The answer specifies the scanner's data model and event/state contract, traversal and aggregation algorithm, cancellation behavior, progress semantics, error policy, resource bounds, and test seams precisely enough to implement without additional architectural decisions.

## Answer

**The scan engine is an `actor Scanner` in the Foundation-only `ScanCore` package, exposing `scan(ScanRequest) -> AsyncStream<ScanEvent>`. Traversal is serial, iterative depth-first over an explicit stack, using shallow `contentsOfDirectory` with prefetched URL resource keys and its own per-subdirectory device-boundary check.** Full design — data model, event/state contract, algorithm, cancellation, progress, error/exclusion policy, resource bounds, and test seams — with every API claim verified against Apple's documentation metadata, is in `assets/03-scan-engine-design.md`.

**Why serial, shallow, self-recursing traversal (the load-bearing decisions).**

- **Shallow listing, not the deep enumerator.** Apple's `FileManager.enumerator(at:…)` *"traverses the mount point"* when it meets one, which would silently leave the root device and violate Ticket #01's "stay on the root's filesystem device." So the engine recurses itself over shallow `contentsOfDirectory(at:includingPropertiesForKeys:options:)` and descends into a subdirectory only when its `volumeIdentifierKey` equals the root's (compared via `isEqual`) — which also makes nested mounted volumes out-of-scope for free.
- **Serial, single-threaded on the actor's executor.** Ticket #01 defines hard-link ownership as "the first in-scope path encountered"; "first" is only well-defined under a deterministic order, so traversal uses a stable within-directory name sort and no traversal concurrency. Serial also removes all locking from the hot path (identity index, accumulators, ancestor roll-up) and matches single-device I/O reality. Parallelism is deferred with a defined seam, not designed out.
- **One measure: `fileSizeKey` (logical length), `Int64`,** rolled up incrementally to every ancestor so each open directory's total is live at all times; `totalFileAllocatedSizeKey` and any block/allocation figure are never read (Ticket #01).

**Data model / state ownership.** `final class ScanNode` (name-only, parent link, children, `ownBytes`/`subtreeBytes`, attribution, read-state, lifecycle). The `actor` solely owns the mutable tree, hard-link index, and accumulators for the scan's duration; the UI reads scalar `ProgressSnapshot`s and `TreeSnapshot`s built from **frozen** (immutable-once-complete) subtrees shared by reference — cheap incremental delivery with no deep copies, and race-free across the actor boundary. At terminal the frozen tree is handed to the `@MainActor` result model read-only.

**Hard links / clones / cloud.** Dedup by `fileResourceIdentifierKey` identity (Apple: equal iff same path or same inode on same filesystem) — indexed only for `linkCount > 1`, so the index is tiny; APFS clones have distinct identities and fall out as separate contributions automatically (Ticket #01). Cloud materialization is gated on `ubiquitousItemDownloadingStatusKey`: `.notDownloaded` items are omitted and counted as exclusions, never downloaded; `.downloaded`/`.current` are attributed normally.

**Event/state contract.** State machine `idle → scanning → completed | cancelled | failed`. `.failed` is emitted only for a pre-flight root-eligibility failure; every mid-scan filesystem problem is recorded and traversal continues. Exactly one terminal `.finished(ScanResult)` (reason `.completed` or `.cancelled`) or `.failed` per scan; `ScanResult` always carries a full immutable tree plus `completeness`, error summary, exclusion summary, and (volume scans) separate capacity/free.

**Progress before the total is known.** Indeterminate primary progress with live telemetry (attributed bytes, files/dirs seen, current path, elapsed, throughput); an *explicitly approximate* completion fraction only for whole-volume scans (bytes / volume-used), never a synthetic byte figure in the tree. Emissions are coalesced/throttled (~15 Hz scalars, ~4 Hz tree, configurable to 0/∞ for tests), never per file (Ticket #02).

**Cancellation.** Cooperative `Task.isCancelled`, checked per-directory and per-256-entry batch (worst-case sub-directory latency, independent of tree size). On cancel, still-open ancestors are marked incomplete, the tree is frozen and fully retained/browsable, and a final exact snapshot plus `.finished(.cancelled)` is emitted; `withTaskCancellationHandler` guarantees security-scoped access is released.

**Errors / bounds / tests.** Recoverable errors (unreadable dir/entry, disappearance, malformed metadata) never fail the scan and never guess sizes: the entry is marked Unreadable, ancestors Incomplete, and a capped summary is exposed — with no synthetic "Unknown" derived from physical usage (Ticket #01). Memory is dominated by the inherent node tree (bounded via name-only nodes; URLs rebuilt on demand); working set, hard-link index, and error details are all bounded; no file *contents* are ever read. The engine is tested headlessly via an injectable `DirectoryProbe` seam, injectable cadence/clock, and temp-dir fixtures covering every Ticket #01 acceptance case.

**Also settled here (Ticket #02 deferred it):** the root-eligibility predicate — exists, is a directory, `volumeIsLocalKey == true` (excludes network volumes), security-scoped access starts.

**Omitted / flagged.** Treemap layout over this node tree (Ticket #05) and view wiring/interaction refinement (Tickets #04/#05) are not designed here. **One residual gap flagged for a human:** on macOS 11 no first-party `URLResourceKey` reliably distinguishes a disk-image-backed volume selected *directly as the root* from an ordinary local volume (it reports `volumeIsLocalKey == true`); the recommendation is to accept it (it is genuinely local, read-only scanning is harmless), since network exclusion and the device boundary — the load-bearing safety rules — are fully enforced. See §2.1 of the asset.
