---
type: task
blocked_by: [02]
undermined_by: []
claimed_by: sc6d18c600a83
claimed_at: 2026-08-16T10:28:20Z
---

# ScanCore: core traversal + event/state + cancellation

## Question

Build the headless heart of the scan engine — enough to scan a tree, total it correctly,
stream honest progress, deliver one terminal result, and cancel promptly — as the first
complete-but-invisible slice. Semantics and interfaces are fixed by spec §3 and §5; the
research asset `assets/03-scan-engine-design.md` in the planning map has the cited detail.

Implement in the scan-engine package:

- The **`DirectoryProbe` test seam** (listing + metadata only; no write/download/open-data
  method) and a **`ScriptedDirectoryProbe`** that supplies entry metadata, volume
  identifiers, and injected cadence/clock directly.
- The **`actor Scanner`** exposing `scan(ScanRequest) -> AsyncStream<ScanEvent>` with the
  state machine `idle → scanning → completed | cancelled | failed` (spec §5.3): root
  eligibility pre-flight producing `.failed` **only** pre-flight; exactly one terminal
  event; one active scan at a time.
- **Serial, iterative, depth-first traversal** over an explicit stack using shallow
  directory listing with prefetched resource keys, descending into a subdirectory only
  when its volume identifier equals the root's (device boundary; spec §5.4). Deterministic
  within-directory name sort.
- **Logical `fileSizeKey` rollup** (`Int64`) to every ancestor, live at all times; hidden
  files included; symlinks displayed but never followed and attributed **zero** bytes;
  allocation/metadata figures never read.
- The **frozen, structurally-shared snapshot model** (spec §5.2): the actor owns the
  mutable name-only node tree; the UI-facing side reads immutable `ProgressSnapshot`s and
  `TreeSnapshot`s built from frozen subtrees shared by reference.
- **Coalesced progress** (≤ ~15 Hz scalars, ≤ ~4 Hz tree; injectable clock; configurable
  to 0/∞ for tests), never per-entry; folder scans carry no completion fraction.
- **Cooperative cancellation** checked per-directory and per-256-entry batch, retaining
  all discovered results and emitting a final exact snapshot with reason `.cancelled`;
  security-scoped access released exactly once via a cancellation handler.

This ticket does **not** implement hard-link/clone/package/cloud/error semantics (ticket
04) or the production `FileManager` probe (ticket 05).

## Done when

- `ScanCoreTests` (fake probe, virtual clock) proves: eligibility pre-flight emits
  `.failed` only pre-flight; a fully eligible root emits `.started`; interleaved monotonic
  snapshots; exactly one terminal event then stream end; one active scan.
- Aggregation is exact and incremental at cadence zero: every ancestor total is monotonic
  and equals discovered owned leaves at every event; final totals equal an independent
  manifest fold.
- Traversal is proven serial/iterative/deterministic on a deep chain (identical runs →
  identical node order); the request log proves no listing beneath a differing-volume
  child and no redundant reads.
- Hidden files roll up; symlinks are visible zero-byte leaves and are never traversed
  (including a loop/broken link, once real fixtures exist in ticket 05 — scripted here).
- Progress honesty holds under the virtual clock (≤15 Hz / ≤4 Hz, buffering-newest,
  immediate exact final snapshot; folder fraction always absent).
- Cancellation records ≤ one additional listing/batch past the checkpoint, marks open
  ancestors Incomplete, retains all nodes, ends `.cancelled`, and releases access once.

## Answer

The headless heart of the scan engine is built and green: `Packages/ScanCore` now scans a
tree, totals it exactly, streams honest coalesced progress, delivers exactly one terminal
result, and stops promptly when asked — 41 tests in `ScanCoreTests`, clean under Thread
Sanitizer, and `Scripts/verify-scaffold.sh` exits 0 with every step PASS (including the
`MacDirStat-CI` plan and the universal Release build).

**What was built**

- **`DirectoryProbe`** — the seam, three requirements and nothing else: `list(_:)`,
  `metadata(of:)`, `volumeInfo(for:)`. Read-only is structural, and `ReadOnlySeamTests`
  holds it that way by asserting against the protocol's own source text (Swift has no
  runtime reflection over protocol requirements), so a later session cannot widen the seam
  by habit. `EntryMeta` mirrors the full prefetch key set; `fileSize` is `Int64?` because a
  size that cannot be read is never guessed.
- **`ScriptedDirectoryProbe`** (new target `ScanCoreTestSupport` — a target, not test-target
  sources, so every suite shares one set of doubles and the shipping library carries none of
  them) with `VirtualClock` and `SpySecurityScopedAccess`. It **records every request**,
  which is the only way to prove the two negative claims: nothing beneath a differing-volume
  child is ever listed, and no entry is read twice. It hands entries back in reverse order on
  purpose, so the engine's own sort is what produces determinism.
- **`actor Scanner`** — `scan(ScanRequest) -> AsyncStream<ScanEvent>`, pre-flight
  eligibility (exists, is a directory, not a symlink, `volumeIsLocal`), `.failed` only there,
  exactly one terminal event, one active scan. The traversal runs on a **detached** task
  rather than the actor's executor: it is a long synchronous run of Foundation file I/O
  (§4.3 — the async file APIs are above the floor), and parking that on the actor would make
  every `scan`/`cancel` queue behind it. `ScanSession` is confined to that task, so the tree
  has one writer by construction with no lock on the hot path.
