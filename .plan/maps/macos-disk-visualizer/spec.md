# macOS Disk Visualizer — Implementation-Ready Specification

## Decisions taken after this spec was written

**These supersede the body of this document wherever the two disagree.** The spec below
is left as the original design record rather than rewritten in place.

*2026-08-18 — simplification pass. The repo had grown ~14,000 lines of tests and guard
machinery around ~8,000 lines of product, and mid-scan tree publishing was producing wrong
percentages and a crash on held selections.*

1. **The deployment floor is macOS 14**, not 11.0, and the build is no longer pinned to a
   universal `arm64 + x86_64` slice. This retires the whole post-Big-Sur API watch-list
   (§4.4), the compatibility-smoke target/plan/scheme and the Big Sur endpoint testing
   (§9.1, §9.4, §10), and the availability workarounds the floor forced.
2. **The tree is published once, with the terminal event.** §5.2's structurally-shared
   frozen snapshots, `TreeSnapshot`, the ~4 Hz tree cadence (§5.4, §5.5) and the panes
   populating behind the progress card (§7.1) are all gone. Reused subtrees kept pointing
   up into the live tree, so a published node's parent was a node the scan thread was still
   mutating — a moving denominator for share-of-parent, and an upward pointer that did not
   keep its target alive. Progress scalars still stream at ~15 Hz and carry the live
   feedback.
3. **Emission cadence is a plain interval in seconds**, not a three-case enum. `0` means
   every change and `.infinity` means the final reading only.
4. **The verification surface is one test plan and one app test target.** The performance
   and scale suite (§8.2, §9.1), the UI-test target, the thread-sanitizer plan, the
   compatibility-smoke plan and the build-time guard scripts (`Scripts/`) are all deleted.
   `swift test` on both packages plus the `CI` plan is the whole gate.

---

**Status:** Settled. This specification is the single authoritative contract for the
first implementation. It consolidates the seven resolved planning tickets of the
*macOS Disk Visualizer* map, reconciles the two flagged contradictions, and names the
subsystem interfaces so an implementation session can build without reopening product
decisions.

**Provenance.** Every requirement here traces to a resolved ticket. Where a decision was
settled with a human, that is noted. This document invents **no new product decisions**;
it reconciles and organizes existing ones. Ticket references use the map's numbering:
[01](./tickets/01-settle-scan-semantics.md) scan semantics,
[02](./tickets/02-choose-platform-architecture.md) architecture,
[03](./tickets/03-design-scan-engine.md) scan engine,
[04](./tickets/04-prototype-core-workspace.md) workspace,
[05](./tickets/05-specify-treemap.md) treemap,
[06](./tickets/06-settle-quality-bars.md) quality bars,
[07](./tickets/07-design-verification-strategy.md) verification.

Supporting research assets (cited API-availability findings) live under `assets/`:
`02-platform-architecture-research.md`, `03-scan-engine-design.md`. Prototypes (primary
sources for the accepted look/feel and treemap geometry) live under `prototype/`.

---

## 1. Product summary

A native Swift macOS application that scans one user-selected folder or mounted local
volume and presents where the space went, as a modern interpretation of WinDirStat — not
a pixel-for-pixel port. It is:

- **Read-only.** It measures and displays. It never deletes, cleans, moves, mutates, or
  downloads. The only file actions are **Open** and **Reveal in Finder**.
- **Big Sur–capable.** It builds and runs on macOS 11.0 and every later stable macOS,
  from a universal (`arm64` + `x86_64`) build.
- **Locally buildable in Xcode.** Signing, notarization, packaging, distribution,
  analytics, and release infrastructure are out of scope.
- **Two synchronized views.** A directory tree and a WinDirStat-style treemap, driven by
  one shared selection.

The MVP's guarantee is **correctness and honesty**, not speed: area is strictly
proportional to the blocks a file occupies, sizes are never guessed, partial and failed
scans stay truthful and browsable, and nothing with real bytes ever disappears from the
picture.

---

## 2. Scope and exclusions

### In scope

- Scanning exactly one selected root (folder or eligible local volume).
- Cancellable scan with visible, incremental progress; partial results retained.
- Synchronized directory-tree (`NSOutlineView`) and treemap (custom Core Graphics
  `NSView`) with one shared selection.
- Read-only **Open** (`NSWorkspace.open`) and **Reveal in Finder**
  (`NSWorkspace.activateFileViewerSelecting`).
- Honest handling of hidden files, symlinks, hard links, packages, cloud placeholders,
  unreadable entries, cancellation, and live filesystem change.

### Out of scope (first version)

- **File mutation of any kind:** deletion, cleanup, moving, renaming, duplicate detection
  and removal, and any file-management workflow.
- **Analytics/history:** historical comparison, scheduled or background scanning.
- **Multiple roots per scan**, network volumes, cloud-provider roots, mounted disk
  images, and nested mounted volumes (see §4).
- **Release infrastructure:** signing, notarization, packaging, distribution, analytics,
  crash reporting, update mechanisms.
- **Persisted documents:** a scan is a transient session, not a saved document; the app
  is **not** document-based.

### Deferred within v1 (fixed enough to build around; refined in the `-impl` map)

These are settled *product behaviors* whose finer presentation detail is left to
implementation, per Tickets 04/05:

- Exact `NSOutlineView` columns, default sort, and percent-bar treatment.
- Final inspector field set, and whether Open/Reveal also appear in a context menu.
- Collapsed-package → expand-to-children drill-in interaction (the aggregate is already
  fixed by §3; only the presentation of children is deferred).
- Final progress throttle cadence and the exact volume-scan approximation copy.
- Exact palette hue constants (tunable, not load-bearing).

### Explicit unset boundaries (must be named to any implementer)

- **No wall-clock / throughput / completion-time SLA.** Throughput is best-effort and
  disk-bound (§8).
- **No p99 / millisecond UI-latency or cancellation-latency thresholds.** Cancellation is
  bounded as an *operation* count, not a time (§8).
- **No quantitative accessibility coverage bar.** The a11y *mechanics* are required; no
  VoiceOver or keyboard coverage percentage is committed (§9, §11).

---

## 3. Filesystem and scan semantics (the measurement contract)

*From Ticket 01, with engine detail from Ticket 03.*

### 3.1 The measure: blocks on disk, with content length beside it

*Amended by Ticket 13. This section previously fixed a single logical measure; the field
evidence against it, and the decision, are in that ticket's answer.*

- The scan represents the **blocks a file actually occupies**: the
  `URLResourceKey.fileAllocatedSizeKey` value, held as `Int64`. This is the measure the
  treemap's area, the tree's Size column, share-of-parent, and every total are computed
  from.
- **Content length is carried beside it** — the `fileSizeKey` value, likewise `Int64`,
  likewise rolled up to every ancestor. It drives nothing on screen; it explains the
  visible figure where the two diverge (§7.2).
- Both are rolled up incrementally to every ancestor on one walk, so each open directory's
  totals are live during the scan.
