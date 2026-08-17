# macOS Disk Visualizer — Implementation

## Destination

Build the first shippable-locally version of the macOS Disk Visualizer to the settled
[specification](../macos-disk-visualizer/spec.md): a native Swift/AppKit macOS app,
universal (`arm64` + `x86_64`) with a macOS 11.0 floor, that scans one selected local
folder or volume with visible cancellable progress and presents synchronized
directory-tree and classic-flat treemap views driven by one shared selection, with
read-only Open and Reveal actions. Done when every acceptance criterion in the
specification (§12) is met and the full verification gate (§9) passes: the `MacDirStat-CI`
scheme green (with one Thread Sanitizer run), the universal Release build succeeding, the
performance/scale suite within the 8 GB/no-OOM ceiling, and the compatibility runtime
matrix recorded across macOS 11 through current.

## Notes

- The authoritative contract is [`spec.md`](../macos-disk-visualizer/spec.md) in the
  planning map. Every ticket here traces to it; read the referenced sections before
  working a ticket. Do not reopen settled product or technical decisions — flag conflicts
  for a human instead.
- This is the implementation map paired with the planning map
  `.plan/maps/macos-disk-visualizer/`. The planning map's `spec.md`, prototypes, and
  assets are the durable upstream record.
- Tickets are tracer-bullet vertical slices worked the frontier way: any ticket whose
  `blocked_by` tickets are all resolved is takeable. Start frontier: **01** (whole-app
  prototype) and **02** (scaffold) run in parallel.
- The **whole-app gold-standard prototype (01)** is the authoritative visual/behavioral
  reference for all on-screen work. It settles the spec's deferred-within-v1 presentation
  details (tree columns/sort, inspector field set, package drill-in, progress copy,
  palette hues). Tickets 06–09 build to it.
- Read-only is structural and non-negotiable: no dependency exposes a write/download
  method; the only file actions are Open and Reveal. Verification proves it three ways
  (fixture fingerprint, no-write-method, action spies).
- Prefer Apple primary documentation for platform and API facts, consistent with the
  spec's cited findings.
- **Tickets 12–15 come from the first real whole-volume run** (2026-08-17, `/` on an M1 Pro,
  a Debug build). Four defects the suites could not have caught, because every fixture and
  every rung is a tree the tests built themselves: a scan of `/` counts the disk twice, the
  logical measure is indefensible on sparse VM images, the treemap's layout pre-pass blocks
  the main thread, and the directory sort normalizes Unicode on every comparison. Run the
  app against a real volume before claiming a scale ticket is done.

## Decisions so far

- [Whole-app gold-standard prototype](./tickets/01-whole-app-gold-standard-prototype.md) —
  `prototype/whole-app-variants.html` is the authoritative visual/behavioral reference for
  06–09. Settles the deferred-within-v1 details (tree columns `Name │ Size │ % │ Items`
  default Size ▼ with an inline bar in the % cell; package drill-in subdivides without
  changing outer area; inspector field set plus a right-click Open/Reveal menu; 10 Hz
  scalars / 4 Hz tree with "About N% of used space"; 11 respaced kind hues; legend only
  once a scan has color) and closes the three spec gaps blocking 06: **merge rule
  iterates to fixpoint**, **merge box pinned last** in child order, **outlines capped at
  3 levels**. Status-bar counts are tree-visible, not scanner-enumerated. §§6.1, 6.2, 7.1
  and 7.3 need amending to match — the prototype is authoritative where they disagree.

- [Project & package scaffold](./tickets/02-project-and-package-scaffold.md) — the
  repository shape every later ticket builds on: `MacDirStat.xcodeproj` (app + three test
  targets), `Packages/ScanCore` and `Packages/TreemapLayout` (Foundation-only, floor
  pinned, the other three test targets), four shared schemes and four test plans, and
  three self-tested guards in `Scripts/` wired into the app build. Thread Sanitizer is a
  **second plan** (`CI-ThreadSanitizer`) on the CI scheme, so `-testPlan CI` stays the
  documented one-command gate. **No sandbox entitlements** — deferred to 07 with the
  chooser in hand. Closed on Xcode 26.6: all four documented commands run green and
  `Scripts/verify-scaffold.sh` exits 0, after fixing a `Performance.xctestplan`
  `loggingType` value Xcode rejects and adding a twelfth step that runs the other three
  plans.

