---
type: task
blocked_by: [02, 03, 04, 05, 06]
undermined_by: []
claimed_by: sbee7271ea99b
claimed_at: 2026-08-15T04:26:52Z
---

# Design the verification strategy

## Question

What automated and manual checks will prove the settled behavior on macOS Big Sur and newer without requiring destructive filesystem operations? Map product rules to unit, integration, UI, geometry, performance, cancellation, and compatibility checks, and define deterministic filesystem fixtures for symlinks, hard links, packages, permissions, and deep trees.

## Done when

Every settled requirement and quality bar maps to at least one practical check, the test fixture strategy is reproducible and read-only, compatibility coverage is explicit, and the local commands or Xcode schemes needed to run verification are named.

## Answer

Verification is a layered release gate: pure Swift package tests prove semantics and
geometry deterministically; a small disposable-filesystem suite proves the production
Foundation adapter; app-model and UI tests prove state and interaction wiring; opt-in
scale suites prove algorithmic and memory behavior; and a recorded runtime matrix proves
that a universal release build actually works on macOS 11 through the current stable
macOS. A deployment-target build is necessary but is not accepted as a substitute for
running the app on Big Sur.

The scanner is read-only in every verification run. Test setup may create, change modes
on, and remove a uniquely owned fixture directory, but it never stages cases in an
existing user directory. Manual Open/Reveal checks use that disposable fixture too,
because an application launched by Open could otherwise modify a user's real file.

### Test targets and release gates

The implementation map must create these test targets and shared schemes. Tests named
"generated" below build their input from a versioned seed and manifest; no generated
fixture tree is committed.

| Target or gate | Responsibility | Normal cadence |
| --- | --- | --- |
| `ScanCoreTests` | Pure scanner, fake `DirectoryProbe`, virtual clock, event/state, aggregation, errors, cancellation | Every change |
| `ScanCoreFileSystemTests` | Production `FileManager` probe against a small temporary tree | Every change on macOS |
| `TreemapLayoutTests` | Pure geometry, merge buckets, hit testing, palette classification | Every change |
| `MacDirStatTests` | `@MainActor` presentation models, formatting, chooser policy, selection, workspace-action spies | Every change |
| `MacDirStatUITests` | App lifecycle states, three-pane wiring, keyboard, resizing, accessibility surface | Every change on macOS; screenshots reviewed when changed |
| `MacDirStatPerformanceTests` | Generated Smoke/Representative/Large/Stress scans, peak RSS, operation counts, relayout bounds | Opt-in before a release candidate on the reference machine |
| Compatibility matrix | Universal build plus launch/workflow smoke on every supported major macOS | Before declaring a release candidate compatible |

The default `MacDirStat-CI` shared scheme/test plan includes every target except
`MacDirStatPerformanceTests`. `MacDirStat-Performance` is a shared Release-configuration
scheme containing only the scale and stress tests. `MacDirStat-CompatibilitySmoke` is a
short UI test plan that performs launch, folder scan, incremental-result, cancel,
selection, Open/Reveal-spy, and partially-failed-state checks.

The intended local commands, from the repository root, are:

```sh
swift test --package-path Packages/ScanCore
swift test --package-path Packages/TreemapLayout
xcodebuild test -project MacDirStat.xcodeproj -scheme MacDirStat-CI -testPlan CI -destination 'platform=macOS'
xcodebuild build -project MacDirStat.xcodeproj -scheme MacDirStat -configuration Release -destination 'generic/platform=macOS' ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=11.0
xcodebuild test -project MacDirStat.xcodeproj -scheme MacDirStat-Performance -configuration Release -destination 'platform=macOS'
```

The package paths, project, schemes, and `CI.xctestplan` above are part of this
verification contract, not descriptions of files that already exist in this planning
map. Xcode's Test action for `MacDirStat-CI` is the one-command local gate. A release
candidate must pass it with Thread Sanitizer once as an additional diagnostic run;
performance measurements run without sanitizers because instrumentation changes memory
and timing behavior.