- **Still excluded from both:** extended attributes, resource forks, and filesystem
  metadata. Directories report no allocated size of their own and contribute zero, exactly
  as they did under the old measure.
- **Rationale:** a disk visualizer's picture has to match the disk. Measured on the field
  machine (Ticket 13), content length reports `/Users/rengwu` as 1,812 GiB where it
  occupies 277 GiB — 6.5× too big on a 460 GB disk — because sparse VM images and
  cloud-provider placeholders are counted at their full nominal length. Length is wrong in
  the other direction too: macOS compresses its own binaries, so it over-reports `/System`
  by 43%. Blocks on disk, deduplicated for hard links as §3.4 requires, land within 0.3%
  of what the volume itself reports as used.
- **The second key is free.** `fileAllocatedSizeKey` rides the batched prefetch of §5.4;
  measured overhead on a real 25,456-file tree is 0.1%, inside the noise. No extra syscall,
  no second pass.
- **Accepted residual error:** block slack. A one-byte file occupies a 4 KiB block, so a
  directory of tiny files reads slightly larger than the sum of its contents. Across
  2,529,061 files on the field machine this totalled 6.64 GiB — 2% of the true total, and
  the honest figure regardless, since the blocks are genuinely spent.

### 3.2 Units and formatting

- Display uses **binary IEC units** (KiB, MiB, GiB, TiB) at **3 significant figures**
  (`1.23 GiB`, `12.3 GiB`, `123 GiB`); the unit steps up at ≥ 1024 of the current unit.
- **`ByteCountFormatter` is disallowed for display** — even `.binary` style labels output
  "KB/MB", not the required "KiB/MiB". A **custom IEC formatter** produces display sizes;
  a locale-aware `NumberFormatter` handles digit grouping and decimal separators for the
  exact byte count and entry counts (e.g. `1,234,567 files`).
- The inspector shows the **exact grouped byte count** alongside the IEC value.
- Share-of-parent **percentages** to 1 decimal; values below 0.05% render `< 0.1%`, never
  `0.0%`. **Zero** renders `0 bytes`; the singular is handled (`1 byte`).
- **Naming the two measures (Ticket 13).** The tree's column header stays **"Size"** — in a
  disk tool that is what a size column means. The inspector labels its figure **"on disk"**
  and adds the content length as a second line **only when the two differ by more than a
  display step**, so the pair reads as a finding rather than as clutter on every ordinary
  file. No second tree column: it would be identical on ~99% of rows.

### 3.3 One root, one device

- One scan has exactly **one selected root**.
- **Eligible roots:** a folder or a volume on internal storage or directly attached
  physical storage (USB / Thunderbolt SSD or HDD). Predicate: exists, is a directory,
  `volumeIsLocalKey == true`.
- **Ineligible:** network volumes, cloud-provider roots, mounted disk images, and nested
  mounted volumes. Traversal **stays on the root's filesystem device**: the engine
  descends into a subdirectory only when its `volumeIdentifierKey` equals the root's
  (compared via `isEqual`), which makes nested mounts out-of-scope automatically.
- **The device check is not enough on APFS, and three rules do the work.** macOS reports
  one device *and* one file identity for `/` and `/System/Volumes/Data`, and hangs
  synthetic aliases of the whole filesystem off the volume root, so a scan of `/` counted
  the disk twice until ticket 12 added:
  1. a **visited-directory identity guard** — one entry per directory *opened*, keyed on
     `fileResourceIdentifierKey`; a repeat is an **exclusion**, never an error, and the
     second name stays visible and weightless with the owner's path;
  2. a **mount point inside the root's own volume is opened last and never indexed**,
     because two volume roots may share an inode number and skipping one would lose
     everything only it can reach;
  3. a **hidden subdirectory is opened after its visible siblings**, because `/.nofollow`
     is an alias of the whole filesystem that sorts before every real name.
  The probe seam therefore reads the mount table (`mountPointPaths()`, one
  `getmntinfo_r_np` per scan) as well as listings and metadata.
- **Known residual gap (§11.2):** on macOS 11 no first-party `URLResourceKey` reliably
  distinguishes a disk-image-backed volume selected *directly as the root* from an
  ordinary local volume (it reports `volumeIsLocalKey == true`). Accepted: scanning it is
  genuinely local and read-only-harmless; the load-bearing safety rules (network
  exclusion, device boundary) are fully enforced.

### 3.4 Entry-type semantics

- **Hidden files and directories are included.**
- **Symbolic links** are displayed as links but **never followed**; they receive **zero**
  attributed content bytes and cannot form a traversal loop.
- **Finder aliases that are ordinary files remain ordinary files** (normal attribution).
- **Hard links** are deduplicated by filesystem identity (`fileResourceIdentifierKey`)
  within the scan. Under a deterministic within-directory name sort, the **first in-scope
  path encountered owns the bytes**; later in-scope paths remain visible with
  **zero attributed bytes**, a "Hard link — counted elsewhere" marker, and a reference to
  the owning path when available. The scanner does **not** search outside the root for
  other names of the inode. The identity index is populated **only for `linkCount > 1`**
  (tiny index) and bypassed when the volume reports no hard-link support.
- **APFS clones are not deduplicated** — inexpensive metadata gives no exact shared-block
  attribution, so each clone contributes its own figure (distinct identities fall out as
  separate contributions automatically). **Under the §3.1 measure this over-reports**: two
  clones of one file each report their full allocated size, where under the old length
  measure they under-reported. Accepted, and the direction is recorded (Ticket 13); on the
  field volume the residual is inside the 0.3% separating the scan's total from the
  volume's own used figure.
- **macOS packages** are measured by enumerating their descendants during the initial
  scan, so their aggregate is accurate. They initially appear as **one collapsed package
  item and one treemap box**. Materializing the package's detailed child hierarchy is
  deferred to user expand/select and **must not** change the already-measured aggregate.
- **Cloud / file-provider items** count **only when already materialized locally**
  (`ubiquitousItemDownloadingStatusKey` is `.downloaded`/`.current`). Remote-only
  placeholders (`.notDownloaded`) are **omitted** and **counted as exclusions** —
  scanning **never** initiates a download or network request. An unavailable/third-party
  status safely counts the present file. **Under the §3.1 measure that case is now right on
  its own** (Ticket 13): a third-party provider's placeholder that surfaces no download
  status reports a full nominal length and **zero blocks** — ten such videos on the field
  machine reported up to 10.22 GiB each while occupying nothing — so it counts as zero,
  stays visible, and the inspector can say "10.2 GiB in length, nothing on disk". The rule
  itself is unchanged.

### 3.5 Errors, cancellation, live change

- **Recoverable errors never fail the scan and never guess sizes.** Permission failures,
  disappearing files, malformed metadata: the entry stays visible where possible, is
  marked **Unreadable** (size not guessed), every affected ancestor is marked
  **Incomplete**, and an error summary is exposed. No synthetic "Unknown" byte count is
  ever derived (e.g. by subtracting scanned totals from physical volume usage).
