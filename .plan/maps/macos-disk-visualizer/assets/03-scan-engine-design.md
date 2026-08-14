# Scan-engine design — cancellable directory scanner for the macOS disk visualizer

Design backing **Ticket #03 — Design the cancellable scan engine**
(`.plan/maps/macos-disk-visualizer/tickets/03-design-scan-engine.md`).

**Question.** How should the scanner traverse large directory trees, compute aggregate
sizes, publish useful progress before the total workload is known, remain responsive, and
stop promptly without violating the settled filesystem semantics — defining ownership and
lifetime of scan state, bounded concurrency or serialization, error collection, incremental
result delivery, and cancellation checkpoints?

This document fixes the engine's data model, event/state contract, traversal and
aggregation algorithm, cancellation behavior, progress semantics, error policy, resource
bounds, and test seams precisely enough to implement without further architectural
decisions. It lives in `ScanCore` (the Foundation-only package established by Ticket #02),
and honors the filesystem semantics settled in Ticket #01.

Every platform/API claim below is verified against Apple's machine-readable documentation
metadata (the `…/tutorials/data/documentation/…json` feed that backs each
`developer.apple.com/documentation/…` page and carries the same `@available` annotations
the compiler enforces). Versions captured **2026-08-14**. Deployment floor is **macOS 11.0**
(Ticket #02); every API used below is available at or below that floor.

---

## 0. Verified primary-source facts this design rests on

| Fact used by the design | Min macOS | Source |
| --- | --- | --- |
| `URLResourceKey.fileSizeKey` — *"the file's size, in bytes"*, i.e. logical length, as `NSNumber`. | 10.6 | [filesizekey](https://developer.apple.com/documentation/foundation/urlresourcekey/filesizekey) |
| `URLResourceKey.totalFileAllocatedSizeKey` — *"total allocated size … includes the size of any file metadata"* (the on-disk measure we **exclude**). | 10.7 | [totalfileallocatedsizekey](https://developer.apple.com/documentation/foundation/urlresourcekey/totalfileallocatedsizekey) |
| `URLResourceKey.fileResourceIdentifierKey` — unique id (`id`); *"Two resources are equal if they have the same file-system path or if their paths link to the same inode on the same file system"*; compare with `isEqual(_:)`; **not persistent across restarts**. | 10.7 | [fileresourceidentifierkey](https://developer.apple.com/documentation/foundation/urlresourcekey/fileresourceidentifierkey) |
| `URLResourceKey.linkCountKey` — hard-link count as `NSNumber`; `1` means a single link. | 10.6 | [linkcountkey](https://developer.apple.com/documentation/foundation/urlresourcekey/linkcountkey) |
| `URLResourceKey.volumeIdentifierKey` — unique volume id (`id`); *"determine whether two file system resources are on the same volume"* via `isEqual(_:)`; not persistent across restarts. | 10.7 | [volumeidentifierkey](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeidentifierkey) |
| `URLResourceKey.volumeIsLocalKey` — *"whether the volume is on a local device"* (`false` ⇒ network-mounted). | 10.7 | [volumeislocalkey](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeislocalkey) |
| `URLResourceKey.volumeIsInternalKey` — *"connected to an internal bus"*; `nil` if undeterminable. | 10.7 | [volumeisinternalkey](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeisinternalkey) |
| `URLResourceKey.volumeSupportsHardLinksKey` — whether the volume supports hard links. | 10.6 | [volumesupportshardlinkskey](https://developer.apple.com/documentation/foundation/urlresourcekey/volumesupportshardlinkskey) |
| `URLResourceKey.isSymbolicLinkKey` / `isDirectoryKey` / `isRegularFileKey` / `isPackageKey` — item-kind booleans (`NSNumber`). `isPackage` ⇒ *"the resource is a file package."* | 10.6 / 10.6 / 10.6 / 10.6 | [issymboliclinkkey](https://developer.apple.com/documentation/foundation/urlresourcekey/issymboliclinkkey), [ispackagekey](https://developer.apple.com/documentation/foundation/urlresourcekey/ispackagekey) |
| `URLResourceKey.ubiquitousItemDownloadingStatusKey` → `URLUbiquitousItemDownloadingStatus` ∈ {`.notDownloaded`, `.downloaded`, `.current`}. `.notDownloaded` ⇒ *"has not been downloaded yet."* | 10.9 (key) | [ubiquitousitemdownloadingstatuskey](https://developer.apple.com/documentation/foundation/urlresourcekey/ubiquitousitemdownloadingstatuskey), [URLUbiquitousItemDownloadingStatus](https://developer.apple.com/documentation/foundation/urlubiquitousitemdownloadingstatus) |
| `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:options:)` — shallow listing; prefetches the requested resource values; does **not** resolve symlinks. | 10.6 | [contentsofdirectory(at:…)](https://developer.apple.com/documentation/foundation/filemanager/contentsofdirectory(at:includingpropertiesforkeys:options:)) |
| `FileManager.enumerator(at:…errorHandler:)` — **deep** enumerator; *"does not resolve symbolic links or mount points … nor recurse through them,"* but *"if … passed a directory on which another file system is mounted (a mount point), it traverses the mount point."* `errorHandler` returns `true` to continue / `false` to stop. | 10.10 | [enumerator(at:…)](https://developer.apple.com/documentation/foundation/filemanager/enumerator(at:includingpropertiesforkeys:options:errorhandler:)) |
| Swift Concurrency (`Task`, `actor`, `AsyncStream`, cooperative cancellation) back-deploys to macOS 10.15 via the bundled runtime. | 10.15 | [Xcode 13.2 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-13_2-release-notes) |
| `Task.isCancelled` — *"whether the task should stop executing"*; once `true` it *"remains `true` indefinitely."* Cancellation is cooperative. | 10.15 | [task/iscancelled](https://developer.apple.com/documentation/swift/task/iscancelled) |
| `withTaskCancellationHandler(operation:onCancel:)` — the `onCancel` handler is *"always and immediately invoked when the task is canceled."* | 10.15 | [withtaskcancellationhandler](https://developer.apple.com/documentation/swift/withtaskcancellationhandler(operation:oncancel:)) |

**Two facts drive the whole traversal shape:**

1. The deep `enumerator(at:…)` **traverses mount points**. Ticket #01 requires traversal to
   *stay on the root's filesystem device*. Therefore the engine must **not** delegate
   recursion to the deep enumerator; it does its own recursion with a per-subdirectory
   device-boundary check (§3).
2. `fileResourceIdentifierKey` equality already means *"same path or same inode on the same
   file system,"* which is exactly Ticket #01's hard-link identity — no `stat`/`getattrlist`
   is needed (§3.4).

---

## 1. Scope this ticket closes, and what it hands on

**Closes:** the scan-engine data model, event/state contract, traversal + aggregation
algorithm, cancellation, progress, error/exclusion policy, resource bounds, test seams, and
— because Ticket #02 explicitly deferred it here — the **root-eligibility predicate** (§2.1).

**Out of scope (deferred elsewhere):** treemap layout and its interaction (Ticket #05);
`NSOutlineView`/treemap view wiring and prototype-discovered interaction detail (Ticket #04);
signing/notarization/packaging (map). This document defines the engine and its public
surface; it does not define view code. It assumes the AppKit-first shell and the
`@MainActor` UI-update boundary from Ticket #02.

---

## 2. Public surface (the contract the UI depends on)

`ScanCore` exposes one entry point, an event stream, and immutable snapshot/result value
types. The UI (a `@MainActor` presenter) starts a scan, consumes events, and reads
snapshots; it never touches live mutable state.

```swift
public enum ScanMode: Sendable { case folder, volumeRoot }

public struct ScanRequest: Sendable {
    public let root: URL              // security-scoped URL from NSOpenPanel / volume picker
    public let mode: ScanMode
    public let options: ScanOptions   // cadences, error caps — see §7; all have defaults
}

public protocol Scanning {
    /// Starts a scan and returns its event stream. Cancelling the enclosing Swift
    /// `Task` (or the child task that iterates the stream) cancels the scan cooperatively.
    func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent>
}

public enum ScanEvent: Sendable {
    case started(root: URL, mode: ScanMode, volumeCapacity: VolumeCapacity?)
    case progress(ProgressSnapshot)          // throttled ~10–20 Hz (§5)
    case tree(TreeSnapshot)                  // throttled, slower (~2–5 Hz) (§4.5, §5)
    case finished(ScanResult)                // terminal: .completed or .cancelled
    case failed(ScanFailure)                 // terminal: pre-flight failure only (§2.1)
}
```

The concrete engine is an `actor Scanner: Scanning`. `actor` isolation makes the mutable
node tree single-writer by construction (Ticket #02's *"node tree is actor/serial-queue
isolated"*). `AsyncStream` (not a delegate) is chosen because it is trivially testable
(collect events in an array), naturally back-pressured, and ties scan lifetime to a Swift
`Task` so cancellation is the language's own `Task` cancellation (§6).

**Terminal guarantee:** exactly one of `.finished` / `.failed` is emitted, then the stream
finishes. `.finished` always carries a fully-formed, immutable `ScanResult` even when the
reason is `.cancelled` or when unreadable entries exist — partial results are results, not
failures.

### 2.1 Pre-flight and the root-eligibility predicate (deferred from Ticket #02)

Before any traversal, the engine validates the root on its executor. A predicate failure
ends the scan with `.failed` (nothing to show); a *mid-scan* problem never does (§8).

Eligible root — all must hold, read from the root's own resource values:

- exists and `isDirectoryKey == true` (a volume root is a directory). Reject regular files
  and symlinks as roots.
- `volumeIsLocalKey == true` — **excludes network volumes** (the key's `false` case is
  precisely network-mounted). Internal *and* directly-attached external storage both report
  `true`, satisfying Ticket #01's "internal or directly attached physical" rule without
  needing `volumeIsInternalKey` (which only distinguishes internal-bus from external and is
  informational here).
- security-scoped access starts successfully (§7.4). If `startAccessingSecurityScopedResource()`
  is required and returns `false`, fail pre-flight with a permissions failure.

```swift
public enum ScanFailure: Error, Sendable {
    case rootMissing(URL)
    case rootNotDirectory(URL)
    case rootOnNetworkVolume(URL)         // volumeIsLocalKey == false
    case rootAccessDenied(URL)            // security-scoped access refused / unreadable root
}
```

**Honest residual gap (flag for a human).** Ticket #01 also excludes *mounted disk images*
and *nested mounted volumes*. Nested mounts are handled **for free** by the device-boundary
rule (§3.3): a nested volume has a different `volumeIdentifier`, so traversal simply never
descends into it. A disk-image-backed volume selected *directly as the root*, however, has
no reliable first-party `URLResourceKey` distinguishing it from an ordinary local volume on
macOS 11 (it reports `volumeIsLocalKey == true`). Options, in order of preference:

1. **Accept and label.** Treat a directly-selected local disk image as a local volume
   (`volumeIsLocalKey == true`); it is genuinely on local storage and read-only scanning it
   is harmless. This keeps the predicate first-party and simple.
2. If exclusion is deemed mandatory, add a low-level `statfs(2)` check on the root
   (`f_flags & MNT_LOCAL`, and inspect `f_fstypename`) — but this leaves `ScanCore`'s
   Foundation-only boundary and still cannot cleanly identify all disk-image mounts.

The recommendation is **option 1**, because the map's device-boundary and network exclusions
are the load-bearing safety properties and both are fully enforced. This is the one place the
predicate is weaker than the prose; it is called out so a human can confirm, not silently
decided.

---

## 3. Data model and traversal/aggregation algorithm

### 3.1 The node

Nodes are reference types (`final class ScanNode`) so completed subtrees can be shared into
snapshots without copying (§4.5). One node per discovered filesystem entry.

```swift
public final class ScanNode {
    // Identity / shape
    public let name: String              // last path component only (URL rebuilt by walking parents)
    public unowned let parent: ScanNode? // nil at root; unowned — tree owns children downward
    public private(set) var children: [ScanNode]   // empty for files/symlinks/leaves
    public let kind: NodeKind            // .directory, .package, .file, .symbolicLink, .other

    // Sizes — Ticket #01 logical-length measure only
    public private(set) var ownBytes: Int64        // this file's fileSize; 0 for dirs/symlinks/deduped
    public private(set) var subtreeBytes: Int64    // ownBytes + Σ children.subtreeBytes (live during scan)
    public private(set) var fileCount: Int64        // regular files in subtree (for the tree's count column)

    // Attribution & status (Ticket #01)
    public private(set) var attribution: Attribution   // .owned, .hardLinkElsewhere(owner: NodePathRef?), .excludedRemoteCloud
    public private(set) var readState: ReadState        // .complete, .incomplete, .unreadable
    public let lifecycle: LifecyclePhase                // .open while mutating; .frozen once done (§4.5)
}

public enum NodeKind: Sendable { case directory, package, file, symbolicLink, other }
public enum Attribution: Sendable {
    case owned
    case hardLinkElsewhere(owner: NodePathRef?)   // "counted elsewhere" marker + owning path if known
    case excludedRemoteCloud                      // shown? no — see §3.5; used only for exclusion accounting
}
public enum ReadState: Sendable { case complete, incomplete, unreadable }
```

- **`name` only, not a stored `URL` per node** — a full `URL`/absolute path per node would
  dominate memory at millions of nodes. The absolute `URL` for Open/Reveal/inspector is
  rebuilt on demand by walking `parent` links from the root (§7.2). `NodePathRef` (the
  hard-link owner reference) is likewise a lightweight `[String]` component list or a node
  handle, not a retained `URL`.
- **`ownBytes` is `fileSizeKey`** (logical length). Directories and symlinks have `ownBytes
  == 0`. Deduped hard links have `ownBytes == 0` with `.hardLinkElsewhere` (§3.4). This is
  the *only* size measure stored — `totalFileAllocatedSizeKey` and any block/allocation
  figure are never read for attribution, per Ticket #01.
- **Exact bytes are `Int64`**; the IEC-unit formatting (KiB/MiB/…) and "exact byte count in
  details" (Ticket #01) are a UI concern over this exact value.

### 3.2 Ownership and lifetime of scan state

- The mutable node tree, the hard-link index (§3.4), the error/exclusion accumulators (§8),
  and the running progress counters are **owned exclusively by the `Scanner` actor** for the
  scan's duration. No other component holds a mutable reference.
- The UI reads only (a) `ProgressSnapshot` value copies and (b) `TreeSnapshot`s made of
  **frozen** nodes (§4.5). Frozen subtrees never mutate again, so sharing their references
  across the actor boundary is data-race-free even though `ScanNode` is a class.
- At terminal (`.finished`), the entire tree is frozen and its root handed to the
  `@MainActor` result model, which then owns it read-only for browsing/Open/Reveal. The actor
  drops its reference. Starting a new scan builds a fresh tree; the old one is released when
  the UI releases it.

### 3.3 Traversal: serial, iterative, depth-first, device-bounded

**Decision: single-threaded serial traversal on the actor's executor. No traversal
concurrency in v1.** Rationale, not preference:

- Ticket #01 defines hard-link ownership as *"the first in-scope path encountered."* "First"
  is only well-defined under a deterministic order. Serial DFS with a **stable within-directory
  sort** (localized case-insensitive `name`, ascending) makes ownership deterministic and
  reproducible across runs — a property parallel traversal cannot offer without extra
  synchronization and a tie-break policy.
- A scan is confined to **one physical device** (Ticket #01). Concurrent readers of a single
  device contend on the I/O queue and, on rotational media, cause seek thrashing; the win from
  parallel `readdir`/`getattr` is small-to-negative and never worth the added lock contention
  on the shared hard-link index and ancestor roll-up.
- Serial removes all locking from the hot path: the identity index, the accumulators, and the
  `subtreeBytes` roll-up are touched by exactly one thread.

Parallelism is therefore **deferred, not designed out**: if profiling on SSDs later shows a
win, the seam is a bounded worker pool over *whole immediate-child directories* with the
identity index and accumulators moved behind the actor — but that needs a defined hard-link
tie-break and is out of scope now. Recorded so a future ticket can reopen it deliberately.

**Algorithm** (iterative to bound call-stack depth and to place cancellation checkpoints):

```
push Frame(root) onto an explicit LIFO stack       // Frame = node + lazily-listed children iterator
while stack not empty:
    if Task.isCancelled: goto CANCELLED            // checkpoint A (per directory)
    frame = stack.top
    if frame has no listing yet:
        listing = try contentsOfDirectory(at: frame.url,
                     includingPropertiesForKeys: PREFETCH_KEYS, options: [])   // shallow, symlinks unresolved
        // on throw -> mark frame node .unreadable, mark ancestors .incomplete, record error, pop (§8)
        frame.pending = stableSort(listing)        // deterministic order
    if frame.pending is exhausted:
        finalize(frame.node)                       // freeze subtree (§4.5); pop
        continue
    for (i, childURL) in frame.pending, in batches of BATCH (e.g. 256):
        if Task.isCancelled: goto CANCELLED        // checkpoint B (within large directories)
        vals = try childURL.resourceValues(forKeys: PREFETCH_KEYS)   // usually already prefetched
        node = classifyAndAttribute(childURL, vals, parent: frame.node)   // §3.4, §3.5
        append node to frame.node.children
        if node.kind ∈ {.directory, .package} and sameDevice(vals) and not symlink:
            push Frame(node)                        // recurse only in-device, non-symlink dirs
        else:
            rollUp(node)                            // leaf: attribute ownBytes up the ancestor chain (§3.6)
    // (loop resumes at while-top; children pushed above are processed before finalize)
CANCELLED:
    mark every still-open frame's node .incomplete ; freeze whole tree ; emit .finished(.cancelled)
```

- **Shallow `contentsOfDirectory(at:…)`, not the deep `enumerator`** — because the deep
  enumerator *traverses mount points* (§0) and would silently leave the device. Shallow
  listing + our own recursion keeps every descent decision under the device-boundary check.
- **`sameDevice(vals)`**: compare the child's `volumeIdentifierKey` against the root's via
  `isEqual(_:)`. A subdirectory on a different volume (a nested mount) is **listed but not
  descended**, marked as a boundary exclusion (§3.5). This is how Ticket #01's "traversal
  stays on the root's device" and "nested mounted volumes are out of scope" are enforced.
- **Symlinks are never descended** — even a symlink to an in-device directory. `contentsOfDirectory`
  does not resolve them (§0); we additionally gate on `isSymbolicLinkKey`. A symlink node is a
  leaf with `ownBytes == 0`, kind `.symbolicLink` (Ticket #01: "displayed as links but never
  followed … no attributed content bytes").
- **Packages** (`isPackageKey == true`) are directories; they are **enumerated fully** during
  the scan (pushed like any directory) so the aggregate is exact — Ticket #01's rule. Their
  *collapsed* one-box/one-row presentation is a UI choice over a fully-measured subtree, not
  an engine behavior; the engine builds the real child nodes and lets the UI defer
  materializing them.

`PREFETCH_KEYS` = `{isDirectoryKey, isRegularFileKey, isSymbolicLinkKey, isPackageKey,
fileSizeKey, linkCountKey, fileResourceIdentifierKey, volumeIdentifierKey,
isUbiquitousItemKey, ubiquitousItemDownloadingStatusKey}`. Requesting them via
`includingPropertiesForKeys` lets Foundation batch the metadata fetch per directory,
minimizing syscalls (the resource-value cache is populated on the returned URLs).

### 3.4 Hard-link deduplication (Ticket #01 identity rule)

- Maintain one **hard-link index** per scan: `[FileIdentityKey: NodeHandle]`, mapping a file
  identity to the node that first (in deterministic order) attributed its bytes.
- **Only files with `linkCountKey > 1` are ever inserted.** A file with link count `1` cannot
  be a hard link and skips the index entirely — this bounds the index to the (typically tiny)
  set of multiply-linked inodes, not the whole tree.
- `FileIdentityKey` wraps the `fileResourceIdentifierKey` value. That value is an `id`
  compared with `isEqual(_:)`; its equality is exactly *"same path or same inode on the same
  file system"* (§0) — precisely Ticket #01's identity. Wrap it as an `NSObject`-backed
  hashable key (forwarding `hash`/`isEqual`) or store in an `NSMutableDictionary`. Because
  the identifier is not persistent across restarts, the index is per-scan and never persisted
  — which is all we need.
- On a link-count-`>1` file: if its identity is **absent**, insert `identity → thisNode`,
  attribute `ownBytes = fileSize`, `attribution = .owned`. If **present**, set `ownBytes = 0`,
  `attribution = .hardLinkElsewhere(owner: handle-of-first-node)`, and do **not** roll bytes
  up (they were already counted at the owner). The node stays visible (Ticket #01: "remain
  visible with zero attributed bytes … and a reference to the owning path").
- The engine never searches outside the root for other names of an inode (Ticket #01) — it
  only knows identities it has actually encountered under the root.
- **Optimization:** if the root volume's `volumeSupportsHardLinksKey == false`, skip the
  index and the `linkCount` bookkeeping entirely — no dedup is possible. (Read once at
  pre-flight.)
- **APFS clones are not deduped** (Ticket #01): clones have *distinct* inodes/identities, so
  they never collide in the index and each contributes its own `fileSize`. This falls out of
  the identity rule automatically — no special case.

### 3.5 Cloud / file-provider materialization (Ticket #01)

For each entry, if `isUbiquitousItemKey == true` (or a downloading-status value is present),
read `ubiquitousItemDownloadingStatusKey`:

- `.notDownloaded` ⇒ **remote-only placeholder**: omit from tree and treemap; increment
  `exclusions[.remoteOnlyCloud]`. Never call `startDownloadingUbiquitousItem` and never open
  the file's data — scanning must not trigger a download (Ticket #01).
- `.downloaded` or `.current` ⇒ locally materialized: include it as an ordinary file and
  attribute its `fileSize` normally.

Third-party File Provider dataless files that do not surface a ubiquitous status on macOS 11
degrade safely: if a materialization status cannot be determined, the entry is treated as a
present local file and attributed by its `fileSize`. This risks counting a small number of
dataless third-party items but never triggers I/O; it is the conservative "include what looks
local" reading of Ticket #01, noted here as the known imprecision.

Boundary exclusions (nested-volume subdirectories not descended, §3.3) increment
`exclusions[.crossedVolumeBoundary]`. Exclusions are **not** errors (§8): nothing went wrong,
a policy chose to skip them. `ScanResult` reports exclusion counts by reason.

### 3.6 Aggregation: incremental ancestor roll-up

- `rollUp(node)`: when a leaf's `ownBytes` is attributed (`> 0`), add it to every ancestor's
  `subtreeBytes` along the `parent` chain to the root, and increment ancestors' `fileCount`.
  Depth is small (tens); this is O(depth) integer additions per file — tens of millions of
  cheap adds across a million-file scan.
- Consequence: **at every instant, each open directory's `subtreeBytes` already reflects
  everything discovered beneath it so far.** This is what makes live, growing directory sizes
  possible in incremental snapshots (§4.5) without a separate summing pass.
- A directory's `subtreeBytes` at finalize equals the sum of its descendants' `ownBytes` — no
  double counting (deduped links contributed 0; symlinks contributed 0; directories carry no
  `ownBytes`).
- Deduped hard links and remote-only cloud items do **not** roll up (0 or omitted), so
  directory totals match Ticket #01's attribution exactly.

---

## 4. Event/state contract, snapshots, and incremental delivery

### 4.1 Engine state machine

```
idle ──scan()──► scanning ──┬─ traversal completes ─────► completed (terminal)
                            ├─ Task cancelled ──────────► cancelled (terminal)
                            └─ pre-flight predicate fails ► failed   (terminal, emitted before any progress)
```

`completed` and `cancelled` both emit `.finished(ScanResult)`; only pre-flight emits
`.failed`. Mid-scan filesystem problems never move the machine to a failed state — they are
recorded and traversal continues (§8).

### 4.2 `ProgressSnapshot` (scalars, high-frequency)

```swift
public struct ProgressSnapshot: Sendable {
    public let attributedBytes: Int64     // headline: bytes counted so far (post-dedup), == root.subtreeBytes
    public let filesSeen: Int64
    public let directoriesSeen: Int64
    public let currentPathTail: String    // e.g. last 2–3 components of the directory being listed
    public let elapsed: Duration
    public let bytesPerSecond: Double      // derived, smoothed
    public let errorCount: Int
    public let exclusionCount: Int
    public let approximateFraction: Double? // §5; non-nil only for volumeRoot scans
}
```

### 4.3 `VolumeCapacity` and `ScanResult`

```swift
public struct VolumeCapacity: Sendable {   // whole-volume scans only; shown "separately" per Ticket #01
    public let totalBytes: Int64            // volumeTotalCapacityKey
    public let availableBytes: Int64        // volumeAvailableCapacityKey
}

public struct ScanResult: Sendable {
    public enum Reason: Sendable { case completed, cancelled }
    public let reason: Reason
    public let root: ScanNode               // frozen, immutable tree root
    public let completeness: Completeness   // .exact | .incomplete(reasons)
    public let errors: ErrorSummary         // §8
    public let exclusions: ExclusionSummary // counts by reason (§3.5)
    public let volumeCapacity: VolumeCapacity?
    public let elapsed: Duration
}

public enum Completeness: Sendable {
    case exact                              // no unreadable entries, ran to completion
    case incomplete(cancelled: Bool, unreadableEntries: Int)  // "Incomplete" / "Incomplete—scan cancelled"
}
```

`completeness` is what the UI reads to render Ticket #01's mandatory **"Incomplete"** and
**"Incomplete—scan cancelled"** banners. Note there is **no** synthetic "Unknown" byte figure
anywhere (Ticket #01): capacity/free are reported as separate volume facts, never subtracted
from logical totals.

### 4.4 Ordering and back-pressure

- Event order per scan: exactly one `.started`; then interleaved `.progress` and `.tree`
  (both monotonic — later snapshots supersede earlier); then exactly one terminal
  `.finished`/`.failed`; then stream end.
- `AsyncStream` buffering policy: **`.bufferingNewest(1)`** for the stream, so a slow UI
  consumer coalesces to the latest snapshot instead of building an unbounded backlog — the
  engine never blocks on the UI, and stale intermediate snapshots are dropped rather than
  queued. (`.started`/`.finished` are delivered reliably by construction: they bracket the
  buffered middle.)

### 4.5 Incremental result delivery via frozen structural sharing

The requirement is a live-updating tree/treemap without O(total-nodes) copies per tick.

- **Node lifecycle:** a `ScanNode` is `.open` while it or its subtree is still being built;
  `finalize(node)` transitions it to `.frozen` once its listing is exhausted and all children
  are frozen. **A frozen node is immutable forever** (its `subtreeBytes`/`children`/state stop
  changing). Only nodes on the current **open spine** (root → the frame being processed) plus
  the frontier are mutable at any instant; that spine is depth-bounded (tens of nodes).
- **A `TreeSnapshot`** published at a tick references **frozen subtrees directly (shared, no
  copy)** and represents the still-open spine with a thin, freshly-made immutable copy of just
  those spine nodes (carrying their current partial `subtreeBytes`). Cost per snapshot ≈
  O(spine depth + nodes frozen since last tick), not O(total). This gives genuine incremental
  delivery: newly-completed subtrees "snap in" fully-formed and shared; open ancestors show
  their growing partial totals.
- Because frozen nodes never mutate, handing their references to the `@MainActor` UI is
  race-free (§3.2). The `NSOutlineView` data source and treemap read node fields directly off
  the snapshot on the main thread.
- **`.tree` cadence is slower than `.progress`** (§5): rebuilding even the thin spine and
  reloading `NSOutlineView`/redrawing the treemap costs more than bumping scalar counters.

This is the concrete mechanism behind Ticket #02's *"UI reads immutable snapshots, never the
live mutating structure."*

---

## 5. Progress semantics before the total is known

There is no cheap way to know the final node/byte count without a full pre-pass, and a
pre-pass would double the I/O. So:

- **Primary progress is indeterminate + live telemetry:** `attributedBytes`, `filesSeen`,
  `directoriesSeen`, `currentPathTail`, `elapsed`, `bytesPerSecond`. This is honest and
  immediately useful ("2.3 GiB · 41,208 files · /Users/…/Caches").
- **Optional approximate fraction for whole-volume scans only.** For `mode == .volumeRoot`,
  read the volume's used bytes at `.started` (`volumeTotalCapacityKey - volumeAvailableCapacityKey`)
  and expose `approximateFraction = min(attributedBytes / usedBytes, 1.0)`, **explicitly
  labelled approximate** in the UI. It drifts (logical content bytes ≠ physical used bytes,
  and excluded/deduped content lowers the numerator), so it is a reassurance bar, never a
  promise, and is `nil` for folder scans. This respects Ticket #01: capacity/free are shown
  as separate volume facts and are **not** turned into a synthetic byte count in the tree.
- **Throttling / coalescing (Ticket #02's "never per file"):** the engine timestamps counter
  mutations but only *emits*:
  - `.progress` at **≤ ~15 Hz** (emit if ≥ ~66 ms since last emit),
  - `.tree` at **≤ ~4 Hz** (emit if ≥ ~250 ms since last emit *and* something froze since the
    last tree emit).
  Both cadences live in `ScanOptions` so tests can set them to 0 (emit every change) or ∞
  (emit only terminally). A final `.progress` + `.tree` is always emitted immediately before
  `.finished` so the UI's last frame is exact.

---

## 6. Cancellation behavior

- **Cooperative, via Swift `Task` cancellation** (Ticket #02). The caller cancels the `Task`
  that consumes the stream; `Task.isCancelled` becomes `true` and stays `true` (§0).
- **Checkpoints** (from §3.3): **(A)** once per directory pop (top of the traversal loop) and
  **(B)** once per `BATCH` (~256) entries inside a large directory. Worst-case latency to stop
  is one directory listing or one batch of `resourceValues` — sub-100 ms in practice, bounded
  regardless of tree size. No unbounded uninterruptible section exists.
- **On cancel:** stop listing/pushing immediately; walk the open spine marking each still-open
  node `.incomplete`; freeze the whole tree; emit a final exact `.progress`, a final `.tree`,
  then `.finished(reason: .cancelled, completeness: .incomplete(cancelled: true, …))`.
  **Everything already discovered is retained and browsable** — nodes are never discarded on
  cancel (Ticket #01). Open/Reveal/selection work on the partial tree.
- **`withTaskCancellationHandler`** wraps the traversal so security-scoped access is released
  promptly on cancel (the `onCancel` handler is invoked immediately, §0), guaranteeing
  `stopAccessingSecurityScopedResource()` even if cancellation lands between checkpoints.
- Cancellation is **idempotent and terminal**: further cancels are no-ops; a cancelled scan
  never later reports `completed`.

---

## 7. Resource bounds

### 7.1 Memory

- The dominant cost is the retained node tree: **one `ScanNode` per in-scope entry**, which is
  inherent (the tree *is* the result). Bounded per node by storing **`name` only** (not a
  `URL`/absolute path) and packing sizes as `Int64` and state as small enums. Budget ≈ low
  hundreds of bytes/node incl. Swift object + array overhead; ~1 M nodes ⇒ order 10²  MB.
  Note for a future ticket if this proves too high: intern repeated directory names, or store
  children in contiguous arrays indexed by parent, or a columnar node store.
- **Traversal working set is small and bounded**: the explicit LIFO stack holds one frame per
  open-spine level (depth-bounded), each with the *current directory's* child listing only —
  not the whole tree. Shallow `contentsOfDirectory` means at most one directory's entries are
  materialized as `URL`s at a time per open level.
- **Hard-link index** holds only `linkCount > 1` identities (§3.4) — typically tiny.
- **Error accumulator** is capped (§8): keep the first `maxDetailedErrors` (default 1,000)
  full records plus per-category counts; overflow only increments counts. Prevents a
  pathological all-unreadable tree from exhausting memory.

### 7.2 Path reconstruction

`Open`/`Reveal`/inspector need an absolute `URL`; nodes store only `name`. Rebuild by
collecting `name`s up the `parent` chain to the root and appending to the root `URL`
(`appendingPathComponent`). O(depth), done only on user action (never in the hot path), so the
memory saving costs nothing at scan time.

### 7.3 I/O

- One shallow directory read per directory (`contentsOfDirectory`), with resource values
  **prefetched in the same call** (§3.3) to avoid a second syscall per child.
- No file *contents* are ever read — only metadata. Guarantees the read-only, no-download
  mandate (Ticket #01) at the I/O layer.

### 7.4 Security-scoped access

The root `URL` from `NSOpenPanel`/volume picker is security-scoped. The engine calls
`root.startAccessingSecurityScopedResource()` at pre-flight and pairs it with
`stopAccessingSecurityScopedResource()` in a `defer` **and** in the `withTaskCancellationHandler`
`onCancel` (§6), so access is always released exactly once. (Entitlement packaging is out of
scope per the map; the access *pattern* is in scope for a locally buildable sandboxed app, per
Ticket #02.)

### 7.5 Concurrency

Exactly **one** in-flight scan per `Scanner`. `scan()` while another scan runs cancels the
prior scan first (its stream finishes `.cancelled`) before starting the new one — the UI can
only show one result at a time and this avoids two traversals contending on the device.

---

## 8. Error and exclusion policy (Ticket #01)

**Principle:** recoverable filesystem problems never fail the scan; sizes are never guessed;
affected ancestors are marked incomplete; a summary is exposed.

| Situation | Detection | Node effect | Propagation | Accounting |
| --- | --- | --- | --- | --- |
| Directory unreadable (permission, I/O) | `contentsOfDirectory` throws | node `.unreadable`; no children; `subtreeBytes` = whatever was attributed before failure (here: 0) | every ancestor `.incomplete` | error record + `errors.byCategory[.unreadableDirectory]++` |
| Entry metadata unreadable / malformed (e.g. `fileSize` nil) | `resourceValues` throws or key missing | that node `.unreadable`; `ownBytes` **not guessed** (0, excluded from totals) | ancestors `.incomplete` | `errors.byCategory[.unreadableEntry]++` |
| Entry vanished mid-scan | listed but `resourceValues`/access fails with no-such-file | node `.unreadable` (disappeared) | ancestors `.incomplete` | `errors.byCategory[.disappeared]++` |
| Symlink | `isSymbolicLinkKey` | leaf, `.symbolicLink`, `ownBytes 0`, `.owned` | none | **not an error, not an exclusion** — a normal displayed item |
| Hard link counted elsewhere | identity hit (§3.4) | `ownBytes 0`, `.hardLinkElsewhere` | none | not an error; visible marker only |
| Remote-only cloud item | `.notDownloaded` (§3.5) | **omitted** (no node) | none | `exclusions[.remoteOnlyCloud]++` |
| Cross-volume subdirectory | `volumeIdentifier` mismatch (§3.3) | listed as boundary node, not descended | none | `exclusions[.crossedVolumeBoundary]++` |

```swift
public struct ErrorRecord: Sendable { public let path: [String]; public let category: ErrorCategory; public let message: String }
public struct ErrorSummary: Sendable {
    public let byCategory: [ErrorCategory: Int]   // full totals (never capped)
    public let details: [ErrorRecord]             // capped at options.maxDetailedErrors
    public let truncated: Bool
}
public struct ExclusionSummary: Sendable { public let byReason: [ExclusionReason: Int] }
```

- **"Incomplete" is derived, not stored redundantly:** a directory is incomplete iff any
  descendant is `.unreadable` *or* the scan was cancelled while it was open. The engine sets
  `readState = .incomplete` on ancestors at the moment of each failure so the flag is correct
  in every intermediate snapshot, not only at the end.
- **No synthetic Unknown byte count** is ever produced by subtracting logical totals from
  physical volume usage (Ticket #01). Unreadable subtrees simply contribute the bytes actually
  measured (often 0) and are visibly flagged, never back-filled with an estimate.
- The `errorHandler` of the deep enumerator is **not** used (we don't use that enumerator);
  errors are caught at each explicit `contentsOfDirectory`/`resourceValues` call site, giving
  precise per-node attribution the deep enumerator's single handler could not.

---

## 9. Test seams (headless, in the framework-free `ScanCore` package)

The engine is Foundation-only and UI-free (Ticket #02), so all of the below run in plain
XCTest with no app host:

1. **Filesystem fixtures via `FileManager` in a temp dir.** Each Ticket #01 acceptance case
   becomes a fixture built in `NSTemporaryDirectory()`, scanned, and asserted on the resulting
   `ScanResult`:
   - hidden 2 GiB (sparse) file ⇒ contributes its logical `fileSize`, visible.
   - symlink to a large file ⇒ `ownBytes 0`, kind `.symbolicLink`, not traversed.
   - two hard links under root (`link(2)`) ⇒ counted once; a third link created *outside* root
     is neither sought nor shown.
   - a package (dir with a package extension) of 500 MiB ⇒ exact aggregate, one subtree.
   - unreadable child (`chmod 000`) ⇒ sibling traversal continues; ancestors `.incomplete`;
     result `.incomplete`, not failed.
   - cancel after N entries ⇒ partial tree retained, `completeness.cancelled == true`.
   (Use small sparse files created with `ftruncate`/`FileHandle.truncate` so multi-GiB logical
   sizes cost no real disk.)
2. **Injectable clock and cadence** — `ScanOptions` carries the progress/tree cadences and a
   clock abstraction so throttling is deterministic in tests (set cadence 0 ⇒ every change
   emitted; drive time manually to assert coalescing).
3. **Injectable filesystem probe (the primary seam).** Traversal talks to a small internal
   `protocol DirectoryProbe { func list(_ url: URL) throws -> [EntryMeta]; func meta(_ url: URL) throws -> EntryMeta }`
   whose production impl wraps `contentsOfDirectory`/`resourceValues`. A **fake `DirectoryProbe`**
   lets tests model, without a real filesystem: cross-volume boundaries (distinct
   `volumeIdentifier`s), cloud `.notDownloaded` items, hard-link identities, mid-scan
   disappearance (throw on second `meta` call), and permission errors — the cases that are
   awkward to stage on a real disk in CI. `EntryMeta` is a plain value mirroring the prefetched
   keys.
4. **Event-stream assertions.** Collect the `AsyncStream<ScanEvent>` into an array and assert:
   exactly one `.started`, monotonic snapshots, exactly one terminal event, correct
   `completeness`, error/exclusion counts, and — via cadence 0 — the full progression.
5. **Cancellation latency test.** With a fake probe that blocks per batch, assert cancellation
   observed within one batch/one directory and that `stopAccessingSecurityScopedResource` (a
   spy) is called exactly once.
6. **Determinism test.** The same fixture scanned twice yields identical hard-link ownership
   and identical node ordering (guards the stable-sort / serial-traversal contract of §3.3).

---

## 10. Decision summary (what an implementer can rely on)

- **Engine = `actor Scanner`** exposing `scan(ScanRequest) -> AsyncStream<ScanEvent>`; one
  scan at a time; pre-flight validates the root and can `.failed`, mid-scan never does.
- **Traversal = serial, iterative DFS** over an explicit stack, using **shallow
  `contentsOfDirectory` with prefetched resource keys** and **its own device-boundary check**
  (never the mount-crossing deep enumerator), with a stable within-directory sort for
  deterministic hard-link ownership.
- **Sizes = `fileSizeKey` (logical) only**, `Int64`, rolled up incrementally to ancestors.
- **Hard links** deduped via `fileResourceIdentifierKey` identity, indexed only for
  `linkCount > 1`; **APFS clones fall out as distinct** automatically.
- **Cloud** materialization gated on `ubiquitousItemDownloadingStatusKey`; remote-only omitted
  and counted, never downloaded.
- **State/lifetime:** the `actor` solely owns the mutable tree; the UI reads scalar
  `ProgressSnapshot`s and `TreeSnapshot`s of **frozen, shared** subtrees — cheap incremental
  delivery, no deep copies.
- **Progress:** indeterminate + live telemetry always; an explicitly-approximate fraction only
  for volume scans; emissions throttled (~15 Hz scalars, ~4 Hz tree), configurable to 0/∞ for
  tests.
- **Cancellation:** cooperative `Task.isCancelled`, checkpoints per-directory and per-256
  entries, worst-case sub-directory latency, discovered results retained and frozen.
- **Errors** never fail the scan, never guess sizes, mark ancestors incomplete, and surface a
  capped summary; **exclusions** are accounted separately; **no synthetic Unknown** byte
  count is ever produced.
- **Bounds:** memory dominated by the (inherent) node tree with `name`-only nodes; working
  set, hard-link index, and error details all bounded.
- **Testable headlessly** via a `DirectoryProbe` seam, injectable cadence/clock, and
  temp-dir fixtures for every Ticket #01 acceptance case.

**Handed on:** treemap layout over this node tree → Ticket #05; view wiring and interaction
refinement → Tickets #04/#05. **Flagged for a human:** the residual disk-image-as-root gap in
§2.1 (recommended resolution: accept local disk images, since network exclusion and the
device boundary — the load-bearing safety rules — are fully enforced).
