# Platform architecture research — Big Sur-compatible macOS disk visualizer

Research backing **Ticket #02 — Choose the Big Sur-compatible platform architecture**
(`.plan/maps/macos-disk-visualizer/tickets/02-choose-platform-architecture.md`).

**Question.** Which native macOS architecture and Xcode project shape best satisfy a
macOS 11 (Big Sur) deployment target while supporting a responsive outline tree, a
custom interactive treemap, folder/volume selection, cancellation, progress updates,
and Finder integration — and which APIs are unavailable on macOS 11?

Every platform-availability claim below was read from Apple's own machine-readable
documentation metadata (the `…/tutorials/data/…json` feed that backs each
`developer.apple.com/documentation/…` page), which carries the same `@available`
annotations the compiler enforces. Versions were captured on **2026-08-14**.

---

## 1. Verified API availability (Apple primary sources)

### 1.1 SwiftUI capabilities gated *above* macOS 11 (cannot be relied on for a Big Sur floor)

| API | Min. macOS | Consequence for this app | Source |
| --- | --- | --- | --- |
| `Table` (multi-column, sortable) | **12.0** | No SwiftUI multi-column sortable tree on Big Sur. | [swiftui/table](https://developer.apple.com/documentation/swiftui/table) |
| `Canvas` (immediate-mode 2D drawing) | **12.0** | No SwiftUI immediate-mode surface for the treemap on Big Sur. | [swiftui/canvas](https://developer.apple.com/documentation/swiftui/canvas) |
| `NavigationSplitView` | **13.0** | No first-class SwiftUI split container on Big Sur. | [swiftui/navigationsplitview](https://developer.apple.com/documentation/swiftui/navigationsplitview) |

`searchable(...)` search fields are likewise a post-Big-Sur SwiftUI addition; a text
filter, if added, should use AppKit's `NSSearchField` (available since the earliest
AppKit) rather than the SwiftUI modifier. (Not independently version-checked here;
treated conservatively by choosing the AppKit control.)

### 1.2 SwiftUI capabilities available *on* macOS 11

| API | Min. macOS | Note | Source |
| --- | --- | --- | --- |
| `App` protocol / `@main` scene lifecycle | **11.0** | SwiftUI app lifecycle *is* usable on Big Sur. | [swiftui/app](https://developer.apple.com/documentation/swiftui/app) |
| `OutlineGroup` / `List(_:children:)` | **11.0** | Single-column hierarchical rows only — no column headers, no per-column sort. | [swiftui/outlinegroup](https://developer.apple.com/documentation/swiftui/outlinegroup) |

### 1.3 SwiftUI ⇄ AppKit interop (all present since macOS 10.15, i.e. below the floor)

| API | Min. macOS | Role | Source |
| --- | --- | --- | --- |
| `NSViewRepresentable` | **10.15** | Wrap an `NSView` for use inside SwiftUI. | [swiftui/nsviewrepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable) |
| `NSHostingView` | **10.15** | Embed a SwiftUI view inside AppKit view hierarchy. | [swiftui/nshostingview](https://developer.apple.com/documentation/swiftui/nshostingview) |
| `NSHostingController` | **10.15** | Embed a SwiftUI view as an `NSViewController`. | [swiftui/nshostingcontroller](https://developer.apple.com/documentation/swiftui/nshostingcontroller) |

Interop works in **both** directions on Big Sur, so the two frameworks can be mixed freely.

### 1.4 AppKit / Foundation primitives for the core panes and OS integration

| API | Min. macOS | Role | Source |
| --- | --- | --- | --- |
| `NSOutlineView` | macOS (since 10.0; no lower bound listed) | Mature multi-column, sortable, cell-reusing tree at scale. | [appkit/nsoutlineview](https://developer.apple.com/documentation/appkit/nsoutlineview) |
| Custom `NSView` + Core Graphics `draw(_:)` | macOS (since 10.0) | Performant custom treemap rendering + hit-testing. | [appkit/nsview](https://developer.apple.com/documentation/appkit/nsview) |
| `NSWorkspace.activateFileViewerSelecting(_:)` | **10.6** | "Reveal in Finder" (read-only). | [appkit/nsworkspace/activatefileviewerselecting(_:)](https://developer.apple.com/documentation/appkit/nsworkspace/activatefileviewerselecting(_:)) |
| `NSWorkspace.open(_:)` | macOS (since 10.0) | "Open" with default app (read-only). | [appkit/nsworkspace/open(_:)](https://developer.apple.com/documentation/appkit/nsworkspace) |
| `NSOpenPanel` (`canChooseDirectories`) | macOS (long-standing) | Folder selection + sandbox access grant. | [appkit/nsopenpanel](https://developer.apple.com/documentation/appkit/nsopenpanel) |
| `FileManager.mountedVolumeURLs(includingResourceValuesForKeys:options:)` | **10.6** (macOS-only; returns `nil` elsewhere) | Enumerate mounted volumes for the volume picker. | [filemanager/mountedvolumeurls…](https://developer.apple.com/documentation/foundation/filemanager/mountedvolumeurls(includingresourcevaluesforkeys:options:)) |
| `FileManager.enumerator(at:includingPropertiesForKeys:options:errorHandler:)` | **10.10** | Directory enumeration building block. | [filemanager/enumerator(at:…)](https://developer.apple.com/documentation/foundation/filemanager/enumerator(at:includingpropertiesforkeys:options:errorhandler:)) |

### 1.5 Concurrency runtime

> "You can now use Swift Concurrency in applications that deploy to **macOS Catalina
> 10.15, iOS 13, tvOS 13, and watchOS 6 or newer.** This support includes
> `async`/`await`, actors, global actors, structured concurrency, and the task APIs."
> — Apple, [Xcode 13.2 Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-13_2-release-notes)

So `async`/`await`, `Task` (with cooperative cancellation), and `actor` isolation are
**available on the Big Sur floor** via the back-deployed concurrency runtime bundled
into the app. Caveat (from the same note): *system* APIs annotated with the 2021 OSes
(macOS 12+) are still gated even though the language features are not — traversal code
must stick to synchronous Foundation file APIs on background tasks and must not call
macOS 12+ async system APIs.

---

## 2. What the evidence forces

Both performance-critical, feature-rich panes must be AppKit on a macOS 11 floor:

- **Directory tree** needs multiple sortable columns (name, size, %, item count, kind)
  over potentially millions of rows with cell reuse. SwiftUI's `Table` (§1.1) is 12.0+;
  the only Big-Sur-capable SwiftUI option, `OutlineGroup`/`List` (§1.2), is single-column
  and does not scale. → **`NSOutlineView`.**
- **Treemap** needs immediate-mode drawing and hit-testing of up to hundreds of thousands
  of rectangles. SwiftUI's `Canvas` (§1.1) is 12.0+; pre-12 SwiftUI drawing allocates a
  view per shape and does not scale. → **custom `NSView` with Core Graphics.**

Everything else (lifecycle, split container, interop, Finder actions, volume/folder
pickers, concurrency) is available at or below macOS 11.

---

## 3. Recommended architecture

**AppKit-first hybrid, with SwiftUI adopted tactically for leaf views.**

- **Lifecycle / shell:** AppKit `NSApplicationDelegate` + programmatic `NSWindowController`
  hosting an `NSSplitViewController`. Full, predictable control of the split divider,
  first-responder/menu validation, and the *tight, high-frequency tree↔treemap selection
  sync* — the app's defining interaction — without routing hover/selection events through
  SwiftUI state on the hot path. (SwiftUI's own window/split story is weakest exactly at
  the macOS 11 floor: `NavigationSplitView` is 13.0+.)
- **Tree pane:** `NSOutlineView` inside the split view, driven by a data-source/delegate
  backed by the shared model.
- **Treemap pane:** custom `NSView` (Core Graphics `draw(_:)`, optionally a cached bitmap
  / `CALayer` for redraw economy) with its own hit-testing for hover and selection.
- **SwiftUI, used tactically** via `NSHostingController`/`NSHostingView` (§1.3) for
  self-contained leaf UI where declarative code pays off and the hot path is not crossed:
  item inspector/details, progress panel, error/exclusion summary, empty/onboarding states.
- **Shared, framework-free core** (see §4) owns the node tree, selection model, progress,
  and errors; both panes observe it.

This is the lowest-risk shape for a macOS 11 deployment target. A **SwiftUI `App`-lifecycle
shell hosting the two AppKit panes via `NSViewRepresentable`** is a viable alternative and
the natural migration target *if the floor is later raised to macOS 12/13* (unlocking
`Table`, `Canvas`, `NavigationSplitView`) — see §6.

---

## 4. Xcode project shape

- **Single macOS App target**, language Swift, AppKit app-delegate lifecycle, **Deployment
  Target = macOS 11.0**; the SwiftUI framework is still linked for leaf views and interop.
- **Not** a document-based (`NSDocument`) app — a scan is a transient session, not a saved
  document; v1 is read-only with no open/save file model.
- Programmatic view construction for the data-driven tree/treemap (a single main-menu
  storyboard/xib is fine); storyboards add little for custom-drawn, dynamic views.
- **Framework-free algorithm modules as local Swift packages**, kept out of the UI target
  so they unit-test headlessly and stay reusable:
  - `ScanCore` (Foundation only): traversal, size aggregation, node model, cancellation
    token, progress emitter, error/exclusion accumulation — the semantics settled in
    Ticket #01. *(Detailed engine = Ticket #03.)*
  - `TreemapLayout` (Foundation only): the rectangle-layout algorithm over the node tree.
    *(Detailed treemap = Ticket #05.)*

---

## 5. Concurrency and the UI-update boundary

- **Executor:** the scan runs as a cancellable `Task` (or a background
  `DispatchQueue`/`OperationQueue`). Traversal, aggregation, and treemap layout run
  **off the main thread**. Swift Concurrency is fine on Big Sur (§1.5).
- **Cancellation:** cooperative — the traversal loop checks `Task.isCancelled` (or a flag)
  frequently, stopping promptly while retaining everything already discovered (Ticket #01's
  "Incomplete — scan cancelled" requirement).
- **Model isolation:** the node tree is owned by an `actor` (or a serial queue); the UI
  reads immutable snapshots, never the live mutating structure.
- **UI-update rule:** *all* UI mutation on `@MainActor`. The scanner emits raw events at
  very high frequency (millions of entries), so the UI layer **coalesces/throttles**:
  a bounded-cadence sampler (~10–20 Hz, timer- or display-driven) publishes the latest
  snapshot — bytes scanned, item count, current path, elapsed — and drives `NSOutlineView`
  reloads and treemap redraws. **Never** update per file.
- **Selection sync:** tree↔treemap selection/hover flows through a shared `@MainActor`
  selection model operating on already-built node references — cheap, main-thread, no
  representable bridging.
- **Security-scoped access:** the `NSOpenPanel` selection grants access to the chosen
  folder/volume; for a sandboxed build wrap traversal in
  `startAccessingSecurityScopedResource()` / `stopAccessing…`. (Entitlement *packaging* is
  out of scope per the map; the *access pattern* is in scope for a locally buildable app.)
- **Volume/folder selection:** folders via `NSOpenPanel` (`canChooseDirectories = true`,
  `canChooseFiles = false`); volumes via `FileManager.mountedVolumeURLs(...)` filtered with
  resource keys such as `.volumeIsInternalKey`, `.volumeIsLocalKey`, `.volumeIsRemovableKey`,
  `.volumeIsRootFileSystemKey` to honor Ticket #01's "internal or directly attached physical"
  eligibility. (Exact eligibility predicate = Ticket #03.)
- **Finder actions (read-only):** Reveal = `NSWorkspace.shared.activateFileViewerSelecting([url])`;
  Open = `NSWorkspace.shared.open(url)`.

---

## 6. Rejected / deprioritized alternatives

1. **Pure SwiftUI (SwiftUI for tree *and* treemap).** Rejected: `Table` and `Canvas` are
   macOS 12.0+ (§1.1); pre-12 SwiftUI can't give a multi-column sortable tree or a
   performant large-N treemap on the macOS 11 floor. Reconsider only if the floor rises.
2. **SwiftUI `App` lifecycle hosting the AppKit panes via `NSViewRepresentable`.**
   *Deprioritized, not impossible* — the `App` protocol is macOS 11+ (§1.2). On the macOS 11
   floor SwiftUI window/split management is immature (`NavigationSplitView` 13.0+), and the
   high-frequency selection sync is cleaner without representable bridging. This is the
   documented migration path if the floor is later raised to macOS 12/13.
3. **Mac Catalyst (UIKit).** Rejected: not "native macOS frameworks" per the map; weaker
   dense-tree/treemap ergonomics; several volume/Finder APIs are macOS-only or awkward under
   Catalyst; non-native window/menu feel.
4. **Cross-platform toolkits (Electron, Qt, Flutter).** Rejected: violate the native
   Swift/macOS-frameworks mandate; heavier, non-native.
5. **Document-based (`NSDocument`) app.** Rejected: a scan is a transient session, not a
   persisted document; adds unused save/open machinery to a read-only v1.
6. **GCD only, avoiding Swift Concurrency.** *Not* rejected as unworkable (it runs on 11),
   but unnecessary: concurrency back-deploys to 10.15 (§1.5), so structured concurrency with
   cooperative cancellation is available and preferred; GCD remains a fine executor choice.

---

## 7. Scope boundaries handed to downstream tickets

- Detailed **scan-engine** design (exact traversal APIs, device-boundary enforcement,
  hard-link dedup mechanics, volume-eligibility predicate) → **Ticket #03**.
- **Treemap** layout algorithm and interaction detail → **Ticket #05**.
- Interaction refinements that only surface once the tree/treemap/progress/selection are
  reactive → **Ticket #04** (prototype).
- This ticket fixes only the **architecture, project shape, framework responsibilities, and
  concurrency/UI-update boundary**.