- **Which size decides (Ticket 13).** With two measures carried, the **on-disk figure**
  determines readability: an entry whose blocks cannot be read is Unreadable, is **never**
  given its content length as a substitute, and never enters the hard-link identity index —
  owning an inode of unknown size would zero out a later name that could be read.
- For a **whole-volume scan**, capacity and free space may be shown **separately**; they
  never become an attributed node byte count.
- **Cancellation** stops traversal promptly and **retains everything already discovered**.
  Still-open ancestors are marked incomplete; the tree and treemap remain usable for
  read-only selection, Open, and Reveal, with an unmistakable **"Incomplete — scan
  cancelled"** state and a way to start a fresh scan.
- **Live change is best-effort, not a snapshot.** Entries that vanish become recoverable
  errors; new or changed entries need not be discovered consistently; the app does
  **not** restart automatically. The user explicitly rescans for a refreshed view.

### 3.6 Representative acceptance cases (measurement)

1. A hidden 2 GiB file contributes 2 GiB and appears normally.
2. A symlink to a 2 GiB file contributes zero content bytes and is not traversed.
3. Two hard-link paths under the root contribute the file's bytes once; a
   hard-link path outside the root is neither sought nor displayed.
4. A package containing 500 MiB of descendants contributes 500 MiB while initially
   occupying one box.
5. A locally downloaded 100 MiB cloud file contributes 100 MiB; a remote-only neighbor is
   omitted and increments the exclusion count without being downloaded.
6. An unreadable child does not abort sibling traversal; its ancestors and the final
   result are Incomplete rather than falsely reported as exact.
7. Cancelling after some entries are aggregated leaves those partial results visible and
   labelled incomplete.
8. A sparse file 1 TiB in length occupying 34.6 GiB of blocks contributes **34.6 GiB**; it
   remains visible, and the inspector reports both figures (Ticket 13).

---

## 4. Architecture and project shape

*From Ticket 02.*

### 4.1 AppKit-first hybrid, macOS 11.0 floor

The Big Sur floor **forces** AppKit for the two interaction-critical panes: SwiftUI's
multi-column sortable `Table` and immediate-mode `Canvas` are macOS 12.0+, and
`NavigationSplitView` is macOS 13.0+ (verified against Apple docs metadata). The only
Big-Sur SwiftUI list (`OutlineGroup`/`List(_:children:)`) is single-column and does not
scale. Therefore:

- **Directory tree → `NSOutlineView`** (source-list styling): mature, multi-column,
  sortable, cell-reusing, scales to millions of rows.
- **Treemap → custom `NSView` with Core Graphics `draw(_:)`** (optionally a cached
  bitmap/`CALayer`) with its own hit-testing — the only way to render and hit-test
  hundreds of thousands of rectangles on the floor.
- **Shell → `NSApplicationDelegate` + programmatic `NSWindowController` hosting an
  `NSSplitViewController`.** Programmatic AppKit lifecycle (no storyboard-driven document
  app), for predictable control of the split divider, menu/first-responder validation,
  and the tree↔treemap selection sync without routing high-frequency hover/selection
  through SwiftUI state.
- **SwiftUI, used tactically** via `NSHostingController`/`NSHostingView` (macOS 10.15+,
  below the floor) for self-contained **leaf** UI only — item inspector, progress panel,
  error/exclusion summary, empty states — never on the hot path.

### 4.2 Xcode project shape

- **One macOS App target** (Swift, AppKit lifecycle, **Deployment Target macOS 11.0**),
  SwiftUI linked for interop, **`SUPPORTS_MACCATALYST=NO`**, **not** document-based.
- **Two framework-free local Swift packages** (Foundation-only, no UI framework, so they
  unit-test headlessly):
  - **`ScanCore`** — traversal, aggregation, cancellation, progress, errors (§3, §5).
  - **`TreemapLayout`** — pure rectangle layout (§6).
- **`MACOSX_DEPLOYMENT_TARGET` fixed at `11.0`** in the app target and both packages.
- Universal build: `ARCHS = arm64 x86_64`, `ONLY_ACTIVE_ARCH = NO`.

### 4.3 Concurrency and the UI-update boundary

- **Swift Concurrency back-deploys to macOS 10.15** (Xcode 13.2 release notes), so
  `async`/`await`/`Task`/`actor` are usable on Big Sur.
- **Caveat:** *system* async APIs annotated macOS 12+ remain gated even though the
  language features back-deploy. Traversal therefore uses **synchronous Foundation file
  APIs**.
- The scan runs as a **cancellable `Task` off the main thread**. Cancellation is
  cooperative (`Task.isCancelled` in the traversal loop, retaining discovered results).
- The node tree is **`actor`-isolated**; the UI reads **immutable snapshots**.
- **All UI mutation is on `@MainActor`.** Progress/incremental results are
  **coalesced/throttled** (~15 Hz scalars, ~4 Hz tree; §5.4), never per-file.
- Selection/hover sync flows through a shared **`@MainActor` selection model** (§7.2).
- Folder selection: `NSOpenPanel` with `canChooseDirectories`. Volume selection:
  `FileManager.mountedVolumeURLs(...)` filtered by volume resource keys. Reveal/Open:
  `NSWorkspace.activateFileViewerSelecting(_:)` / `open(_:)`.

### 4.4 Compatibility watch-list (must be guarded/avoided)

SwiftUI `Table` (12.0+), `Canvas` (12.0+), `NavigationSplitView` (13.0+), and
`searchable` (post-Big-Sur — use **`NSSearchField`**). A source-review guard flags these
for explicit review; compiler availability checking must reject unguarded post-Big-Sur
APIs.

### 4.5 Rejected alternatives (do not revisit)

Pure SwiftUI (Table/Canvas gated above floor); SwiftUI `App`-lifecycle shell hosting the
AppKit panes via `NSViewRepresentable` (viable but deprioritized; it is the documented
migration path *if* the floor is later raised to 12/13); Mac Catalyst (not native macOS
frameworks); cross-platform toolkits (violate the native mandate); document-based
`NSDocument` app (no persisted document in read-only v1); GCD-only concurrency
(unnecessary now that Swift Concurrency back-deploys).

---

## 5. Scan engine (`ScanCore`)

*From Ticket 03.*

### 5.1 Shape and public interface

`ScanCore` is Foundation-only. Its public surface is an **`actor Scanner`** exposing:

```swift
func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent>
```

- **`ScanRequest`** — the selected root URL, mode (folder | volume), injectable
  `DirectoryProbe`, injectable emission cadence/clock (for tests), and security-scoped
  access handle.
- **`ScanEvent`** — a state-machine event stream (§5.3).
- **`DirectoryProbe`** — the test seam: a protocol exposing **listing and metadata only**
  (no write/download/open-data method). Production adapter wraps `FileManager`;
  `ScriptedDirectoryProbe` and `TemporaryFileSystemFixture` back the tests (§9).

### 5.2 Data model and state ownership

