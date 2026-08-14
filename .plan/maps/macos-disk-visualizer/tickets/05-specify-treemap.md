---
type: prototype
blocked_by: [01, 04]
undermined_by: []
assets: []
claimed_by: s2f181979b8be
claimed_at: 2026-08-14T08:38:48Z
---

# Specify treemap layout and visual encoding

## Question

How should filesystem hierarchy and relative size become stable, legible WinDirStat-style rectangles? Settle the rectangle-packing algorithm, hierarchy depth, minimum visible item policy, directory versus file treatment, color encoding, labels, hover and selection affordances, hit testing, resizing stability, and behavior for extreme size distributions.

## Done when

A linked prototype covers representative, dense, deeply nested, and extreme-size datasets; the human accepts its visual and interaction behavior; and the answer defines deterministic geometry, rendering, accessibility, and selection rules suitable for implementation and snapshot or geometry tests.

## Answer

**Settled: recursive squarified treemap with nested directory frames (1 pt border + 2 pt padding per level), area strictly proportional to logical bytes, deterministic sort order, fixed kind-group palette, and a cull-don't-fake policy for sub-visible and zero-byte items.** The geometry below is a pure function of `(tree, viewport size, insets)` and is therefore snapshot/geometry-testable, exactly as Ticket #02's framework-free `TreemapLayout` package requires.

> **Human confirmation pending.** This session ran unattended, so unlike Ticket #04 no live human reaction has happened yet. Open `prototype/treemap-layout-prototype.html`, cycle the three variants (◀ ▶) across all four datasets (keys 1–4), and confirm the **Nested frames** recommendation; only a human may reopen this ticket if it disagrees.

### Prototype (primary source)

`prototype/treemap-layout-prototype.html` — one self-contained file, double-click to run (no server/build). Canvas-rendered to mirror the custom Core Graphics `NSView` target. Three structurally different hierarchy treatments cycle via `?variant=` + the floating "Proto" bar: **Classic flat** (WinDirStat-style: zero insets, directory outlines overdrawn), **Nested frames** (recommended), **Headered directories** (name strip per directory — the foil: headers break area proportionality, dropping area coverage to 76–92% and shredding deep chains). Four deterministic datasets (seeded PRNG): **Representative** (~3.9 GiB home folder with packages, hidden files, symlink/hard-link/unreadable edge cases), **Dense** (2,500 small files), **Deep** (14-level nesting), **Extreme** (one 38 GiB image vs 600 tiny files + zero-byte entries). Hover = highlight + tooltip; click = selection; a state panel surfaces hovered/selected item details and full layout stats after every action.

Headless validation (node harness extracting the file's pure layout core; 91/91 checks pass): byte-identical geometry across runs; all rects in bounds; no leaf overlap; zero-byte items never get rects; nothing rendered below the 2 pt cull threshold; hit testing returns the deepest node; classic variant's rendered+culled area accounts for 100.0% of viewport (area ⟺ bytes end to end); squarified worst aspect beats slice-and-dice decisively (extreme top level 29:1 vs 3,845:1; representative 2.0 vs 26.4). Layout of 2,600 rects takes 0.2–2.4 ms in interpreted JS — trivially fast enough for live relayout in Swift.

### Geometry (the spec)

- **Algorithm:** squarified treemap (Bruls, Huizing, van Wijk), applied recursively per directory. Children enter the layout sorted **bytes descending, ties by name ascending (code-point order)** — this sort order is part of the spec, so identical trees always produce identical rectangles.
- **Area:** strictly proportional to attributed logical bytes (Ticket #01). No log scaling, no minimum-area cheating, no synthetic "other" box.
- **Precision:** layout in unrounded points; snap to the pixel grid only at draw time via the backing scale factor; no cumulative integer rounding.
- **Insets (Nested frames):** each directory level insets its children by 1 pt border + 2 pt padding. The directory's interior (padding, culled children) is a subtle neutral fill, so culled regions read as "directory", not as void.
- **Minimum visible policy:** leaves laid out below **2×2 pt** are culled from rendering and hit-testing. Their bytes remain in ancestor totals; the parent reports "… N items below visible size (total X)" in tooltip/inspector. Nothing is dropped from the data model — culling is render-only.
- **Zero-attributed-byte items** (empty files, symlinks, hard-link non-owners, unreadable entries with unknowable size) get **no rectangle by design**; the tree and inspector carry them. This preserves Ticket #01's "size is never guessed".

### Visual encoding

- **Color:** fixed extension → kind-group → hue table (11 groups — code, image, video, audio, document, archive, app, diskimage, font, data, system — plus gray "other"), HSL with lightness adapted for dark mode. Same extension = same color on every run; legend lives in the status bar per Ticket #04. Exact hues are tunable constants, not load-bearing.
- **Directory vs file:** directories contribute frame + neutral interior only (their area is composed of children); files carry the kind color. Packages remain one leaf box (Ticket #01). **Incomplete** directories (Ticket #01) get a red diagonal hatch overlay; an unreadable leaf has no rect and is marked Unreadable in the tree.
- **Labels:** leaf name at 11 pt only when the rect is ≥ 48×15 pt, ellipsis-truncated, drawn with a contrast halo. Directories are unlabeled in the winning variant (headers were the rejected variant).
- **Hover:** 1 pt high-contrast stroke + tooltip with name, IEC size **and** exact grouped bytes, full path, Ticket-01 flags (symlink / hard-link + owner / package / unreadable), and the culled-children summary for directories.
- **Selection:** single selection shared with the tree per Ticket #04; the selected rect gets a 2 pt system-accent stroke inset 1 pt; selecting a directory outlines its whole region.

### Hit testing, resizing, extremes, accessibility

- **Hit testing:** deepest rendered node whose frame contains the point wins (parents precede children in draw order; last match wins — deterministic because sibling rects are disjoint). Directory padding/border hits the directory itself; culled items are not hit-testable.
- **Resizing stability:** full recompute from `(tree, viewport)` on every size change — no cache, no animation, no hysteresis — coalesced to display refresh during divider drags (Ticket #04's "treemap re-layouts live"). Determinism makes geometry tests a golden-rect list per fixture tree.
- **Extreme distributions:** descending-order squarified keeps aspect ratios sane under 10⁴:1 size skew; the tiny tail culls into the parent region with an item count, so a 38 GiB file next to 600 KiB-scale files stays truthful and legible. Deep chains (14 levels) degrade to strips — inherent to the data shape, acceptable, and visible in the Deep dataset.
- **Accessibility:** every rendered rect is an accessibility child in the deterministic sorted order, labelled "name, size, kind"; selection changes post `NSAccessibilityAnnouncementNotification`; color is never the only channel (kind is named in tooltip/inspector/legend, Incomplete also carries hatch + text); keyboard navigation stays in the tree (Ticket #04), with the treemap focusable and its selection following the shared model; no motion, so reduced-motion needs nothing special.

### Omitted / boundaries

- Classic-flat and headered variants, the variant switcher, and the whole HTML shell are prototype-only; the deliverable is the rule set above. Per Ticket #04's flag, moving `prototype/` to a throwaway branch remains a human follow-up — it stays in the map folder here for consistency with #04's durable record.
- Still deferred per Ticket #04: tree columns & sorting, inspector field set, package drill-in interaction, progress fidelity. Build decomposition is Ticket #08; implementation is the future `-impl` map (this map plans, it does not do).