- [ScanCore: core traversal + event/state + cancellation](./tickets/03-scancore-core-traversal.md) —
  the headless heart: the `DirectoryProbe` seam (three read-only requirements, held that
  way by a test over its own source), `ScriptedDirectoryProbe`/`VirtualClock`/access spy in
  a new `ScanCoreTestSupport` target, and `actor Scanner` over a serial iterative DFS with
  frozen structurally-shared snapshots. Four deliberate departures from the research asset:
  the within-directory sort is **locale-independent** (a localized one is not
  deterministic across machines — **ticket 04's hard-link owner depends on this**);
  `elapsed` is `TimeInterval` and `ScanClock` is ours, because `Duration`/`Clock` are macOS
  13+; a refused security scope is no longer an eligibility verdict; and buffering-newest
  lives in the sink as per-kind slots over `AsyncStream(unfolding:)`, because
  `.bufferingNewest(1)` would drop `.started`. Cancellation is terminal but does not force
  Incomplete when the walk had in fact finished.

- [ScanCore: identity, resilience & exclusion semantics](./tickets/04-scancore-semantics.md) —
  the engine's measurement honesty, finished: `HardLinkIndex` (its own type, so the "only
  multiply-linked inodes are indexed" memory claim is testable directly), `ScanDiagnostics`
  with the capped `ErrorSummary`/`ExclusionSummary`, cloud-materialization gating, and
  `ScanNode.initiallyPresentedChildren` — how "a package is measured through but presents
  as one box" is expressed without putting UI policy in the engine. **Errors and exclusions
  are different things**: an exclusion (boundary, remote-only placeholder) leaves ancestors
  Complete and the result Exact, because nothing went wrong. Three judgment calls: an entry
  whose size cannot be read **never enters the identity index** (owning an inode of unknown
  length would zero out a later readable name); a deduplicated name still counts as **one
  item with zero bytes**; and cloud gating applies to directories too, so a dataless folder
  is never listed. 26 new tests, 67 in `ScanCoreTests`.

- [Production `FileManager` probe + real-filesystem proof](./tickets/05-production-filesystem-probe.md) —
  the engine now runs on a real disk and is proven read-only there.
  `FileManagerDirectoryProbe` (one batched `contentsOfDirectory` prefetch per directory,
  hidden entries included, `lstat` fallback that leaves identity `nil` rather than risk
  double-counting a hard link), `TemporaryFileSystemFixture` (sentinel-owned, four-part
  refusal guard, permission restore), `FilesystemFingerprint`, and the §9.2 fixture —
  sparse hidden file, three symlinks including an ancestor loop, `link(2)` pair plus an
  out-of-scope third name, a real package, a 64-directory chain, a `chmod 000` directory,
  and a `clonefile` clone where the host allows. **61 tests in `ScanCoreFileSystemTests`.**
  The fingerprint has a positive control, so the read-only proof cannot pass vacuously.
  Two findings: `startAccessingSecurityScopedResource()` answers **`true`** for every
  ordinary local URL in an unsandboxed process here — the opposite of ticket 03's
  observation, and why the return value cannot be an eligibility verdict in either
  direction; and the vanished-file/vanished-directory asymmetry is now demonstrated on
  real files rather than argued about.

- [TreemapLayout: geometry, merge rule & palette](./tickets/06-treemap-layout-geometry.md) —
  the Foundation-only layout engine is complete: iterative squarification plus the
  pinned-last merge bucket to fixpoint, half-open hit testing, backing-scale snapping,
  three-level outline metadata, package drill-in inputs, and the settled 11-hue palette.
  Its 71 tests prove deterministic golden rectangles, zero surviving sub-2 pt slivers,
  and 100% positive-byte area at the prototype fixtures and five viewport sizes.

- [App shell + tree + chooser + live scan (+ formatting)](./tickets/07-app-shell-and-live-scan.md) —
  the first on-screen tracer bullet is complete: programmatic three-pane AppKit shell,
  unified toolbar/status bar, filtered mounted-source sheet plus real `NSOpenPanel`,
  frozen-snapshot source-list tree, 10 Hz scalars / 4 Hz tree and path, Cancel, completed
  totals/legend, and exact locale-aware three-significant-figure IEC formatting. The app
  deliberately remains unsandboxed for whole-volume enumeration; security-scoped access
  is balance-only, never eligibility. The full one-command gate exits 0, including CI,
  Thread Sanitizer, universal Release, Performance and Compatibility plans.

- [Performance & scale suite](./tickets/10-performance-and-scale-suite.md) — the opt-in
  pre-release-candidate gate: 48 tests over a lazy scale generator with the exact §9.2
  rungs, a counting probe, a peak-footprint sampler, treemap-at-scale, an opt-in
  real-filesystem builder, and a committed record. Every rung finishes below 0.33 GiB
  against the 8 GiB ceiling; Large holds two million nodes at 88 bytes each and lays out
  into 137,056 visible boxes against a bound of 1,024,000. It found the 28 GB the field
  report could not explain: **`FileManagerDirectoryProbe.list` had no autorelease pool**,
  so a traversal that never suspends held every listing it ever made — 13,615 bytes of
  footprint per entry, now 158. The suite adds one bar §8.4 does not state (under 2 KiB
  per entry on a real-filesystem scan), because the 8 GiB ceiling alone could only have
  failed on the machine of the person already suffering. Deep-tree teardown is confirmed
  clear: depth 64 is 15× under the ~1,000-level recursive-ARC bound and its deepest path
  already nearly fills `PATH_MAX`, so no real filesystem can reach further.

- [Directory re-entry: counted once, on the path you recognise](./tickets/12-firmlink-reentry-double-count.md) —
  a scan of `/` no longer counts the disk twice: **1.78 TB / 2.91 M files / 3.63 M nodes**
  in 9 minutes at a 695 MB footprint, against the field report's 3.78 TiB and 7.35 M files,
  with `Docker.raw` once and `/Users` at the top. `VisitedDirectoryIndex` keys one entry per directory *opened* on
  `fileResourceIdentifierKey`; a repeat is an **exclusion** (`.repeatedDirectory`), never an
  error, and the second name stays visible and weightless with the owner's path, as a
  hard-linked name does. Two things the ticket did not foresee: `/` and
  `/System/Volumes/Data` share an identity while holding different entries, so a **mount
  point is walked last and never indexed** (identity alone would have lost `.Spotlight-V100`
  and its neighbours — a double count traded for an under-count); and `/.nofollow` is a
  synthetic alias of the whole filesystem that sorts before every real name, so **hidden
  subdirectories are opened after their visible siblings**. The seam gained a fourth
  requirement, `mountPointPaths()` — one `getmntinfo_r_np` per scan.

- [The within-directory sort: measured first, then changed for a different reason](./tickets/15-directory-sort-normalization-cost.md) —
  the sort was never the bottleneck the field sample suggested: listing is **93–95 %** of a
  scan's wall clock and the sort **1.5–2.1 %** (0.86 s of a 57 s `/System/Library` scan,
  447,367 entries in 156,701 directories). It changed anyway, for a correctness reason the
  measurement exposed: `String <` orders by canonical equivalence, so two spellings of one
  name are **tied**, and the tie falls to the order the filesystem listed them in — the one
  input that is not the same on two machines holding the same tree, and the input hard-link
  ownership rides on. `ScanCore.NameOrder.precedes` now compares Unicode scalars — the
  comparison `PreparedTree.precedes` already made, now named at both sites and used by the
  tree view too — which is also **2.2–2.4× cheaper** in a real scan. Why cheaper there and
  slower in a warm micro-benchmark: `URL.lastPathComponent` returns a non-contiguous string,
  and canonical comparison of one leaves its fast path for the normalizer, which is the
  NFD/NFC frames the field sample caught on a volume holding 18 non-ASCII names in 447,367.
  Record: [`records/sort-cost.md`](./records/sort-cost.md).