- **`final class ScanNode`** — **name-only** (not absolute URL), parent link, children,
  `ownDiskBytes`/`subtreeDiskBytes` and `ownContentBytes`/`subtreeContentBytes` (`Int64`
  each — the two measures of §3.1, so every call site says which one it means),
  `attributedNodeCount`, `fileCount`, attribution flags, read-state, lifecycle. URLs are
  **rebuilt on demand** from the parent chain (memory bound; §8).
- The **`actor` solely owns** the mutable tree, the hard-link identity index, and the
  accumulators for the scan's duration.
- The UI reads scalar **`ProgressSnapshot`s** and **`TreeSnapshot`s** built from
  **frozen** (immutable-once-complete) subtrees **shared by reference** — cheap
  incremental delivery, no deep copies, race-free across the actor boundary.
- At terminal, the frozen tree is handed to the `@MainActor` result model **read-only**.

### 5.3 Event/state contract

State machine: **`idle → scanning → completed | cancelled | failed`**.

- Exactly **one terminal event** per scan: `.finished(ScanResult)` with reason
  `.completed` or `.cancelled`, **or** `.failed`.
- `.failed` is emitted **only** for a **pre-flight root-eligibility failure** (§3.3
  predicate). **Every mid-scan filesystem problem is recorded and traversal continues.**
- `.started` is emitted only after the root passes pre-flight.
- `ScanResult` always carries a **full immutable tree** plus `completeness`, an error
  summary, an exclusion summary, and (volume scans) **separate capacity/free**.
- Exactly **one active scan**; starting a replacement cancels the current one and begins
  only after the current scan's terminal `.finished(.cancelled)`.

### 5.4 Traversal algorithm (the load-bearing decisions)

- **Serial, iterative, depth-first** over an **explicit LIFO stack** (no recursion depth
  limit), on the actor's executor. Serial because:
  - hard-link "first path" ownership is only well-defined under a deterministic order
    (stable within-directory name sort);
  - it removes all locking from the hot path (identity index, accumulators, roll-up);
  - it matches single-device I/O reality. Parallelism is **deferred with a defined seam**,
    not designed out.
- **Shallow listing, not the deep enumerator.** `FileManager.enumerator(at:…)`
  *"traverses the mount point"*, which would silently leave the root device. The engine
  recurses itself over shallow **`contentsOfDirectory(at:includingPropertiesForKeys:
  options:)`** with **prefetched URL resource keys**, and descends into a subdirectory
  only when its `volumeIdentifierKey == root`'s (§3.3).
- **The measure:** `fileAllocatedSizeKey` (blocks on disk), with `fileSizeKey` (content
  length) carried beside it; both rolled up incrementally to every ancestor on one walk
  (§3.1, Ticket 13).

### 5.5 Progress

- **Indeterminate primary progress** with live telemetry: attributed bytes, files/dirs
  seen, current path, elapsed, **items per second**.
- **The rate shown is items per second, never bytes per second (Ticket 13).** The scanner
  reads directory listings and never file contents, so a byte rate here is not a disk speed
  and will be read as one — the field build displayed *2.91 GiB/s*, a figure no disk on that
  machine can produce. Items per second is the only rate on the card that is a measurement
  of what the scan actually does.
- An **explicitly approximate** completion fraction **only for whole-volume scans**
  (attributed on-disk bytes ÷ volume-used — the same quantity on both sides since §3.1);
  a **synthetic byte figure never enters the tree**. Folder scans have **no** fraction
  (`nil`).
- **No state claims 100% before a scan ends (Ticket 13).** The fraction is capped at **99%**
  while a scan is running, and is **withdrawn** (`nil`) for the remainder of a scan whose
  counted total passes the volume's used figure — clones and snapshots make that reachable —
  leaving the card on counted total, item count and elapsed. Only a *finished* scan may
  report 1.0.
- **A finished whole-volume scan reconciles out loud**: the counted total is shown against
  the volume's used figure ("333 GB counted · 332 GB used"). Agreement is evidence the
  picture is real; disagreement means something was unreadable or skipped, which is when the
  user most needs to know the map is incomplete.
- Emissions are coalesced/throttled: **≤ ~15 Hz scalars, ≤ ~4 Hz tree**, buffering-newest,
  no per-entry backlog; **immediate exact final snapshot** at terminal. Cadence is
  configurable to 0/∞ for deterministic tests.

### 5.6 Cancellation

- Cooperative `Task.isCancelled`, checked **per-directory and per-256-entry batch** — a
  worst-case operation bound independent of tree size (**not** a millisecond SLA).
- On cancel: still-open ancestors → Incomplete; the tree is **frozen and fully
  retained/browsable**; a final exact snapshot + `.finished(.cancelled)` is emitted.
- **`withTaskCancellationHandler` guarantees security-scoped access is released exactly
  once** (on success, failure, cancellation, and replacement).

### 5.7 Errors, bounds, and read-only guarantee

- Recoverable errors (unreadable dir/entry, disappearance, malformed metadata) never
  fail the scan and never guess sizes: entry → **Unreadable**, ancestors → **Incomplete**,
  a **capped** error summary is exposed, and category counts are **exact**.
- **Bounded error detail:** retain up to **1,000** detailed records (name + reason);
  beyond that keep only the exact running total (`truncated == true`), so an error storm
  cannot blow the memory ceiling.
- **No file contents are ever read.** Memory is dominated by the inherent node tree
  (bounded via name-only nodes; URLs rebuilt on demand); working set, hard-link index,
  and error details are all bounded.

---

## 6. Treemap layout and visual encoding (`TreemapLayout` + treemap view)

*From Ticket 05, **reconciled with Ticket 06** (see §11.1). The reconciled rule below is
authoritative.*

The layout is a **pure function of `(tree, viewport size)`**, so it is
snapshot/geometry-testable. Rendered **classic flat** (WinDirStat-style, human-accepted):
zero per-level insets, leaves tiling the area, hierarchy shown by outlines overdrawn per
depth.

### 6.1 Geometry

- **Algorithm:** recursive **squarified** treemap (Bruls, Huizing, van Wijk), applied per
  directory. Children enter the layout sorted **bytes descending, ties by name ascending
  (code-point order)** — this sort is part of the spec, so identical trees always produce
  identical rectangles.
- **Area:** **strictly proportional to attributed on-disk bytes** (§3.1). **No** log
  scaling, minimum-area cheating, or synthetic "other" box (beyond the exact merge bucket
  in §6.2).
- **Precision:** layout in **unrounded points**; snap to the pixel grid **only at draw
  time** via the backing scale factor; no cumulative integer rounding.
- **Insets (classic flat, accepted):** none — children tile 100% of their directory's
  rectangle. Hierarchy is a **post-pass**: a directory region below the root gets a
  **1 pt outline** for the **first three levels only** (ticket 01 — deeper strokes overdraw
  a strip the fills already bound, with no visible difference), with **0.5 pt hairlines**
  between sibling leaves.

### 6.2 The merge rule — "merge, never disappear" (supersedes §05 culling)

The treemap is **always area-truthful, and nothing with real bytes disappears.**

