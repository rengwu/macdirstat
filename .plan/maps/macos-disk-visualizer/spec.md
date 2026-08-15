# macOS Disk Visualizer — Implementation-Ready Specification

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
proportional to logical bytes, sizes are never guessed, partial and failed scans stay
truthful and browsable, and nothing with real bytes ever disappears from the picture.

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

### 3.1 The one measure: logical content bytes

- The scan represents the **ordinary logical length of locally present file content**:
  the `URLResourceKey.fileSizeKey` value, held as `Int64`.
- **Excluded from the measure:** extended attributes, resource forks, filesystem
  metadata, sparse-file allocation, compression savings, and APFS shared-clone
  allocation. `totalFileAllocatedSizeKey` and any block/allocation figure are **never
  read**.
- Rectangle area and directory totals use this one measure, rolled up incrementally to
  every ancestor so each open directory's total is live during the scan.
- **Rationale (intentional tradeoff):** a cheap, consistent, performant content-size view
  is preferred over an estimate of physical blocks consumed.

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

### 3.3 One root, one device

- One scan has exactly **one selected root**.
- **Eligible roots:** a folder or a volume on internal storage or directly attached
  physical storage (USB / Thunderbolt SSD or HDD). Predicate: exists, is a directory,
  `volumeIsLocalKey == true`.
- **Ineligible:** network volumes, cloud-provider roots, mounted disk images, and nested
  mounted volumes. Traversal **stays on the root's filesystem device**: the engine
  descends into a subdirectory only when its `volumeIdentifierKey` equals the root's
  (compared via `isEqual`), which makes nested mounts out-of-scope automatically.
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
  path encountered owns the logical bytes**; later in-scope paths remain visible with
  **zero attributed bytes**, a "Hard link — counted elsewhere" marker, and a reference to
  the owning path when available. The scanner does **not** search outside the root for
  other names of the inode. The identity index is populated **only for `linkCount > 1`**
  (tiny index) and bypassed when the volume reports no hard-link support.
- **APFS clones are not deduplicated** — inexpensive metadata gives no exact shared-block
  attribution, so each clone contributes its ordinary logical length (distinct
  identities fall out as separate contributions automatically).
- **macOS packages** are measured by enumerating their descendants during the initial
  scan, so their aggregate is accurate. They initially appear as **one collapsed package
  item and one treemap box**. Materializing the package's detailed child hierarchy is
  deferred to user expand/select and **must not** change the already-measured aggregate.
- **Cloud / file-provider items** count **only when already materialized locally**
  (`ubiquitousItemDownloadingStatusKey` is `.downloaded`/`.current`). Remote-only
  placeholders (`.notDownloaded`) are **omitted** and **counted as exclusions** —
  scanning **never** initiates a download or network request. An unavailable/third-party
  status safely counts the present logical file.

### 3.5 Errors, cancellation, live change

- **Recoverable errors never fail the scan and never guess sizes.** Permission failures,
  disappearing files, malformed metadata: the entry stays visible where possible, is
  marked **Unreadable** (size not guessed), every affected ancestor is marked
  **Incomplete**, and an error summary is exposed. No synthetic "Unknown" byte count is
  ever derived (e.g. by subtracting logical totals from physical volume usage).
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
3. Two hard-link paths under the root contribute the file's logical bytes once; a
   hard-link path outside the root is neither sought nor displayed.
4. A package containing 500 MiB of descendants contributes 500 MiB while initially
   occupying one box.
5. A locally downloaded 100 MiB cloud file contributes 100 MiB; a remote-only neighbor is
   omitted and increments the exclusion count without being downloaded.
6. An unreadable child does not abort sibling traversal; its ancestors and the final
   result are Incomplete rather than falsely reported as exact.
7. Cancelling after some entries are aggregated leaves those partial results visible and
   labelled incomplete.

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
  `ownBytes`/`subtreeBytes` (`Int64`), attribution flags, read-state, lifecycle. URLs are
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
- **One measure:** `fileSizeKey` (logical), rolled up incrementally to every ancestor.

### 5.5 Progress

- **Indeterminate primary progress** with live telemetry: attributed bytes, files/dirs
  seen, current path, elapsed, throughput.
- An **explicitly approximate** completion fraction **only for whole-volume scans**
  (attributed bytes ÷ volume-used); a **synthetic byte figure never enters the tree**.
  Folder scans have **no** fraction (`nil`).
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
- **Area:** **strictly proportional to attributed logical bytes** (§3.1). **No** log
  scaling, minimum-area cheating, or synthetic "other" box (beyond the exact merge bucket
  in §6.2).
- **Precision:** layout in **unrounded points**; snap to the pixel grid **only at draw
  time** via the backing scale factor; no cumulative integer rounding.
- **Insets (classic flat, accepted):** none — children tile 100% of their directory's
  rectangle. Hierarchy is a **post-pass**: every directory region below the root gets a
  **1 pt outline**, with **0.5 pt hairlines** between sibling leaves.

### 6.2 The merge rule — "merge, never disappear" (supersedes §05 culling)

The treemap is **always area-truthful, and nothing with real bytes disappears.**

- **No minimum-area drop / no culling-to-background.** Within each directory, all children
  whose individual squarified rectangle would fall **below 2×2 pt** are **merged into
  exactly one aggregate box** per directory, whose area equals the **exact sum** of their
  attributed bytes. (2×2 pt is the **merge** trigger, not a *drop* trigger.)
- The trigger applies to any child — a leaf **or** an entire too-small subtree — so a
  collectively-tiny directory folds into its parent's single aggregate box.
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
- **Unified toolbar.** **Bottom status bar** carries: scanned logical total; file + folder
  counts; (volumes only) capacity & free; error & exclusion counts; and the **size-color
  legend**.
- **Chooser:** a toolbar **"Choose…"** sheet listing eligible sources (internal +
  directly-attached drives, plus "choose folder…" via `NSOpenPanel
  canChooseDirectories`). **Ineligible sources — network volumes, mounted disk images,
  cloud-provider roots — are shown disabled with the reason inline**, not hidden, so the
  scope rule is legible. Esc dismisses.
- **Empty state:** centered call-to-action (not a blank window), stating read-only +
  hidden-files-included + drive-eligibility up front.
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
- **Cancelled** — unmistakable **"Incomplete — scan cancelled"** banner, partial results
  retained as fully browsable/selectable, offer a fresh scan.
- **Partially failed ("Completed with errors")** — the unreadable entry marked
  **Unreadable** (size never guessed), every affected ancestor **Incomplete**, an error
  summary + an **excluded-cloud-items count** surfaced. Ticket-01 semantics shown
  concretely per item: symlink (0 bytes, "never followed"), hard link ("counted
  elsewhere" + owner path), iCloud materialized-vs-omitted, package as one box.

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
error/exclusion totals, and hard-link owner paths. Sparse files give multi-GiB logical
lengths without allocating contents. Scale rungs: Smoke 4,096 entries / 768 MiB;
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

- One accessibility child per rendered node **or aggregate rectangle** (including
  directory regions), deterministic sorted order, labels containing name/size/kind (or
  combined count/size for a merge box), focusability, selected state, and an
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
2. **Measurement is correct and honest:** all seven §3.6 cases pass; only logical
   `fileSizeKey` bytes roll up; hidden included; symlinks 0 bytes and not followed; hard
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
   area strictly ∝ logical bytes; classic-flat rendering; **merge (not cull)** for
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