- [The treemap lays out where it must: off the main thread, over what it draws](./tickets/14-treemap-relayout-blocks-main-thread.md) —
  the freeze is gone and it was two defects in one symptom. `PreparedTree` no longer
  builds a class instance per positive-byte node before placing anything: it prepares
  **one directory at a time**, the moment that directory is about to be subdivided, so a
  folded subtree is never opened and the fixpoint tracks survivors by index. The price is
  a fifth seam requirement, `treemapPresentedItemCount` — an aggregate must still say
  exactly how many entries it hid — answered in O(1) by a new `ScanNode.attributedNodeCount`
  rolled up on the same ancestor walk as `subtreeBytes` (an eleventh stored property, and
  the stored-property cap moved to say so). `TreemapLayoutCoordinator` owns *when*: one
  layout at a time, newest wins, on a detached task; the view draws what has arrived and
  refuses a stale **viewport** for hit testing, hover and accessibility while painting it
  stretched so a divider drag is not a grey window. **4 Hz is restored** — `cc212c8`'s
  10 s was hiding the freeze, not preventing it. Large rung: relayout 2.27 s → **1.17 s**,
  main-thread stall **0.019 s** against an inline control of **1.15 s**, entries read
  2,000,000 → **1,335,183** and **221,869** for the same tree at 640×400. Proved in the
  field too: scanning `/System/Library` the shipped app answers for its window in 0.36 s
  and `sample(1)` shows the main thread 91% idle with every layout frame under the
  coordinator's detached task.