### Reproducible fixtures

There are two fixture adapters with the same logical manifest:

1. `ScriptedDirectoryProbe` supplies `EntryMeta` values and injected failures directly.
   It is authoritative for cases the host filesystem cannot stage reliably: different
   volume identifiers, cloud download status, malformed metadata, deterministic
   disappearance, security-scope denial, exact cancellation checkpoints, and error
   storms. It records every list/metadata request, so tests can also prove traversal did
   not cross a boundary or perform redundant reads.
2. `TemporaryFileSystemFixture` creates a fresh child of the test temporary directory,
   writes an ownership sentinel, scans it using the production probe, and fingerprints it
   before and after. Cleanup first verifies both the sentinel and the resolved path; it
   refuses to delete any other directory. It restores permission bits before removing
   its own tree, including after a failed test.

Fixture generation is versioned as `fixture-v1` with fixed seed `0x4D4453`. Scanner-order
fixtures use unambiguous ASCII names; separate treemap tie fixtures use explicit Unicode
scalar sequences and the settled byte-descending/name-ascending code-point rule. Each
manifest records generator version, seed, entry count, exact attributed bytes, expected
node-tree digest, error/exclusion totals, and hard-link owner paths. Sparse files
(`ftruncate`) give multi-GiB logical lengths without allocating their contents.

The small real-filesystem fixture contains:

- `.hidden.bin`, a sparse hidden file with a known logical length;
- `target.bin`, a symlink to it, a broken symlink, and a symlink back to an ancestor to
  prove links are visible, contribute zero, and cannot form a traversal loop;
- `a-owner.bin` and `z-duplicate.bin`, created with `link(2)`, plus a third link in a
  sibling directory outside the scan root; stable naming makes ownership deterministic;
- `Fixture.app/Contents/Info.plist` and sparse resources, forming a real package whose
  descendants are measured while its presentation remains one collapsed item/box;
- a 64-directory chain ending in one file, proving iterative traversal beyond the
  required 20-level stress shape;
- an unreadable directory made with mode `000`, with a readable sibling. The test asserts
  it is running as a non-root user and that listing really fails; deterministic injected
  errors remain the cross-environment authority;
- an empty file, an ordinary `.alias`-named file, fixed-extension files for every palette
  group, a file with extended attributes/resource-fork data, and equal-sized names that
  exercise stable sorting; a scripted regular-file classification covers a Finder alias;
- where the temporary volume supports it, an APFS clone made with `clonefile`; this host
  capability test is supplementary, while a scripted distinct-identity clone case is
  mandatory on every host.

The fingerprint compares relative path, item kind, logical length, mode, modification
time, symlink target, inode/link count, and hashes of the small non-sparse contents before
and after scanning. Access time is excluded because the OS may update it on metadata
access. No test invokes a cloud download API, reads file contents through the scanner, or
mounts/unmounts a volume. The production probe's interface exposes listing and metadata
only; a spy security-scope adapter proves access is balanced exactly once on success,
failure, cancellation, and replacement by a new scan.

The scale generator has exact, reproducible rungs:

| Rung | Generated shape | Required use |
| --- | --- | --- |
| Smoke | 4,096 entries, 768 MiB logical | Real temporary tree and scripted probe; inner loop |
| Representative | 400,000 entries, 200 GiB logical | Generated tree on the M1/8 GB reference machine; primary scale acceptance |
| Large | 2,000,000 entries, 1 TiB logical | Generated tree on the M1/8 GB reference machine; no-crash/no-OOM/usability gate |
| Stress | flat 100,000-entry directory; depth 64; one 40 GiB file plus 10,000 tiny files; 10,000 links; 2,500 injected failures | One fixture per shape so failures identify the cause |

Representative and Large run first through a lazy scripted probe, which computes directory
listings from seed and shape instead of retaining a second copy of all metadata. An opt-in
`FixtureBuilder` may materialize the same manifest beneath an explicitly supplied empty
directory using sparse files. It must create a new sentinel-marked child and refuse an
existing or nonempty target. This provides a real-I/O soak without making hundreds of
thousands of filesystem objects part of the normal test loop. Wall-clock scan time is
reported for context only and never used as a pass/fail threshold.

