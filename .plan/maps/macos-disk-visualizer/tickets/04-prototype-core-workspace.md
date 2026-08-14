---
type: prototype
blocked_by: [01]
undermined_by: []
assets: []
claimed_by: s37f511f350cf
claimed_at: 2026-08-14T07:15:35Z
---

# Prototype the core scanning workspace

## Question

What should the first version look and feel like across empty, choosing, scanning, completed, cancelled, and partially failed states? Prototype the folder or drive chooser, progress and cancellation controls, directory tree, treemap, synchronized selection, details presentation, resizing, keyboard behavior, and the Open and Reveal actions so a human can react to the complete workflow.

## Done when

A linked, disposable prototype demonstrates every major state and selection path; the human has reacted to it live; and the ticket records the accepted layout, interaction rules, macOS conventions, and deliberately deferred refinements.

## Answer

**Accepted layout: the three-pane split — `tree │ treemap │ inspector` side by side — chosen by the human from a live reaction to three structurally different variants.** A disposable HTML prototype exercised every lifecycle state and selection path; this ticket records the settled interaction model and the refinements deliberately left for later.

### Prototype (primary source)

`prototype/core-workspace-prototype.html` — one self-contained file, double-click to run (no server/build). It mocks the *native* AppKit workspace (`NSSplitViewController` + `NSOutlineView` tree + custom Core Graphics treemap `NSView`) purely so a human can react. Three layouts cycle via `?variant=` + a floating "Proto" bar (← → / arrows): **Classic split** (tree over treemap), **Three-pane** (the winner), **Treemap-first** (map hero + rail + popover). A second "State" control jumps to every lifecycle state, and the toolbar "Choose…" runs the real flow (chooser → animated live scan → results). Logic was validated headlessly (rollups don't double-count; symlink/hard-link attribute 0 bytes; treemap covers ~94% area within bounds; all state transitions and inspector variants render clean).

> **Verdict.** Question — *what should v1 look and feel like across empty/choosing/scanning/completed/cancelled/partially-failed?* — settled as: the **three-pane split**, with the interaction rules below. The other two variants and the variant switcher are prototype-only and must not enter the implementation map's main code.

### Accepted layout & macOS conventions

- **Shell:** `NSSplitViewController` with three split items — **left** directory tree (`NSOutlineView`, source-list styling), **center** treemap (the growable item), **right** inspector (fixed ~300 pt, collapsible). Unified toolbar; bottom status bar carries scanned total / file+folder counts / (for volumes) capacity & free / error & exclusion counts / a size-color legend.
- **Chooser:** toolbar "Choose…" opens a sheet listing eligible sources (internal + directly-attached drives, plus "choose folder…" via `NSOpenPanel canChooseDirectories`). Ineligible sources — network volumes, mounted disk images, cloud-provider roots — are shown **disabled with the reason inline**, not hidden, so the scope rule from Ticket #01 is legible.
- **Empty state:** centered call-to-action in the content area (not a blank window), stating read-only + hidden-files-included + drive-eligibility up front.
- **Scanning:** centered progress card — indeterminate bar (a coarse, explicitly-approximate % only for whole-volume scans), live telemetry (measured bytes, files, folders, elapsed, current path), and a prominent **Cancel**. Tree and treemap populate incrementally behind it.
- **Sizes:** binary IEC everywhere (KiB/MiB/GiB), exact grouped byte count in the inspector (Ticket #01).
- **Read-only actions:** **Open** (`NSWorkspace.open`) and **Reveal in Finder** (`activateFileViewerSelecting`) in the toolbar and inspector; no mutation affordances anywhere.

### Interaction rules

- **Synchronized selection is bidirectional and single-source:** selecting a tree row highlights its treemap rectangle (a directory highlights its whole region) and fills the inspector; clicking a treemap rectangle selects and scrolls-to the tree row and fills the inspector. One shared `@MainActor` selection model, exactly as Ticket #02 specified.
- **Keyboard:** ↑/↓ move the tree selection; ⌘O = Open, ⌘R = Reveal, Return = expand/open; Esc dismisses the chooser. (In the prototype ←/→ cycle *variants*; that switcher is prototype-only and ships hidden.)
- **Resizing:** every split divider drags; the treemap re-layouts live; the inspector can collapse.
- **State legibility:** **Cancelled** shows an unmistakable "Incomplete — scan cancelled" banner, retains partial results as fully browsable/selectable, and offers a fresh scan. **Partially-failed** ("Completed with errors") marks the unreadable entry **Unreadable** (size never guessed), every affected ancestor **Incomplete**, and surfaces an error summary + an excluded-cloud-items count. Ticket-01 semantics are shown concretely per item: symlink (0 bytes, "never followed"), hard link ("counted elsewhere" + owner path), iCloud materialized-vs-omitted, package as one box.

### Deliberately deferred (fog, not decisions)

- **Treemap layout & coloring** — the prototype's squarified layout and kind-based palette are illustrative only; the real algorithm, cushioning, color mapping, hover/zoom, and hit-testing are **Ticket #05**.
- **Tree columns & sorting** — exact `NSOutlineView` columns (size / % / count / kind), default sort, and the percent-bar treatment.
- **Inspector depth** — final field set, and whether Reveal/Open also live in a right-click context menu.
- **Package drill-in** — the collapsed-package → expand-to-children interaction (aggregate is already fixed by Ticket #01).
- **Progress fidelity** — final throttle cadence and the exact volume-scan approximation copy.
- **Not adopted:** Classic-split and Treemap-first layouts, and the variant switcher — prototype-only.

### Notes / boundaries

- **No version control in this working tree** (`git rev-parse` fails), so the prototype-skill "capture to a throwaway branch off main" step can't run here and no commit was made; `claimed_by`/`claimed_at`/`audit.jsonl` likewise could not be committed. The prototype folder under this map is therefore the durable primary-source record. **Flag for a human:** when this tree is under git, move `prototype/` and the losing variants to a throwaway branch and leave only the decision above on main.
- This ticket fixes look/feel and interaction only. It does not implement app code (planning map, "plan don't do"); build decomposition is Ticket #08 and the treemap spec is Ticket #05.
