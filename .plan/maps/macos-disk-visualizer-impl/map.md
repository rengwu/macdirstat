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

## Not yet specified

- **Compiler availability checking does not reject everything §4.4 assumes it does.** A
  `Canvas` in a `some View` body is a *warning*, not an error, and would crash on Big Sur.
  The `Scripts/check-post-bigsur-apis.sh` guard is load-bearing rather than a second
  opinion; §4.4 and §9.3 word it as though the compiler alone suffices.
- **The 10 s tree throttle contradicts a settled decision, and the reason is relayout cost,
  not memory.** Ticket 01 fixed "10 Hz scalars / **4 Hz tree**"; commit `cc212c8` quietly
  raised the tree interval to 10 s. Ticket 10 measured why: a full treemap relayout at the
  Large rung takes **2.27 s** at 2,560×1,600, because `PreparedTree` rebuilds every
  positive-byte node on every layout. The scan's autorelease fix does not move that
  number, so 4 Hz is unaffordable at two million nodes for an independent reason. The
  options — keep the throttle, prune sub-pixel nodes before layout, or cache the draw list
  — are a decision, not a measurement. The field run showed the throttle only changes how
  often the app freezes, not whether it does: the pre-pass runs on the main thread.
  <clears-with: 14>
- **The single logical measure is indefensible on sparse files, and the progress fraction
  is dimensionally wrong.** A 1 TiB `Docker.raw` occupying 34.6 GiB is the normal case on a
  developer's machine. Whether the engine carries logical bytes, allocated bytes or both is
  a product decision that reaches back into ticket 04's semantics and into `spec.md`; the
  "About N% of used space" bar divides logical bytes by real used space and pegs at 100%
  long before a scan ends. <clears-with: 13>
- **Every name a scan holds is a non-native Swift string.** `URL.lastPathComponent` returns
  a string whose UTF-8 is not contiguous, and ticket 15 measured one consequence: canonical
  `String <` on those names costs **5.9×** what it costs on the same names copied into
  native storage. Comparison is only one of the things done to a name — hashing, `==`,
  path building and every UI read pay some version of the same tax. Copying each name once,
  in the probe, would buy it back at the price of one allocation per entry (2.9 M on a scan
  of `/`). Unmeasured, and nothing depends on it today.
- **§3.3 now has three rules where the spec states one.** The device-identity boundary
  check is joined by a visited-directory identity guard and by two ordering rules — a
  mount point inside the root's own volume is opened last, a hidden subdirectory after its
  visible siblings — because macOS reports one device *and* one file identity for `/` and
  `/System/Volumes/Data`, and hangs synthetic aliases of the whole filesystem off the
  volume root. Ticket 12 settled all three and proved them on a real `/`; `spec.md` still
  describes the boundary check alone, and the probe seam it calls "listing and metadata
  only" now also reads the mount table. The patch is the edit to `spec.md`, not a
  re-decision.
- **Spec text lags the prototype.** Ticket 01's answer supersedes six clauses across
  §§6.1, 6.2, 7.1 and 7.3 (merge iteration, merge-box order, outline depth cap,
  tree-visible counts, Cancelled banner → status-bar chip, empty-state and chooser
  disclosures removed). `spec.md` still carries the old wording. These are settled
  decisions, not open questions — the patch is the edit to `spec.md`, not a re-decision.
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
