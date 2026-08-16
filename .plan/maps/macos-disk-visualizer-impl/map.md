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

## Not yet specified

- **Compiler availability checking does not reject everything §4.4 assumes it does.** A
  `Canvas` in a `some View` body is a *warning*, not an error, and would crash on Big Sur.
  The `Scripts/check-post-bigsur-apis.sh` guard is load-bearing rather than a second
  opinion; §4.4 and §9.3 word it as though the compiler alone suffices.
- **A security scope's verdict is environment-dependent, and never an eligibility one.**
  Ticket 03 recorded `startAccessingSecurityScopedResource()` returning `false` for an
  ordinary non-security-scoped local URL; ticket 05 measured `true` for every ordinary
  local URL in an unsandboxed test process on macOS 27. Both readings kill the research
  asset's rule (§2.1: refuse the root on `false`) — one because it would reject most real
  roots, the other because it would accept everything. The adapter reports only whether a
  *stop* is owed, and an unreadable root fails through the probe instead. What a
  **sandboxed** app answers, for a URL from the panel and for one that never was, is still
  unmeasured. <clears-with: 07>
- **Deep trees have a teardown ceiling, not a traversal one.** Releasing a `ScanNode` chain
  is a recursive ARC teardown, so it is bounded by the releasing thread's stack — past
  ~1,000 levels on a 512 KB cooperative-pool thread. That is 15× the depth-64 stress shape
  and deeper than `PATH_MAX` permits, so it is a recorded bound rather than a fix; the
  scale suite should confirm the stress rung stays clear of it. <clears-with: 10>
- **Spec text lags the prototype.** Ticket 01's answer supersedes six clauses across
  §§6.1, 6.2, 7.1 and 7.3 (merge iteration, merge-box order, outline depth cap,
  tree-visible counts, Cancelled banner → status-bar chip, empty-state and chooser
  disclosures removed). `spec.md` still carries the old wording. These are settled
  decisions, not open questions — the patch is the edit to `spec.md`, not a re-decision.
- **The read-only guarantee and the scan-scope rule are stated nowhere in the UI.** A
  consequence a human accepted knowingly when the empty-state disclosures and the
  chooser's disabled ineligible rows were cut. Worth one look before 09 ships: a user
  whose network volume is simply absent from the chooser gets no reason for it.

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