### Scanner and filesystem traceability

| Settled contract | Automated proof |
| --- | --- |
| Root exists, is a directory, is local, and security access starts | Table-driven pre-flight tests produce each `ScanFailure`; only a fully eligible root emits `.started`. A fake `volumeIsLocal == false` proves network rejection. |
| One device only; nested mounts are listed but not traversed | Give a child directory a different `volumeIdentifier`; assert no list call beneath it, one boundary exclusion, and no attributed descendants. |
| Serial iterative deterministic DFS | Request log and a depth-64 fixture prove LIFO traversal without recursion failure; identical runs have identical node order and hard-link owner. |
| Logical `fileSize` only; hidden files included; metadata/allocation excluded | Real sparse/hidden/xattr fixture and fake conflicting logical-vs-allocated values assert only logical bytes roll up, using `Int64`. |
| Symlinks never followed; Finder aliases remain ordinary files | Real loop/broken-link fixture plus scripted classifications assert visible zero-byte symlink leaves, termination, and normal alias attribution. |
| Hard links counted once; outside names ignored; APFS clones counted separately | Real `link(2)` fixture and scripted identities assert first stable path owns bytes, duplicate stays visible with owner path and zero bytes, outside path is absent, and distinct clone identities both count. The request log proves the identity index is consulted only when link count is greater than one and is bypassed when the volume says it has no hard-link support. |
| Packages measured recursively but initially represented as one item | Real `.app` and scripted package assert descendant rollup is exact; app-model/treemap tests assert the package is initially a single leaf presentation. Detailed package drill-in remains deferred. |
| Only materialized cloud items count; placeholders omitted without download | Script `.current`, `.downloaded`, `.notDownloaded`, and unavailable third-party status; assert the first two count, the placeholder has no node and increments the exact exclusion count, and the unavailable status safely counts the present logical file. A spy that would fail on any download/open-data call proves none occurs. |
| Rollups are incremental and never double count | At cadence zero, assert every ancestor total is monotonic and equals discovered owned leaves at every event; final totals equal an independent manifest fold. |
| Frozen snapshots are race-free and structurally shared | Assert a finalized subtree keeps object identity across snapshots and cannot mutate, while only the open spine is copied. Run the CI suite once under Thread Sanitizer while consuming events on `@MainActor`. |
| Event/state contract and one active scan | Exhaustively assert `.started`, interleaved monotonic snapshots, one reliable terminal event, then stream end. Pre-flight has `.failed` only; recoverable errors have `.finished(.completed)`; cancelling or replacing a scan has `.finished(.cancelled)` and the replacement starts only afterward. |
| Progress is honest and coalesced | A virtual clock proves scalar emissions at no more than 15 Hz and tree emissions at no more than 4 Hz, no per-entry backlog, buffering-newest behavior, and immediate exact final snapshots. Folder fraction is always `nil`; volume fraction is labelled approximate, clamped, and never enters a tree total. |
| Cancellation checks per directory and 256-entry batch | A barrier probe cancels immediately before each checkpoint and records no more than one current listing/batch of additional work. Assert open ancestors become Incomplete, all discovered nodes remain, final reason is cancelled, and security access stops exactly once. This is an operation bound, not a millisecond SLA. |
| Recoverable errors never abort or guess | Script unreadable directory/entry, missing size, and disappearance. Assert siblings continue, nodes are Unreadable where representable, ancestors are Incomplete, attributed size stays zero, `.completed` is reached, and counts by category are exact. |
| Error details are bounded | Inject 2,500 failures: exact total is 2,500, details contain the first 1,000 deterministic records, and `truncated` is true. |
| Capacity/free remain separate | Volume-mode result exposes the injected capacity/free values; no node or formatter receives `capacity - free` as unknown content. |
| Live filesystem changes are best-effort | A barrier probe removes an already-listed entry, changes metadata after its one read, and exposes a new child after its parent's listing. Assert disappearance is recoverable, no second pass or automatic restart occurs, and only an explicit new scan sees the new state. |
| Read-only behavior | The real-fixture fingerprint is unchanged. Scanner dependencies have no write/download method. Workspace action tests call only `open` or `reveal` spies with the selected URL; UI tests assert no Delete/Clean/Move mutation command exists. |