- [What the app measures: blocks on disk, with content length beside them](./tickets/13-sparse-files-and-honest-totals.md) —
  the single logical measure is replaced. **`/Users/rengwu` reports 1,812 GiB of content
  length and occupies 277 GiB** — 6.5× too big on a 460 GB disk — and the error runs the
  other way too: macOS compresses its own binaries, so length over-reports `/System` by
  43%. `fileAllocatedSizeKey` drives the treemap, the tree, every total and the progress
  figures; `fileSizeKey` is carried beside it, rolled up through folders, and shown in the
  inspector only where the two differ. Reading the second key is **0.1%** on a real tree
  and the second pair of `Int64` is ~58 MB at 3.63 M nodes. Blocks on disk, **deduplicated
  the way this engine deduplicates hard links**, land within **0.3%** of the volume's own
  used figure (332.97 GiB against 331.98) — undeduplicated they read 347.59, and all 14.62
  GiB of that difference is 66,920 second names. Throughput becomes **items per second**
  (bytes/s here was never a disk speed — the scanner reads listings, never contents); the
  progress fraction is capped at 99% while scanning and withdrawn if the count passes
  volume-used; a finished volume scan reconciles out loud. Ticket 04's semantics survive
  intact except that the **on-disk figure decides readability** (length is never
  substituted) and the third-party cloud placeholder now counts as zero on its own, which
  is what it is. Clones flip to over-reporting and are accepted. `spec.md` is amended;
  `CONTEXT.md` pins the two terms; the build is [ticket 16](./tickets/16-count-blocks-on-disk.md).

- [Count blocks on disk, carry length beside them](./tickets/16-count-blocks-on-disk.md) —
  the build, and the specification and the code agree again. `EntryMeta.diskSize` beside
  `contentLength`, four `Int64` on `ScanNode` rolled up on one ancestor walk, the `lstat`
  fallback reaching the same quantity through `st_blocks × 512`, `attributedNodeCount`
  keyed on the visible measure. Throughput is items per second, the completion fraction is
  capped at 0.99 while running and withdrawn once counting passes volume-used, and a
  finished volume scan reconciles in the **status bar** — *"344 GiB counted · 384 GiB
  used"* — shown whenever there is a used figure, because agreement only reads as evidence
  if it is there every time. `ownBytes`/`subtreeBytes` are **renamed** at all 205 sites
  rather than kept with a changed meaning. Proved on `/`: **344.16 GiB on disk against
  1,817.97 GiB of length**, `/Users` 263 GiB occupying and 1,724 GiB long, two runs
  agreeing to 0.02%. Record: [`records/blocks-on-disk.md`](./records/blocks-on-disk.md).

