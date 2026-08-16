---
type: task
blocked_by: [01, 06, 07]
undermined_by: []
claimed_by: s34e215ddf97c
claimed_at: 2026-08-16T14:25:31Z
---

# Treemap view + bidirectional selection + inspector + Open/Reveal

## Question

Complete the synchronized workspace: render the treemap, wire one shared selection across
tree ↔ treemap ↔ inspector, fill the inspector, and add the read-only Open and Reveal
actions. This turns the tree-only shell into the full three-pane experience. Built to the
gold-standard prototype (ticket 01); fixed by spec §6.3–§6.4, §7.1–§7.2, §10.

Implement in the app target:

- The **custom Core Graphics treemap `NSView`** rendering the ticket-06 layout output in
  classic-flat style: zero insets, per-depth directory outlines with 0.5 pt sibling
  hairlines, kind-colored file leaves, directories composed of children (no own fill),
  packages as one box, the neutral distinctly-filled merge-aggregate box, leaf labels at
  11 pt only when ≥ 48×15 pt (truncated with a halo), and the status-bar legend. Full
  recompute on resize (no cache/animation/hysteresis), coalesced to display refresh during
  divider drags.
- The **shared `@MainActor` selection model** (spec §7.2, §10): one source of truth
  referencing a node identity or an aggregate-box descriptor. Selecting a tree row
  highlights its treemap rectangle (a directory outlines its whole region) and fills the
  inspector; clicking a rectangle selects and scrolls-to the tree row and fills the
  inspector. Selecting a zero-byte tree row produces no false rectangle; selecting an
  aggregate describes the bucket without inventing an individual node. Hover shows a 1 pt
  stroke + tooltip; selection shows a 2 pt accent stroke inset 1 pt.
- The **inspector** (final field set from the ticket-01 prototype): IEC size **and** exact
  grouped bytes, full path, Ticket-01 flags (symlink / hard-link + owner / package /
  unreadable), and the aggregate's combined-count summary; hosted via `NSHostingController`
  if SwiftUI is used.
- **Read-only Open and Reveal** via an injectable `NSWorkspace` adapter (spy-testable),
  in the toolbar and inspector, with ⌘O / ⌘R and Return = expand/open; URLs reconstructed
  on demand from a node's parent chain. No mutation affordance anywhere.
- **Treemap accessibility children**: one per rendered rectangle (including directory
  regions and aggregates) in the deterministic sorted order, labelled name/size/kind (or
  combined count/size), focusable, with a selection-change announcement.

## Done when

- Rendering matches the ticket-01 prototype for classic-flat drawing (fixed-size bitmap
  regression fixtures in light/dark check zero insets, outlines, 0.5 pt hairlines, neutral
  aggregate, 1 pt hover, 2 pt inset accent selection); geometry assertions remain
  authoritative over cross-OS pixels.
- Bidirectional single-source selection works both directions and updates the inspector;
  a zero-byte tree selection leaves no false rectangle; an aggregate selection describes
  the bucket without an invented node; selection persists through relayout.
- ⌘O / ⌘R / Return and toolbar+inspector Open/Reveal call only the `NSWorkspace` spy with
  the exact reconstructed URL; a manual pass opens/reveals only disposable files; no
  menu/context-menu/toolbar/accessibility mutation affordance exists.
- Inspector content shows IEC + exact grouped bytes + path + flags + aggregate summary.
- Accessibility children are one-per-rendered-rectangle in sorted order with name/size/kind
  labels, focusability, selected state, and an announcement on shared-selection change.
- Dividers drag and the treemap recomputes live with no cache/animation/hysteresis.

## Answer

The synchronized three-pane workspace is built and, for the first time in this map,
**verified on screen** rather than only through tests. The treemap draws the ticket-06
layout in classic-flat style, one shared selection drives tree ↔ treemap ↔ inspector in
both directions, the inspector carries the ticket-01 field set, and Open/Reveal are the
only two file actions anywhere in the app.

