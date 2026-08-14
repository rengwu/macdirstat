# macOS Disk Visualizer

## Destination

Produce an implementation-ready specification for a native Swift macOS app that builds locally in Xcode, supports macOS Big Sur and newer, scans a user-selected folder or mounted drive with visible cancellable progress, and presents synchronized directory-tree and WinDirStat-style treemap results with read-only Open and Reveal actions.

## Notes

- The requested product is a modern macOS interpretation of WinDirStat, not a pixel-for-pixel port.
- The implementation must support macOS 11 Big Sur and later and use native Swift/macOS frameworks.
- The first version is read-only. Deletion, cleanup, mutation, and file-management workflows are excluded.
- The deliverable is a locally buildable Swift app. Signing, notarization, packaging, publishing, and release infrastructure are excluded.
- This is a planning map and follows Wayfinder's “plan, don't do” rule. When the specification is settled, create a separate implementation map at `.plan/maps/macos-disk-visualizer-impl/`.
- Prefer Apple primary documentation for platform and API facts. Record durable decisions in the ticket that resolves them rather than duplicating them here.

## Decisions so far

- [Settle filesystem and scan semantics](./tickets/01-settle-scan-semantics.md) — Scan one local physical-volume root using ordinary logical file sizes; include hidden and locally materialized content, avoid traversal and allocation double-counting, and preserve visibly incomplete results after errors or cancellation.
- [Choose the Big Sur-compatible platform architecture](./tickets/02-choose-platform-architecture.md) — AppKit-first hybrid targeting macOS 11.0: `NSOutlineView` tree + custom Core Graphics `NSView` treemap under an `NSSplitViewController`, with SwiftUI via `NSHostingController` for leaf views only (SwiftUI `Table`/`Canvas`/`NavigationSplitView` are 12/13+); framework-free `ScanCore`/`TreemapLayout` Swift packages; a cancellable off-main `Task` with `@MainActor`, coalesced (~10–20 Hz) progress updates (Swift Concurrency back-deploys to 10.15).
- [Design the cancellable scan engine](./tickets/03-design-scan-engine.md) — `actor Scanner` in `ScanCore` exposing `scan(ScanRequest) -> AsyncStream<ScanEvent>`; serial iterative depth-first traversal over shallow `contentsOfDirectory` with prefetched resource keys and a per-subdirectory `volumeIdentifier` device-boundary check (the deep enumerator crosses mounts); logical `fileSizeKey` sizes rolled up incrementally; hard-link dedup by `fileResourceIdentifierKey` (indexed only for `linkCount > 1`, APFS clones fall out); cloud gated on `ubiquitousItemDownloadingStatusKey`; the actor owns the mutable tree while the UI reads frozen shared snapshots; cooperative `Task.isCancelled` checkpoints; errors mark entries Unreadable / ancestors Incomplete without guessing sizes; headless `DirectoryProbe` test seam. Also settles the root-eligibility predicate (`volumeIsLocalKey == true`).
- [Prototype the core scanning workspace](./tickets/04-prototype-core-workspace.md) — Three-pane split `tree │ treemap │ inspector` (`NSSplitViewController`, treemap as the growable item, ~300 pt collapsible inspector) accepted from a live human reaction; chooser sheet with ineligible sources shown disabled with reasons; indeterminate progress card with live telemetry and prominent Cancel; bidirectional single-source selection; ⌘O Open / ⌘R Reveal, read-only throughout; cancelled/partially-failed states stay browsable with unmistakable Incomplete banners; treemap layout/coloring, tree columns, inspector depth, package drill-in, and progress fidelity deliberately deferred.
- [Specify treemap layout and visual encoding](./tickets/05-specify-treemap.md) — Recursive squarified layout in `TreemapLayout` with nested directory frames (1 pt border + 2 pt padding per level); area strictly proportional to logical bytes; deterministic child order (bytes desc, name asc); render-only culling below 2×2 pt with bytes kept in ancestor totals; zero-attributed-byte items get no rectangle; fixed extension→kind-group→hue palette with status-bar legend; labels only when ≥ 48×15 pt; hover stroke + tooltip, 2 pt accent selection; deepest-node hit testing; pure recompute on resize (no cache/animation) for snapshot-testable geometry. Human confirmation of the nested-frames recommendation is pending.

## Not yet specified

- **Implementation decomposition.** Concrete build tickets, sequencing, and integration boundaries depend on the settled product and technical specification. <clears-with: 08>

## Out of scope

- File deletion, cleanup, mutation, duplicate detection, historical comparisons, and scheduled/background scanning are outside the read-only first version.
- Signing, notarization, packaging, distribution, analytics, and release infrastructure are outside the locally buildable deliverable.
