---
type: task
blocked_by: [02]
undermined_by: []
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