**Six new files in the app target.** `SelectionModel` is the single source of truth
(`WorkspaceSelection` is a `ScanNode` identity or an `AggregateDescriptor`; a write that
changes nothing notifies nobody, so a tree click and its echo cannot bounce). `TreemapView`
is the Core Graphics `NSView`: zero insets, 0.5 pt sibling hairlines, 1 pt directory
outlines capped at three levels, kind-hue leaves, a hatched neutral aggregate, red hatch
over Incomplete, 11 pt haloed labels at ≥ 48×15 pt, 1 pt hover with tooltip, 2 pt accent
selection inset 1 pt, and one accessibility element per rendered rectangle.
`TreemapPresentation` is the whole `ScanCore` → `TreemapLayout` adapter — the two packages
still cannot see each other, and package drill-in lives in a `PackageExpansion` set beside
the frozen tree because a `ScanNode` cannot carry presentation state. `InspectorContent`
is the inspector *as data*, so "IEC **and** exact grouped bytes, path, flags, aggregate
summary" is a unit test rather than a screenshot; `InspectorViewController` renders it in
SwiftUI through `NSHostingController`, the one shape §4.1 permits. `WorkspaceActions` is
the injectable `NSWorkspace` seam with exactly two methods.

**43 new tests, 53 in `MacDirStatTests`.** Both selection directions, a zero-byte row
leaving no false rectangle, an aggregate described without an invented node, selection
surviving relayout, package drill-in leaving the outer rectangle's area unchanged
(asserted equal, not eyeballed), ⌘O/⌘R/Return/toolbar/inspector/context-menu all reaching
only the spy with the exact reconstructed URL, no mutation verb anywhere, and light/dark
bitmap regressions that assert *properties* of the rendered pixels — corners filled,
hairline on the shared edge, neutral aggregate distinguishable from all eleven hues,
accent stroke present at 1–3 pt inside the edge and absent on the edge itself. Golden
pixels are deliberately not compared: geometry assertions stay authoritative, as the
ticket asks.

**The window rendered blank, and only looking at it found that.** After the tests were
green I drove the real app through its own UI-test harness and screenshotted it: full-size
window, toolbar and status bar drawn, and all three panes not drawn at all. Every pane was
laid out correctly and answering accessibility queries with real values, so no test, no
query and no log noticed. Ten bisection runs against a ticket-07 baseline narrowed it to
one thing: a background view in the status bar that painted by overriding `draw(_:)`.
Painting the same colour through `updateLayer()` fixes it completely. A second, separate
defect surfaced on the way: the inspector's hosted view is pinned edge-to-edge and hugs
its content, and a constraint-driven window content view *takes its size from that* — the
content area collapsed to 42 pt inside a full-size window. Lowering the hosted view's
hugging priority fixes it (measured: fitting height 42 → 74, frame 42 → 700).

Three tests now lock those shapes, and their comments say plainly that **neither would
have found the bug**. That is the finding worth carrying to ticket 09: this app can be
entirely correct in its geometry, its accessibility tree and its 53 assertions while
rendering nothing, so §9.4's by-eye walkthrough is load-bearing, not ceremonial.

**Four judgment calls.**
1. **No "Logical length" row.** Ticket 01 settled that symlinks and hard-link non-owners
   show `0 bytes` with the real length on a separate row. `ScanCore` deliberately does not
   retain that nominal length — a non-owner is attributed zero and the number is dropped —
   so the row cannot be filled without an engine change, which is tickets 03/04's. The
   ticket's own required field list does not include it; the hard-link **owner path** is
   there and is shown. Recorded as a gap, not implemented here.
2. **The inspector's "Contains" row walks the subtree.** `ScanNode.fileCount` is live but
   there is no folder count, so the folder half is an O(subtree) walk on a frozen tree,
   once per selection change, never on the scan's hot path. It reports the *scanner's*
   numbers, per ticket 01 decision 10, which is why it differs from the status bar's.
3. **An aggregate selection is refreshed, not preserved, across a relayout.** A wider
   viewport folds fewer children, so the bucket's numbers change; the descriptor is
   re-read from the new layout, and if that directory no longer folds anything the
   selection clears rather than describe a box that is not there.
4. **The layout result is held for the frame it describes.** §6.4's "no cache" forbids
   reusing geometry across a size change, which never happens here — a resize invalidates
   before it repaints. Hit testing, hover and the accessibility children all have to
   answer for the rectangles currently on screen, so they read that one result.

**Also fixed in passing:** the status-bar legend now uses the settled 11-hue palette plus
the merge neutral instead of ticket 07's placeholder system colours, and follows the
appearance instead of freezing whichever one was current at load.

**Deliberately omitted:** ticket 09's cancelled/error presentation and error-summary
sheet; the treemap keyboard navigation §9.4 assigns to the tree; and the manual
VoiceOver/Accessibility Inspector walkthrough, which is the release checklist's.

Verification: `Scripts/verify-scaffold.sh` — twelve steps, both packages, all four schemes
and plans, Thread Sanitizer, the universal Release build, and 53 app tests.