- **No minimum-area drop / no culling-to-background.** Within each directory, all children
  whose individual squarified rectangle would fall **below 2×2 pt** are **merged into
  exactly one aggregate box** per directory, whose area equals the **exact sum** of their
  attributed bytes. (2×2 pt is the **merge** trigger, not a *drop* trigger.)
- The trigger applies to any child — a leaf **or** an entire too-small subtree — so a
  collectively-tiny directory folds into its parent's single aggregate box.
- **The rule iterates to a fixpoint** (ticket 01): folding children into the aggregate
  enlarges it and re-flows the row, which can push a previously-adequate sibling under the
  trigger, so the pass repeats until no survivor is below it (capped at 8 rounds — the
  worst case measured across all four bench fixtures was 5).
- **The aggregate box is pinned last** in its directory's child order, so the fixpoint is
  stable and the box lands in the same corner every time.
- **Distinct fill:** the aggregate box uses a **neutral, visibly different fill** (e.g. a
  subtle hatch), **not** any single kind-hue, so it reads as "combined," not one file.
- **Selectable and honest:** the aggregate box is **hit-testable**; its tooltip/inspector
  report *"N items below individual size, combined X"*; **every individual item remains
  fully listed and selectable in the tree**, which always enumerates everything.
- **Total area truthfulness:** visible rendered area (individual + aggregate boxes) =
  **100%** of attributed bytes, with no empty directory-background gaps.
- **Zero-attributed-byte items** (empty files, symlinks, hard-link non-owners, unreadable
  entries with unknowable size) still get **no rectangle** (they have no area) but
  **never vanish from the product** — they remain in the tree and inspector.
- **Render/relayout is bounded by the count of *visible* boxes** (individual + aggregate),
  not by total node count, so all workload rungs (including Stress) stay drawable. The
  treemap **does not** promise per-entry visibility; per-entry access is via the
  synchronized tree. **That is the stated tradeoff.**

### 6.3 Visual encoding

- **Color:** fixed **extension → kind-group → hue** table (**11 groups** — code, image,
  video, audio, document, archive, app, diskimage, font, data, system — plus gray
  "other"), HSL with **lightness adapted for dark mode**. Same extension → same color
  every run. Legend lives in the **status bar** (§7.1). Exact hues are tunable constants.
- **Directory vs file:** directories contribute **no fill of their own** (their area is
  composed of children; their region is the overdrawn outline). Files carry the kind
  color. Packages remain **one leaf box** (§3.4).
- **Incomplete** directories get a **red diagonal hatch overlay**; an unreadable leaf has
  no rect and is marked Unreadable in the tree.
- **Labels:** leaf name at **11 pt only when the rect is ≥ 48×15 pt**, ellipsis-truncated,
  drawn with a contrast halo. Directories are **unlabeled** in the flat variant (names
  live in the tree/tooltip/inspector).
- **Hover:** **1 pt** high-contrast stroke + tooltip (name, IEC size **and** exact grouped
  bytes, full path, Ticket-01 flags, and the aggregate summary for a merge box).
- **Selection:** single selection **shared with the tree** (§7.2); the selected rect gets
  a **2 pt system-accent stroke inset 1 pt**; selecting a directory outlines its whole
  region.

### 6.4 Hit testing, resize, extremes

- **Hit testing:** the **deepest rendered node** whose frame contains the point wins
  (parents precede children in draw order; last match wins — deterministic because
  sibling rects are disjoint). A merge-box interior returns the **aggregate**;
  zero-byte/unrendered items are not hit-testable in the map (reachable via the tree).
- **Resizing:** **full recompute** from `(tree, viewport)` on every size change — **no
  cache, no animation, no hysteresis** — coalesced to display refresh during divider
  drags. Determinism makes geometry tests a golden-rect list per fixture tree.
- **Extreme distributions:** descending-order squarified keeps aspect ratios sane under
  10⁴:1 skew; the tiny tail folds into the per-directory aggregate; deep chains (≥14–20+
  levels) degrade to strips — inherent to the data shape, acceptable, truthful.

---

## 7. Workspace and interaction model

*From Ticket 04 (accepted layout: the three-pane split, chosen by a human from a live
reaction to three variants). The other two variants and the variant switcher are
prototype-only and must **not** enter the implementation map's main code.*

### 7.1 Shell and chrome

- **`NSSplitViewController` with three split items:**
  - **Left** — directory tree (`NSOutlineView`, source-list styling).
  - **Center** — treemap (the **growable** item).
  - **Right** — inspector (fixed **~300 pt**, **collapsible**).
- **Unified toolbar.** **Bottom status bar** carries: scanned on-disk total; file + folder
  counts; (volumes only) capacity & free, and the counted-against-used reconciliation;
  error & exclusion counts; and the **size-color legend**, which appears only once a scan
  has colour to explain. The counts are **tree-visible** — what the panes are showing —
  not the scanner's enumeration, so a package contributes one item until it is drilled
  into (ticket 01, decision 10). The inspector's "Contains" row deliberately answers the
  other question.
- **Chooser:** a toolbar **"Choose…"** sheet listing eligible sources (internal +
  directly-attached drives, plus "choose folder…" via `NSOpenPanel
  canChooseDirectories`). Ineligible sources are **absent rather than shown disabled with
  a reason** (ticket 01). Esc dismisses.
- **Empty state:** centered call-to-action (not a blank window). The read-only and
  scan-scope disclosures were **cut** (ticket 01) — see §11 for the consequence a human
  accepted knowingly: a user whose network volume is simply missing from the chooser is
  given no reason for it.
- **Scanning state:** centered progress card — indeterminate bar (a coarse, explicitly
  approximate % **only** for whole-volume scans), live telemetry (measured bytes, files,
  folders, elapsed, current path), a **prominent Cancel**. Tree and treemap populate
  incrementally behind it.
- **Read-only actions:** **Open** (`NSWorkspace.open`) and **Reveal in Finder**
  (`activateFileViewerSelecting`) in the toolbar and inspector. **No mutation affordance
  anywhere** — no Delete/Clean/Move in menus, context menus, toolbar, or accessibility
  tree.

### 7.2 Interaction rules

- **Synchronized selection is bidirectional and single-source** through **one shared
  `@MainActor` selection model:** selecting a tree row highlights its treemap rectangle (a
  directory highlights its whole region) and fills the inspector; clicking a treemap
  rectangle selects and scrolls-to the tree row and fills the inspector. Selecting a
  zero-byte tree row produces **no false rectangle**; selecting an aggregate box describes
  the bucket **without inventing an individual node**.
- **Keyboard:** ↑/↓ move the tree selection; **⌘O = Open, ⌘R = Reveal**, Return =
  expand/open; Esc dismisses the chooser. (The prototype's ←/→ variant switcher ships
  **hidden/absent**.)
- **Resizing:** every split divider drags; the treemap re-layouts live; the inspector can
  collapse; selection persists through relayout.

### 7.3 Lifecycle-state legibility

