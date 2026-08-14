---
type: research
blocked_by: []
undermined_by: []
assets: [02-platform-architecture-research.md]
claimed_by: sb3ce9ebd536d
claimed_at: 2026-08-14T06:54:17Z
---

# Choose the Big Sur-compatible platform architecture

## Question

Which native macOS architecture and project shape best satisfy the Big Sur deployment target while supporting a responsive outline tree, a custom interactive treemap, folder and volume selection, cancellation, progress updates, and Finder integration? Establish which responsibilities belong in SwiftUI, AppKit, Foundation, and any compatibility adapters, and identify APIs that are unavailable on macOS 11.

## Done when

The ticket recommends a concrete application architecture and Xcode project shape, cites authoritative compatibility evidence for the important APIs, defines the concurrency and UI-update boundary, and lists rejected alternatives with concise reasons.

## Answer

**Recommendation: an AppKit-first hybrid app targeting macOS 11.0, with SwiftUI adopted tactically for leaf views.** Full cited findings, including every API-availability check against Apple's own documentation metadata, are in `assets/02-platform-architecture-research.md`.

**Why AppKit-first is forced by the Big Sur floor.** The two hardest, most interaction-critical panes cannot be SwiftUI on macOS 11: SwiftUI's multi-column sortable `Table` and its immediate-mode `Canvas` are both **macOS 12.0+**, and `NavigationSplitView` is **macOS 13.0+** (verified via Apple docs metadata). The only Big-Sur-capable SwiftUI list, `OutlineGroup`/`List(_:children:)` (macOS 11.0+), is single-column and does not scale. Therefore:

- **Directory tree → `NSOutlineView`** — mature multi-column, sortable, cell-reusing tree that scales to millions of rows.
- **Treemap → a custom `NSView` with Core Graphics `draw(_:)`** (optionally a cached bitmap/`CALayer`) with its own hit-testing — the only way to render and hit-test hundreds of thousands of rectangles on the floor.
- **Shell → `NSApplicationDelegate` + programmatic `NSWindowController` hosting an `NSSplitViewController`**, giving predictable control of the split divider, menu/first-responder validation, and the defining tree↔treemap selection sync without routing high-frequency hover/selection events through SwiftUI state.
- **SwiftUI, used tactically** via `NSHostingController`/`NSHostingView` (both macOS 10.15+, i.e. below the floor) for self-contained leaf UI — item inspector, progress panel, error/exclusion summary, empty states — where it does not cross the hot path.

**Xcode project shape.** One macOS App target (Swift, AppKit lifecycle, **Deployment Target macOS 11.0**), SwiftUI still linked for interop; **not** document-based (a scan is a transient session, not a saved document). The algorithms live in framework-free local Swift packages kept out of the UI target so they unit-test headlessly: `ScanCore` (Foundation-only traversal/aggregation/cancellation/progress/errors, per Ticket #01) and `TreemapLayout` (Foundation-only rectangle layout).

**Concurrency and UI-update boundary.** Swift Concurrency (`async`/`await`, `Task`, `actor`) is usable on Big Sur via the back-deployed runtime — Apple's Xcode 13.2 release notes state concurrency deploys back to **macOS 10.15**. The scan runs as a cancellable `Task` off the main thread; cancellation is cooperative (`Task.isCancelled` checked in the traversal loop, retaining discovered results); the node tree is `actor`/serial-queue isolated and the UI reads immutable snapshots. **All UI mutation is on `@MainActor`, and progress/incremental results are coalesced/throttled** (~10–20 Hz snapshot sampling of bytes/count/current-path/elapsed) rather than emitted per file, so the tree and treemap stay responsive under millions of entries. Selection/hover sync flows through a shared `@MainActor` selection model. Folder selection uses `NSOpenPanel` (`canChooseDirectories`); volume selection uses `FileManager.mountedVolumeURLs(...)` filtered by volume resource keys; Reveal/Open use `NSWorkspace.activateFileViewerSelecting(_:)` / `open(_:)` (read-only).

**APIs unavailable on macOS 11 (compatibility watch-list):** SwiftUI `Table` (12.0+), `Canvas` (12.0+), `NavigationSplitView` (13.0+), and `searchable` search fields (post-Big-Sur — use `NSSearchField`). Also note Apple's caveat that *system* async APIs annotated macOS 12+ stay gated even though the language concurrency features back-deploy, so traversal must use synchronous Foundation file APIs.

**Rejected alternatives:** pure SwiftUI (Table/Canvas gated above the floor); a SwiftUI `App`-lifecycle shell hosting the AppKit panes via `NSViewRepresentable` (viable but deprioritized — immature SwiftUI window/split on macOS 11, messier hot-path bridging; it is the documented migration path if the floor is later raised to 12/13); Mac Catalyst (not native macOS frameworks; macOS-only volume/Finder APIs awkward); cross-platform toolkits (violate the native-frameworks mandate); document-based `NSDocument` app (no persisted document in a read-only v1); and GCD-only concurrency (workable but unnecessary now that Swift Concurrency back-deploys).

**Excluded / deferred (not this ticket):** detailed scan-engine internals and the exact volume-eligibility predicate (Ticket #03), the treemap layout algorithm and interaction detail (Ticket #05), and prototype-discovered interaction refinements (Ticket #04). This ticket fixes only architecture, project shape, framework responsibilities, and the concurrency/UI-update boundary. Signing/notarization/packaging remain out of scope per the map, though the security-scoped-access pattern is noted because it affects a locally buildable sandboxed app.