The combined resilience fixture contains permission denial, unreadable metadata,
disappearance, remote placeholder, duplicate hard link, and a flat directory in one run.
Its gate is zero crashes, `.finished(.completed)`, exact error/exclusion counts, correct
Unreadable/Incomplete propagation, and no guessed bytes. The real `chmod 000` check validates
the adapter on a normal local test account; scripted failures keep CI deterministic when
host permissions or sandbox behavior differ.

### Treemap and formatting traceability

Ticket #06's merge rule is the expected result wherever it conflicts with Ticket #05's
earlier culling rule.

| Settled contract | Automated proof |
| --- | --- |
| Recursive squarified, deterministic geometry | Golden rectangles for small hand-computable trees plus property tests over Representative, Dense, Deep, Extreme, and seeded random trees. Repeated runs must be byte-identical before draw-time snapping. |
| Area strictly follows attributed bytes | For every directory, child and aggregate areas sum to the parent within a scale-relative floating-point epsilon; no overlap, negative area, out-of-bounds rectangle, log scaling, inset, header area, or minimum-area inflation is allowed. |
| Tiny nonzero children merge rather than disappear | At several viewports and backing scales, every child whose individual result is below 2 x 2 pt goes into exactly one per-directory aggregate. Its byte total and recursive item count are exact, it is hit-testable, and visible individual plus aggregate area accounts for 100% of nonzero bytes. Tiny subtrees exercise the same rule. |
| Zero-byte items have no rectangle but remain in the tree | Empty, symlink, hard-link non-owner, and unknowable unreadable nodes produce no geometry; app-model tests still find and select their tree rows and inspector data. |
| Stable order and extremes | Equal-byte names verify code-point ascending ties. A 40 GiB-plus-tiny-tail fixture, 2,500-item Dense fixture, and depth-64 chain remain deterministic, bounded, and crash-free. Rendered geometry count is bounded by visible individual boxes plus one aggregate per affected directory. |
| Precision, resize, and hit testing | Layout uses unrounded points; draw tests snap only using injected 1x/2x scale. Recompute after every viewport change has no cache, animation, hysteresis, or history dependency. Points on interiors and defined shared edges return the deterministic deepest rendered node; aggregate interiors return the aggregate. |
| Classic-flat drawing and hierarchy | Fixed-size bitmap regression fixtures in light/dark appearance check zero insets, directory outlines, 0.5 pt sibling hairlines, red hatch plus text for Incomplete, neutral aggregate treatment, 1 pt hover, and 2 pt inset accent selection. Geometry assertions, not cross-OS pixels, are authoritative. |
| Palette, legend, label, and tooltip | Table tests cover extension to 11 kind groups plus Other and stable same-extension color. Rendering/model tests check dark-mode lightness, directories remain unlabeled in the flat view, leaf labels appear only at least 48 x 15 pt at 11 pt with truncation/halo, the legend is complete, and tooltip/inspector content includes IEC/exact bytes/path/flags/aggregate summary. |
| IEC, exact counts, and percentages | Locale-fixed unit tests cover 0, 1, 1023, 1024, every unit boundary through TiB, rounding carry, and three significant figures. `en_US` and a comma-decimal locale prove locale grouping without changing KiB labels. Percent tests cover 0, below 0.05%, exactly 0.05%, ordinary values, and 100%, producing one decimal and `< 0.1%` rather than `0.0%`. |

Aspect ratio and relayout duration are recorded diagnostics, not acceptance thresholds;
Ticket #06 deliberately sets algorithmic and memory bars rather than a wall-clock SLA.