- **Empty**, **Choosing**, **Scanning** — as above.
- **Completed** — normal status bar.
- **Cancelled** — an **"● Incomplete — scan cancelled" chip at the head of the status
  bar**, not a banner (ticket 01: a banner costs a pane's worth of height to say one
  sentence). Partial results are retained as fully browsable/selectable, and Choose… is
  always available for a fresh scan.
- **Partially failed ("Completed with errors")** — the unreadable entry marked
  **Unreadable** (size never guessed), every affected ancestor **Incomplete**, an error
  summary + an **excluded-cloud-items count** surfaced. Ticket-01 semantics shown
  concretely per item: symlink (0 bytes, "never followed"), hard link ("counted
  elsewhere" + owner path), iCloud materialized-vs-omitted, package as one box.
- **Where the error summary lives:** the status bar carries the counts; the inspector
  describes the scan itself **while nothing is selected**, naming the first five paths
  that could not be read with "…and N more", the counts by reason, and which of the two
  kinds makes a total a lower bound. A scan that read everything says nothing there.

---

## 8. Quality bars — performance, memory, resilience

*From Ticket 06. All numbers are quoted against the reference hardware below.*

### 8.1 Reference hardware and workload ladder

- **Performance-reference machine:** Apple Silicon **M1, 8 GB** unified memory, NVMe SSD.
  Every performance and memory expectation is stated on this machine.
- **Compatibility floor:** a **2015-era dual-core Intel Mac, 8 GB RAM, SATA SSD**
  (representative oldest-supported macOS 11 host). On the floor we guarantee
  **correctness, no-crash, and a non-frozen UI only** — **never a speed number** (scan
  speed there is disk-I/O-bound and outside our control).
- **Workload ladder** (entries = files + directories), scan-performance fixtures distinct
  from §6's render datasets:
  - **Smoke** — ~1–5k entries, < 1 GiB. Inner test loop.
  - **Representative** — ~300–500k entries, ~150–250 GiB. **The anchor rung.**
  - **Large** — ~2M entries, ~1 TiB. Bars: "no catastrophic degradation, still usable."
  - **Stress** — pathological *shapes* (one flat 100k-entry dir; ≥20-level chain; one
    ~40 GiB file beside thousands of tiny ones; thousands of hard links; thousands of
    unreadable/vanishing entries). Bars: correctness + no-crash + memory-bounded only.

### 8.2 Performance — algorithmic, not wall-clock

- **No second-count / completion-time SLA.** Disk throughput is best-effort and
  **explicitly disk-bound**. We optimize what we own — the algorithm and I/O batching —
  and refuse to be measured on disk speed we do not own.
- Commitment: **single-pass, streaming, iterative DFS** with prefetched resource keys and
  no redundant metadata reads; **results appear incrementally** as discovered, never
  batched until the end.

### 8.3 UI responsiveness & cancellation — noted, not bars

Recorded for later tuning, **not** MVP acceptance bars; the architectural invariants from
§4/§5 still stand: off-main cancellable `Task`; coalesced/throttled updates; cooperative
per-directory / per-256-entry cancellation retaining partial results. **No p99 /
millisecond latency threshold is committed.**

### 8.4 Memory

- **Hard ceiling:** total resident memory **stays within the 8 GB reference machine and
  never OOMs**, at every rung including Large and Stress. This is the single memory
  acceptance bar ("fits in 8 GB, never OOM").
- **How held (from §5, not reopened):** name-only `ScanNode`s; URLs rebuilt on demand;
  hard-link index only for `linkCount > 1`; no file contents read; UI snapshots share
  frozen subtrees by reference (O(1) per update, no deep copies).
- Representative is expected order hundreds of MB (diagnostic, not a threshold); Large is
  expected comfortably within 8 GB.

### 8.5 Resilience

- **Zero crashes** across the resilience fixture matrix: permission-denied directory,
  unreadable file, mid-scan deletion (vanishing entry), cloud placeholder (omitted +
  counted), hard-link duplicate, and one huge flat directory.
- The scan still reaches **`.completed`** on that matrix, with every recoverable error
  represented (entry → Unreadable, ancestors → Incomplete, size never guessed) and
  **exact** total error and exclusion counts.
- **Bounded error detail:** ≤ **1,000** detailed records, then exact running total only.
- Pre-flight root-eligibility failure ⇒ `.failed`; every mid-scan filesystem problem ⇒
  recorded and traversal continues.

### 8.6 Formatting bars

As §3.2: custom IEC formatter at 3 sig figs; `ByteCountFormatter` disallowed for display;
locale-aware grouping via `NumberFormatter`; exact grouped bytes in the inspector;
percentages to 1 decimal with `< 0.1%` floor; `0 bytes` / `1 byte` handled.

---

## 9. Verification and acceptance

*From Ticket 07. This is a layered release gate; the implementation map must create these
targets, schemes, and test plans.* The scanner is **read-only in every verification run**;
tests stage only a uniquely owned fixture directory, never an existing user directory.

### 9.1 Test targets and gates

| Target / gate | Responsibility | Cadence |
| --- | --- | --- |
| `ScanCoreTests` | Pure scanner: fake `DirectoryProbe`, virtual clock, event/state, aggregation, errors, cancellation | Every change |
| `ScanCoreFileSystemTests` | Production `FileManager` probe vs a small temporary tree | Every change on macOS |
| `TreemapLayoutTests` | Pure geometry, merge buckets, hit testing, palette classification | Every change |
| `MacDirStatTests` | `@MainActor` presentation models, formatting, chooser policy, selection, workspace-action spies | Every change |
| `MacDirStatUITests` | Lifecycle states, three-pane wiring, keyboard, resizing, accessibility surface | Every change on macOS; screenshots reviewed when changed |
| `MacDirStatPerformanceTests` | Generated Smoke/Representative/Large/Stress scans, peak RSS, operation counts, relayout bounds | Opt-in before an RC on the reference machine |
| Compatibility matrix | Universal build + launch/workflow smoke on every supported major macOS | Before declaring an RC compatible |

- Shared schemes/test plans: **`MacDirStat-CI`** (every target except performance —
  the one-command local gate), **`MacDirStat-Performance`** (Release-config, scale +
  stress only), **`MacDirStat-CompatibilitySmoke`** (launch, folder scan,
  incremental-result, cancel, selection, Open/Reveal-spy, partially-failed checks).
- An RC must pass `MacDirStat-CI` with **Thread Sanitizer once** as an additional
  diagnostic run; performance runs **without** sanitizers (instrumentation perturbs
  memory/timing).
- Intended local commands (repository root):

```sh
swift test --package-path Packages/ScanCore
swift test --package-path Packages/TreemapLayout
xcodebuild test -project MacDirStat.xcodeproj -scheme MacDirStat-CI -testPlan CI -destination 'platform=macOS'
xcodebuild build -project MacDirStat.xcodeproj -scheme MacDirStat -configuration Release -destination 'generic/platform=macOS' ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=11.0
xcodebuild test -project MacDirStat.xcodeproj -scheme MacDirStat-Performance -configuration Release -destination 'platform=macOS'
```

These package paths, project, schemes, and `CI.xctestplan` are part of the contract, not
descriptions of files that already exist in the planning map.

### 9.2 Fixtures

Two fixture adapters share one logical manifest:

1. **`ScriptedDirectoryProbe`** supplies `EntryMeta` and injected failures directly —
   authoritative for cases the host filesystem cannot stage reliably (different volume
   identifiers, cloud download status, malformed metadata, deterministic disappearance,
   security-scope denial, exact cancellation checkpoints, error storms). It **records
   every list/metadata request** so tests can prove no boundary crossing and no redundant
   reads.
2. **`TemporaryFileSystemFixture`** creates a fresh child of the test temp dir, writes an
   ownership **sentinel**, scans with the production probe, and **fingerprints before and
   after**. Cleanup verifies both sentinel and resolved path and **refuses to delete any
   other directory**; it restores permission bits even after a failed test.

Generation is versioned **`fixture-v1`, seed `0x4D4453`**; each manifest records generator
version, seed, entry count, exact attributed bytes, expected node-tree digest,
error/exclusion totals, and hard-link owner paths. **A manifest states both §3.1 measures**,
because sparse files give multi-GiB content lengths without allocating contents, and the
sparse entries are exactly where the two diverge — the §9.2 fixture's sparse hidden file
pins its attributed bytes to its *allocated* size, so a later change cannot silently move
the measure (Ticket 13). Scale rungs: Smoke 4,096 entries / 768 MiB;
Representative 400,000 / 200 GiB; Large 2,000,000 / 1 TiB; Stress the four shapes (flat
100k; depth 64; 40 GiB + 10,000 tiny; 10,000 links; 2,500 injected failures). Wall-clock
time is reported **for context only**, never a pass/fail threshold.

The fingerprint compares relative path, item kind, logical length, mode, mtime, symlink
target, inode/link count, and hashes of small non-sparse contents; **access time is
excluded**. No test invokes a cloud download, reads file contents through the scanner, or
mounts/unmounts a volume. A **spy security-scope adapter** proves access is balanced
exactly once on success, failure, cancellation, and replacement.

### 9.3 Traceability (the acceptance matrix)

Every settled contract has an automated proof. The full traceability tables live in
[Ticket 07](./tickets/07-design-verification-strategy.md) (scanner/filesystem; treemap/
formatting; app/UI/read-only). Load-bearing acceptance criteria:

- **Read-only proven three ways:** real-fixture fingerprint unchanged; scanner
  dependencies expose no write/download method; workspace actions call only `open`/`reveal`
  spies with the selected URL, and UI asserts no mutation command exists anywhere.
- **One device only:** a child with a different `volumeIdentifier` gets **no list call**
  beneath it, one boundary exclusion, no attributed descendants.
- **Deterministic serial DFS:** request log + depth-64 fixture prove LIFO traversal
  without recursion failure; identical runs → identical node order and hard-link owner.
- **Merge, not cull:** every child below 2×2 pt goes into exactly one per-directory
  aggregate; its byte total and recursive item count are exact; it is hit-testable;
  visible individual + aggregate area = **100% of nonzero bytes**. **This is the expected
  result wherever it conflicts with §05's earlier culling rule.**
- **Zero-byte items:** empty/symlink/hard-link-non-owner/unknowable-unreadable produce
  **no geometry** but are found and selected in the tree with inspector data.
- **Progress honesty:** virtual clock proves ≤15 Hz scalar / ≤4 Hz tree, buffering-newest,
  immediate exact final snapshot; folder fraction always `nil`; volume fraction labelled
  approximate, clamped, never in a tree total.
- **Cancellation is an operation bound:** a barrier probe cancels immediately before each
  checkpoint and records ≤ one additional listing/batch; open ancestors → Incomplete; all
  discovered nodes remain; final reason `.cancelled`; security access stops exactly once.
  **Not a millisecond SLA.**
- **Error bounds:** inject 2,500 failures → exact total 2,500, first 1,000 detailed
  records, `truncated == true`.
- **Formatting:** locale-fixed unit tests over 0/1/1023/1024/every boundary through TiB,
  rounding carry, 3 sig figs; `en_US` + a comma-decimal locale prove grouping without
  changing KiB labels; percent tests cover 0 / <0.05% / exactly 0.05% / ordinary / 100%,
  one decimal, `< 0.1%` not `0.0%`.
- **Performance/memory (opt-in, reference machine, Release, no sanitizer):** one shallow
  list per traversed directory, no device-boundary descent, no content reads, no duplicate
  metadata fetch; operation counts scale with entries + ancestor depth, not total bytes;
  barriers at 25/50/75% prove incremental results; frozen subtrees shared not deep-copied;
  Representative/Large/each Stress shape finish **without allocation failure or crash and
  below 8 GiB peak RSS**; treemap visible-box count bounded by viewport/merge policy.
- **Compatibility matrix (before RC):** universal Release build succeeds for `x86_64` +
  `arm64`; compiler availability rejects unguarded post-Big-Sur APIs; a source-review
  guard flags `SwiftUI.Table`/`Canvas`/`NavigationSplitView`/`searchable`.
  `MacDirStat-CompatibilitySmoke` runs on **at least one host per major macOS from 11
  through current stable**, mandatory endpoints **Big Sur 11.7.x on the 2015 Intel floor**
  and **current stable macOS on Apple Silicon**, each record capturing exact OS/build,
  arch, hardware/VM, artifact commit, and pass/fail for launch, Smoke totals, incremental
  updates, cancel/retained results, partial errors, treemap selection, keyboard commands,
  and disposable-file Open/Reveal. **A deployment-target build is necessary but not
  accepted as a substitute for running on Big Sur.**

### 9.4 Accessibility mechanics (required; no coverage threshold — §11.3)

- One accessibility child per **labelled** rectangle — the leaves at or above the 48×15 pt
  label threshold (§6.3), aggregates included — plus the selected rectangle whatever its
  size. Subdivided directory regions are not published: they carry no label and no click
  selects one, and the tree pane already exposes every node with its hierarchy. Publishing
  every rectangle instead cost a screen-reader client **7–8 s of main thread** on a
  whole-volume map, because an accessibility client's questions are answered there; the
  labelled leaves do not overlap, so their number is bounded by viewport area over
  48×15 pt regardless of how many entries the scan holds.
- Deterministic draw order, labels containing name/size/kind (or combined count/size for a
  merge box), focusability, selected state, and an
  `NSAccessibilityAnnouncementNotification` when shared selection changes.
- Kind is written in tooltip/inspector/legend and **Incomplete** uses hatch **plus** text,
  so neither color nor hatch alone carries meaning; keyboard navigation lives in the tree,
  the treemap is focusable and follows the shared selection.
- The release checklist performs **one VoiceOver + Accessibility Inspector walkthrough** of
  empty/scanning/selected-file/directory/aggregate/cancelled/error states on Big Sur and
  current macOS, recording defects but applying **no pass-percentage or task-coverage
  threshold**.

---

## 10. Subsystem interface contract (the seams)

The wiring between subsystems, so an implementation session can parallelize:

- **`ScanCore` → app model.** `Scanner.scan(ScanRequest) -> AsyncStream<ScanEvent>`. The
  app model consumes events on `@MainActor`, holding the latest `ProgressSnapshot` /
  `TreeSnapshot`, and at terminal takes the read-only frozen `ScanResult` tree. `ScanCore`
  imports Foundation only; it knows nothing of AppKit/SwiftUI.
- **`TreemapLayout` ← tree snapshot + viewport.** `layout(tree, viewportSize) ->
  [PlacedRect]` (individual + per-directory aggregate boxes), a pure function. The treemap
  `NSView` renders and hit-tests these rects; it never mutates the tree. `TreemapLayout`
  imports Foundation only.
- **Shared selection model (`@MainActor`).** One source of truth referencing a node
  identity (or an aggregate-box descriptor). Both the `NSOutlineView` tree and the treemap
  view observe and write it; each maps identity ↔ its own representation. Zero-byte nodes
  and aggregate boxes are representable as selections (§7.2).
- **Workspace adapter (`@MainActor`).** A protocol wrapping `NSWorkspace.open` /
  `activateFileViewerSelecting`, injectable so tests substitute a spy. Reconstructs the
  absolute URL from a node's parent chain on demand.
- **`DirectoryProbe` (in `ScanCore`).** Listing + metadata only; production `FileManager`
  adapter, scripted/temporary-fixture adapters for tests. **No** write/download/open-data
  method exists on the protocol — read-only is structural.
- **Security-scoped access.** Started at pre-flight (root eligibility), released exactly
  once via `withTaskCancellationHandler` on every terminal path; a spy proves the balance.

---

## 11. Reconciled contradictions and known gaps

The map tasked this ticket with reconciling contradictions without inventing product
decisions. Three items were flagged by prior tickets:

### 11.1 Treemap sub-2×2 pt content — RESOLVED in favor of Ticket 06 (merge)

Ticket 05 originally specified **render-only culling** below 2×2 pt (item dropped from
render/hit-testing → directory background shows through → hover hits the directory).
Ticket 06 **supersedes** this with the **merge** policy: sub-2×2 pt children fold into
**exactly one per-directory, exactly-sized, hit-testable aggregate box** with a neutral
"combined" fill; area truthfulness reaches 100%; every item stays in the tree. **This
specification adopts the merge policy (§6.2) as the single reconciled rule.** (Ticket 05's
`undermined_by` carries `06` to mark this; only a human may formally revise Ticket 05's
prose. This spec is the reconciliation the map's Done-when requires.)

### 11.2 Disk-image root detection — ACCEPTED residual gap

On macOS 11 there is no settled first-party `URLResourceKey` that reliably identifies a
disk-image-backed volume **selected directly as the root** (it reports `volumeIsLocalKey
== true`). Accepted (Ticket 03 recommendation): scanning it is genuinely local and
read-only-harmless, and the load-bearing safety rules — network exclusion and the device
boundary — are fully enforced. The **chooser** can disable a source already classified as
a disk image, but the production classifier cannot claim to detect **every** directly
mounted disk image. This is a known, bounded gap, not a defect to fix in v1.

### 11.3 Accessibility coverage — DEFERRED gap (explicit)

Ticket 06 deliberately sets **no** measurable VoiceOver or keyboard-coverage bar; Tickets
07 and 08 inherit the gap. The a11y **mechanics** are required and specified (§6.3, §9.4);
**no coverage percentage or task-coverage threshold is committed** in v1. This is a known,
deliberate hole for a later session to fill, not an oversight.

Additionally, several presentation details are **deferred within v1** (§2): exact tree
columns/sort, final inspector field set, package drill-in interaction, progress-cadence
copy, and exact palette hues. None blocks implementation; each has a fixed enclosing
behavior.

---

## 12. Acceptance criteria (implementation-ready checklist)

The first implementation is accepted when all of the following hold:

1. **Builds and runs** as a universal (`arm64` + `x86_64`) macOS 11.0 app in Xcode; the
   `MacDirStat-CI` scheme passes (incl. one Thread Sanitizer run); the universal Release
   build succeeds; the compatibility smoke passes on the Big Sur/2015-Intel floor and
   current-stable/Apple-Silicon endpoints (§9).
2. **Measurement is correct and honest:** all eight §3.6 cases pass; `fileAllocatedSizeKey`
   bytes drive every visible figure and `fileSizeKey` is carried beside them (§3.1); hidden
   included; symlinks 0 bytes and not followed; hard
   links counted once with owner reference; APFS clones each counted; packages measured
   recursively yet one box; only materialized cloud items counted with exact exclusion
   count; unreadable → Unreadable + ancestors Incomplete, size never guessed; no synthetic
   "Unknown."
3. **One root, one device:** eligibility predicate enforced; traversal never crosses a
   `volumeIdentifier` boundary; ineligible sources shown disabled with reasons.
4. **Engine contract:** `Scanner.scan → AsyncStream<ScanEvent>`; serial iterative DFS over
   shallow `contentsOfDirectory`; `.failed` only pre-flight; exactly one terminal event;
   one active scan; frozen structurally-shared snapshots; coalesced ≤15 Hz/≤4 Hz progress;
   cooperative per-directory/per-256-entry cancellation retaining partial results;
   security access balanced exactly once; ≤1,000 bounded error records.
5. **Treemap:** recursive squarified, deterministic (bytes desc, name asc code-point);
   area strictly ∝ on-disk bytes; classic-flat rendering; **merge (not cull)** for
   sub-2×2 pt content with 100% area truthfulness; zero-byte items no rect but in tree;
   fixed kind palette + status-bar legend; labels ≥48×15 pt; hover/selection strokes;
   deepest-node hit testing; pure recompute on resize.
6. **Workspace:** three-pane split (tree │ treemap │ inspector) with unified toolbar and
   status bar; chooser sheet; all six lifecycle states legible incl. cancelled and
   completed-with-errors banners; bidirectional single-source selection; ⌘O/⌘R; read-only
   throughout with **no** mutation affordance anywhere.
7. **Quality bars:** fits in 8 GB and never OOMs on Representative/Large/Stress; zero
   crashes on the resilience matrix reaching `.completed` with exact counts; incremental
   results; IEC/locale formatting exact. **No** wall-clock, latency, or a11y-coverage
   threshold is asserted.
8. **Verification:** every traceability row in §9.3 / Ticket 07 has a passing automated
   proof (or a recorded manual check where specified); read-only proven by fixture
   fingerprint + no-write-method + action spies.

---

## 13. Next step

With this specification settled, **a separate implementation map can now be charted** at
`.plan/maps/macos-disk-visualizer-impl/`, per the planning map's "plan, don't do" rule.
That map decomposes this contract into concrete build tickets — the `ScanCore` and
`TreemapLayout` packages, the AppKit shell and three panes, the shared selection and
workspace adapters, and the test targets/schemes/fixtures of §9 — sequenced along the
subsystem seams in §10. No material product or technical choice from this specification is
left open for an implementation session.