## Not yet specified

- **Compiler availability checking does not reject everything §4.4 assumes it does.** A
  `Canvas` in a `some View` body is a *warning*, not an error, and would crash on Big Sur.
  The `Scripts/check-post-bigsur-apis.sh` guard is load-bearing rather than a second
  opinion; §4.4 and §9.3 word it as though the compiler alone suffices.
- **A relayout at the Large rung still costs 1.17 seconds of a background core, and it is
  allocation churn rather than algorithm.** Two arrays per directory opened — the
  adapter's `treemapPresentedChildren`, then the prepared children — and four more per
  merge round, across 126,144 directories. Reusing buffers across directories would cut
  it without touching geometry. §8.2 commits no wall-clock bar and the main thread no
  longer waits for it, so this is a recorded cost and not a defect; it matters only if
  the tree feed's 4 Hz ever needs to be honoured rather than coalesced.
- **A scan of `/` reconciles about ten percent below the volume's used figure, and nothing
  is wrong.** `volumeAvailableCapacityKey` is a property of the APFS *container*, so
  Preboot, Recovery and VM are inside the denominator while §3.3 correctly keeps them
  outside the numerator; local snapshots hold blocks no walk can reach; root-owned
  directories a user's own scan cannot read hold a little more. Against the two volumes a
  scan of `/` can actually reach, ticket 16 measured **−3.2%**. Ticket 13's 0.3% was taken
  on `/System/Volumes/Data`, where the root really is one volume. Nobody has decided
  whether the line should say so — subtract the sibling volumes, name them, or leave the
  user to read a gap that is normal for one root and meaningful for another.
- **Every name a scan holds is a non-native Swift string.** `URL.lastPathComponent` returns
  a string whose UTF-8 is not contiguous, and ticket 15 measured one consequence: canonical
  `String <` on those names costs **5.9×** what it costs on the same names copied into
  native storage. Comparison is only one of the things done to a name — hashing, `==`,
  path building and every UI read pay some version of the same tax. Copying each name once,
  in the probe, would buy it back at the price of one allocation per entry (2.9 M on a scan
  of `/`). Unmeasured, and nothing depends on it today.
- **The read-only guarantee and the scan-scope rule are stated nowhere in the UI.** A
  consequence a human accepted knowingly when the empty-state disclosures and the
  chooser's disabled ineligible rows were cut. Worth one look before 09 ships: a user
  whose network volume is simply absent from the chooser gets no reason for it.
- **Every performance number on record was taken on the wrong machine.** §8.1 fixes the
  reference machine at M1 / 8 GB / NVMe; ticket 10's run was on an M1 Pro with 16 GB, and
  the record says so. The margin is wide — 0.32 GiB peak at the Large rung against an
  8 GiB ceiling — but a host with twice the memory swaps later, so the ladder has to be
  climbed once on the reference machine before an RC is declared.

## Out of scope

- File mutation of any kind — deletion, cleanup, moving, renaming, duplicate detection —
  and any file-management workflow. The first version is read-only (Open/Reveal only).
- Historical comparison, scheduled or background scanning, and analytics.
- Multiple roots per scan; network volumes, cloud-provider roots, mounted disk images,
  and nested mounted volumes as scan scope.
- Signing, notarization, packaging, distribution, crash reporting, and update mechanisms.
- Persisted documents — a scan is a transient session; the app is not document-based.
- Quantitative accessibility coverage bars, and any wall-clock / throughput / UI-latency
  SLA (the spec commits algorithmic and memory bars only; accessibility mechanics are
  required but no coverage threshold is set).