### App, UI, and read-only workflow traceability

UI tests launch with deterministic injected scan streams/results rather than depending on
an `NSOpenPanel` or a live disk. There is one launch case for each state: empty, choosing,
scanning, completed, cancelled, and completed-with-errors.

| Settled contract | Automated and manual proof |
| --- | --- |
| AppKit-first Big Sur shell | Build-setting/dependency checks require one non-document macOS AppKit target (`SUPPORTS_MACCATALYST=NO`) and framework-free local packages (`ScanCore` and `TreemapLayout` import Foundation but no UI framework). A view-hierarchy test asserts programmatic AppKit lifecycle, three `NSSplitViewController` items, source-list-styled `NSOutlineView` left, custom treemap `NSView` center as growable item, unified toolbar/status bar, and collapsible roughly 300 pt inspector right. SwiftUI hosting is confined to leaf panels. |
| Empty and chooser states | UI test checks centered read-only/hidden-files/eligibility copy and Choose action. Chooser-model tests show eligible local/internal/external sources and disabled network/cloud/disk-image classifications with inline reasons; Esc dismisses. One manual pass exercises the real `NSOpenPanel` with `canChooseDirectories == true` and the mounted-volume list. |
| Scanning state and responsiveness | A gated fake scan checks indeterminate folder progress, explicitly approximate volume progress, bytes/files/folders/elapsed/throughput/current-path telemetry, prominent Cancel, and incremental tree/map behind the card. While the probe is paused, a UI event and selection complete, proving the main actor is not blocked; no numeric latency bar is inferred. |
| Completed, cancelled, and partial failure | UI tests assert the normal status bar; unmistakable `Incomplete - scan cancelled` with retained browsable results and rescan; and `Completed with errors` with Unreadable rows, Incomplete ancestors, summaries, and excluded-cloud count. |
| Bidirectional single-source selection | Selecting a tree row outlines the corresponding file/directory and updates inspector; clicking a rectangle selects and scrolls the row; zero-byte tree selection leaves no false rectangle; aggregate selection describes the bucket without inventing an individual node. |
| Keyboard, split views, and state preservation | UI tests exercise Up/Down, Return expand/open, Command-O, Command-R, chooser Esc, draggable dividers, live treemap recompute, inspector collapse, and selection persistence through relayout. Prototype-only variant controls are absent. |
| Open and Reveal only | Model tests use an `NSWorkspace` adapter spy to assert exact reconstructed URLs and command validation. A manual pass opens/reveals only disposable files and confirms toolbar/inspector actions; menus, context menus, accessibility tree, and toolbar contain no mutation affordance. |
| Status and details | UI assertions cover scanned logical total, file/folder counts, capacity/free only for volume scans, error/exclusion counts, color legend, binary IEC values, and exact grouped bytes in the inspector. |

Snapshot images are stored only for stable app-owned views at fixed viewport, appearance,
locale, and backing scale. Native-control pixel differences across macOS releases require
human review rather than brittle universal pixel equality.

### Performance and memory proof

The performance suite runs a Release build on the settled M1, 8 GB, NVMe reference machine
with other test processes quiescent and records OS version, hardware, generator version,
seed, entry count, logical bytes, operation counts, peak resident memory, terminal state,
and diagnostic elapsed time.

- A counting probe asserts one shallow list per traversed directory, no descent across a
  device boundary, no file-content reads, and no duplicate metadata fetch after a prefetched
  value. Running geometrically larger generated inputs verifies operation counts scale with
  entries plus ancestor depth, rather than with total bytes or a second full pass.
- A barrier at 25%, 50%, and 75% of the generated scan proves useful progress and tree
  results exist before completion. Snapshot identity checks ensure frozen subtrees are
  shared instead of deep-copied.
- Structural checks keep one name and parent link per node rather than a stored absolute
  URL, and keep the hard-link index limited to multiply linked identities. During
  Representative and Large scans, injected UI-model selection and Cancel actions must
  continue to work; "still usable" is not converted into an unapproved timing threshold.
