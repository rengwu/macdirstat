---
type: task
blocked_by: [01, 06, 07]
undermined_by: []
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