- **Serial, iterative, depth-first traversal** over an explicit stack, descending
  immediately on reaching a directory so the open spine stays root→current — which is what
  makes a snapshot O(spine depth) rather than O(open nodes). One shallow listing per
  directory; `metadata` is called for the root and nowhere else.
- **Frozen structural sharing.** A leaf freezes on attribution, a directory on its last
  entry. `frozenSnapshot` returns a frozen node **as-is, shared by reference** and copies
  only the open spine. `TreeSnapshot` keeps a strong reference to the live tree, because a
  shared frozen subtree's `unowned parent` points into it and a snapshot outliving the
  result would otherwise dangle.
- **Coalesced progress** at ≤15 Hz scalars / ≤4 Hz tree against an injectable clock,
  configurable to `.everyChange` (0) and `.terminalOnly` (∞). The clock is consulted every
  64 entries rather than per entry, since a 66 ms decision does not need a syscall per file.
  Volume scans carry an explicitly approximate, clamped fraction; folder scans carry `nil`.
- **Cancellation** checked per directory and per 256-entry batch, via `Task.isCancelled`
  **and** a synchronously-settable token behind `Scanner.cancel()` — the UI's Cancel button
  must be able to trip the flag and then keep consuming the stream to receive its partial
  result, which cancelling the consuming task cannot do. Open ancestors → Incomplete, every
  discovered node retained and frozen, `.finished(.cancelled)`, and security-scoped access
  released exactly once through `withTaskCancellationHandler` plus a once-flag.

**Four judgment calls that depart from the research asset — all deliberate**

1. **The within-directory sort is locale-independent**, not the asset's "localized
   case-insensitive". A localized comparison is not a deterministic one: two machines with
   different locales would produce different node order and, in ticket 04, a different
   hard-link owner. Swift's `String <` is Unicode-deterministic and matches the spec's
   treemap tie-break (§6.1, code-point order). **Ticket 04 depends on this.**
2. **`ProgressSnapshot.elapsed` is a `TimeInterval`, not `Duration`.** `Swift.Duration` is
   macOS 13+, above the 11.0 floor; the asset's signature would not compile at the floor.
   `ScanClock` exists for the same reason — `Swift.Clock` is also macOS 13+.
3. **A refused security scope is no longer an eligibility verdict.** The asset fails
   pre-flight when `startAccessingSecurityScopedResource()` returns `false`, but that is
   what an ordinary non-security-scoped local URL returns, so the rule would reject most
   real roots. The adapter now reports only whether a stop is *owed*; a root that genuinely
   cannot be read fails pre-flight through the probe instead. Flagged for ticket 07.
4. **Buffering-newest is implemented in the sink, not by `AsyncStream`'s policy.**
   `.bufferingNewest(1)` would drop `.started` the moment a `.progress` arrived at a busy
   consumer, and `.started`/terminal are the contract. `EventSink` therefore queues progress
   and tree as *slots* — one value each, holding its place in the queue, overwritten in
   place by a newer one — over a pull-based `AsyncStream(unfolding:)`. A consumer that looks
   away comes back to the newest snapshot exactly once; the contract events always arrive.
   Proven: a consumer that sleeps through a whole scan receives one `.started`, one
   terminal, and far fewer snapshots than the engine emitted, the last of which is exact.

**Two semantics worth knowing**

- **Cancelled is terminal, incomplete is separate.** Once cancellation is requested the
  reason is `.cancelled` and never `.completed`, but a cancel that lands after the last
  directory was read still reports `completeness == .exact` — the data really is whole. The
  banner reads `completeness`, so it does not cry Incomplete over a complete tree.
- **Unprocessed entries produce no nodes.** Nodes are materialized as entries are processed,
  so a listed-but-not-yet-walked sibling has no node when cancellation lands. That is
  precisely what Incomplete on its parent means; the alternative is inventing nodes whose
  state nothing has established.

**One bound found, not a defect**

The depth-chain test tops out at 1,000 levels, not because the walk recurses — it does not —
but because releasing *any* class chain that deep is a recursive ARC teardown, and a
cooperative-pool thread's 512 KB stack gives out somewhere past 1,000. Reproduced in twelve
lines with no scanner involved. It sits 15× beyond the spec's depth-64 stress shape and
beyond what `PATH_MAX` lets a real filesystem nest, so it is recorded for ticket 10 rather
than worked around.

**Omitted deliberately (ticket 04's, per this ticket's own boundary)**

Hard-link dedup, APFS clones, cloud materialization, the boundary/cloud **exclusion**
counters, and the capped `ErrorSummary`/`ExclusionSummary` with category totals and
`truncated`. `ScanResult` therefore carries `completeness` (with an exact unreadable-entry
count) but no error or exclusion summaries yet. The model fields those rules need —
`Attribution`, `linkCount`, `fileIdentity`, `cloudDownloadingStatus`,
`VolumeInfo.supportsHardLinks` — exist and are documented as ticket 04's, so 04 adds
behaviour rather than reshaping types. The production `FileManager` probe and real-filesystem
fixtures are ticket 05's; `ScanCoreFileSystemTests` still holds only its scaffold placeholder.