- The harness samples the app process's peak resident size. Representative, Large, and each
  Stress shape must finish without allocation failure or crash and remain below 8 GiB peak
  RSS on the reference machine. Representative's expected hundreds-of-MB result is reported
  as a diagnostic, not promoted into an unapproved threshold.
- Treemap layout and draw operate on the resulting snapshots. The gate is completion with a
  visible-box count bounded by the viewport/merge policy and no crash; relayout time is
  recorded only.
- On the 2015-era Intel/8 GB/SATA compatibility floor, the Smoke fixture must be correct,
  cancellable, non-crashing, and allow UI interaction while scanning. It has no scan-time or
  throughput threshold.

### Compatibility and accessibility matrix

`MACOSX_DEPLOYMENT_TARGET` is fixed at `11.0` in the project and both local packages. The
universal Release build command above must succeed for `x86_64` and `arm64`; compiler
availability checking must reject unguarded post-Big-Sur APIs. A source-review guard also
flags `SwiftUI.Table`, `Canvas`, `NavigationSplitView`, and SwiftUI `searchable` for explicit
review; the permitted search control is `NSSearchField`, and scan traversal uses synchronous
Foundation filesystem APIs.

Before release, `MacDirStat-CompatibilitySmoke` is run on at least one real or virtual host
for **every major macOS version from 11 through the current stable release**, using the same
universal release artifact. The mandatory endpoints are Big Sur 11.7.x on the settled
2015-era Intel/8 GB/SATA floor and the current stable macOS on Apple Silicon. Each record
contains exact OS/build, architecture, hardware or VM, artifact commit, and pass/fail for
launch, Smoke scan totals, incremental updates, cancellation/retained results, partial
errors, tree-map selection, keyboard commands, and disposable-file Open/Reveal. This
runtime record is the compatibility claim; availability compilation alone is not.
Where the host's Xcode can run the UI plan, it automates the checklist; otherwise the same
copied release artifact and fixture are exercised manually, so compatibility does not
depend on an old host being able to compile newer Swift source.

The settled accessibility mechanics are checked even though Ticket #06 deliberately
defines no numerical coverage bar:

- `TreemapLayoutTests`/view tests assert one accessibility child per rendered node or
  aggregate rectangle (including directory regions), deterministic order, labels containing
  name/size/kind (or combined count/size), focusability, selected state, and an announcement
  notification when shared selection changes.
- UI tests drive the settled tree keyboard commands and assert that kind is written in
  tooltip/inspector/legend and Incomplete uses hatch plus text, so neither color nor hatch
  alone carries meaning.
- The release checklist performs one VoiceOver and Accessibility Inspector walkthrough of
  empty, scanning, selected file/directory/aggregate, cancelled, and error states on Big Sur
  and current macOS. It records defects but applies no pass-percentage or task-coverage
  threshold that Ticket #06 did not authorize.

### Known boundaries handed to the specification

- Ticket #06 supersedes Ticket #05 only for sub-2 x 2 pt content: verification expects one
  exact, selectable merge bucket per affected directory, not culling-to-background. Ticket
  #08 must reconcile the prose in the final specification.
- The scan engine's settled eligibility test can prove `volumeIsLocal == true`, but macOS 11
  has no settled first-party way to identify every directly selected disk-image root.
  Chooser-policy tests can disable a source already classified as a disk image; they cannot
  claim the production classifier detects all such mounts. This remains the explicit
  Ticket #03 gap for Ticket #08/human reconciliation.
- No quantitative cancellation latency, UI frame-time, throughput, VoiceOver coverage, or
  keyboard-coverage bar is invented here. The operation-bound cancellation checks,
  off-main responsiveness checks, best-effort timing diagnostics, and settled accessibility
  mechanics are the strongest checks authorized by Ticket #06.
- Tree columns/sorting, final inspector field depth, package drill-in, and any additional
  context menu remain deferred product choices, so this strategy tests only the behavior
  already settled for them.
