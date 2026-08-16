---
type: task
blocked_by: [01, 02]
undermined_by: []
claimed_by: sa3e8089a6d8e
claimed_at: 2026-08-16T11:58:14Z
---

# TreemapLayout geometry + merge + palette

## Question

Build the pure, deterministic treemap layout engine — a function of `(tree, viewport)`
producing the rectangles the treemap view will draw and hit-test — with the reconciled
merge-bucket rule and the kind-group palette classification. No drawing here; this is the
Foundation-only geometry package. Fixed by spec §6 (the reconciled §6.2 merge rule is
authoritative over the planning map's earlier culling wording); the gold-standard
prototype (ticket 01) fixes the exact palette hues and label thresholds.

Implement in the treemap-layout package:

- A **lightweight input protocol/type** for the node tree (bytes, children, kind, status
  flags) so the package stays independent of the scan-engine package.
- **Recursive squarified layout** applied per directory; children enter sorted **bytes
  descending, ties by name ascending (code-point order)**; area **strictly proportional to
  attributed logical bytes** — no log scaling, minimum-area inflation, insets, or headers.
  Layout in unrounded points; pixel-grid snapping only at draw time via an injected backing
  scale.
- The **merge rule (spec §6.2)**: within each directory, every child (leaf **or** entire
  too-small subtree) whose individual rectangle would fall below **2×2 pt** folds into
  **exactly one aggregate box** per directory whose area equals the exact sum of their
  bytes. The aggregate is hit-testable and reports its combined bytes and recursive item
  count. Visible individual + aggregate area accounts for **100%** of nonzero bytes.
- **Zero-attributed-byte items** get **no rectangle** (empty files, symlinks, hard-link
  non-owners, unknowable unreadable entries).
- **Deepest-node hit testing**: the deepest rendered node whose frame contains a point
  wins; an aggregate interior returns the aggregate.
- **Palette classification**: extension → one of 11 kind groups + "other", stable across
  runs, with the exact hues (light + dark) taken from the ticket-01 prototype.

## Done when

- `TreemapLayoutTests` prove golden rectangles for small hand-computable trees and
  byte-identical geometry across repeated runs before draw-time snapping; every rectangle
  in bounds, no leaf overlap, no negative area.
- For every directory, child + aggregate areas sum to the parent within a scale-relative
  epsilon; no inset, header, log scaling, or minimum-area inflation exists.
- Every child below 2×2 pt at several viewports/backing scales goes into exactly one
  per-directory aggregate with exact byte total and recursive item count, hit-testable,
  with visible individual + aggregate = 100% of nonzero bytes; tiny subtrees exercise the
  same rule.
- Zero-byte items produce no geometry; equal-byte names verify code-point ascending ties;
  extreme (40 GiB + tiny tail), dense (2,500-item), and depth-64 trees stay deterministic,
  bounded, and crash-free with visible-box count bounded by individual boxes plus one
  aggregate per affected directory.
- Hit testing returns the deterministic deepest rendered node; aggregate interiors return
  the aggregate. Palette classification maps every settled extension to its kind group with
  stable same-extension color.

## Answer

The geometry engine is built and green: **71 tests in `TreemapLayoutTests`**, the whole
of §6 provable without a window. `Scripts/verify-scaffold.sh` still exits 0 — all twelve
steps, both packages, all four schemes and plans, and the universal Release build.

**What was built** (`Packages/TreemapLayout/Sources/TreemapLayout/`)

- **`TreemapInputNode`** — the seam. Five requirements (name, kind, read state, attributed
  bytes, presented children) and nothing else, so `ScanCore` and `TreemapLayout` still do
  not know about each other. Two decisions are baked into its shape: `treemapAttributedBytes`
  is the **subtree** total, not the entry's own size, so a collapsed package can report
  12 GiB while presenting no children; and `treemapPresentedChildren` is **presentation, not
  structure**, which is how package drill-in is expressed without the engine owning any UI
  policy. `TreemapTree` is a concrete conformance for fixtures and callers who already hold
  a value tree.
- **`TreemapGeometry`** — the package's own `TreemapPoint`/`Size`/`Rect`, because it cannot
  see CoreGraphics. Containment is **half-open**, which is what makes deepest-node hit
  testing deterministic on a shared edge without a tie-break rule.
  `snapped(toBackingScale:)` is the only rounding in the package and the view is the only
  caller: it rounds **both edges** and takes the difference, so abutting siblings stay flush
  instead of accumulating seams.
- **`SquarifiedLayout`** — Bruls/Huizing/van Wijk as one pure `(weights, rect) -> [rect]`,
  index-aligned with its input. It knows nothing about merging, which is what makes it
  re-runnable; a test asserts that ignorance against its source.
- **`PreparedTree`** — one normalization pass: drop zero-byte entries, sort children, roll
  up item counts. Built **breadth-first and iteratively**, so the fixpoint sees identical
  numbers every round and depth costs heap, not stack.
- **`TreemapLayout.layout(tree:viewport:)`** — the merge fixpoint and the tree walk, also
  iterative. Returns a flat draw list (parents always before their children), per-box
  `parentIndex`, and statistics.
- **`TreemapPalette`** — the 11 kind groups plus gray "other", 98 extensions, the respaced
  hues, sat 55%, lightness 52%/60%, and framework-free sRGB via an HSL initializer.
- **`TreemapMetrics`** — the settled numbers in one place, so the threshold the engine
  applies and the threshold the tests assert are the same constant.

**Measured, at 520×390** — the prototype's own bench viewport:

| fixture | boxes | visible | aggregates | merged items | rounds | passes | area |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Realistic | 11 | 7 | 2 | 17 | 2 | 6 | 100.000000% |
| 40 GiB + tail | 3 | 2 | 1 | 40 | 2 | 2 | 100.000000% |
| Flat 2,500 | 1,061 | 1,060 | 1 | 1,441 | 2 | 2 | 100.000000% |
| Deep ×64 | 129 | 64 | 0 | 0 | 1 | 65 | 100.000000% |

Zero sub-2 pt survivors on all of them, at five viewports down to 60×40 and at backing
scales 1/2/3 — which reproduces ticket 01's bench result on the production engine. The
fixpoint settles in **two rounds** everywhere, as the pinned-last aggregate promised.
A full relayout of the 2,500-item fixture is **5.4 ms** in Release (0.08 ms for the skew
fixture); §8.2 commits no wall-clock bar, so this is a recorded number, not a threshold.

**Four judgment calls**

1. **The tie-break is true code-point order**, compared over Unicode scalars, not
   `String <`. §6.1 says code-point; Swift's `<` orders by Unicode canonical equivalence.
   Both are locale-independent and deterministic, so this is only visible between two
   siblings of *identical* size whose names differ in normalization — but the spec named
   one of them, and `ScanCore`'s traversal sort (a different sort, for listing order)
   deliberately keeps `<`. A third tie-break on discovery position makes the order total,
   so the result never depends on how the sort algorithm handles equal elements.
2. **An aggregate's item count excludes zero-attributed entries** inside the folded
   subtrees. They had no rectangle to lose, merged or not, and §6.2 keeps them in the tree
   either way; counting them would make *"N items below individual size"* mean something
   different from what it says. The invariant that falls out is exact: individually drawn
   entries + merged item counts = every positive-byte entry in the tree.
3. **An aggregate is exempt from the sliver test.** It has nothing left to fold into, so
   a directory whose whole rectangle is under 2 pt ends as one aggregate covering it —
   truthful, rather than blank. Verified at a 1.5×1.5 pt viewport.
4. **Each directory is scaled by its own children's byte sum**, not by its declared total.
   On consistent input (which `ScanCore` guarantees) these are the same number; where they
   ever disagree, this choice keeps the parent's rectangle exactly filled rather than
   leaving a gap, which is the property §6.2 actually promises.

**Proven, not asserted**

Golden rectangles are hand-computed twice: a 4,000/3,000/2,000/1,000 tree at 100×100
(1 pt² per byte, so `[a, b]` fill a 70 pt strip and `c`/`d` stack in the 30 pt column),
and a 9,990-plus-5-plus-3-plus-2 tree whose tail lands as 0.1 pt strips, folds, and
re-packs to leave the survivor at exactly 99.9 pt. "No inset, header, log scaling, or
minimum-area inflation" is proven **behaviourally** — three levels of nesting cost a leaf
no area; doubling a child's bytes doubles its area at four magnitudes with the total held
fixed; a survivor at the threshold gets exactly its share — and then again **structurally**,
against the engine's own source text, because a later "just 1 pt of breathing room" would
break area truthfulness by a margin no single fixture would notice.

**Omitted deliberately**

- **No drawing, and no adapter.** Nothing here imports a UI framework or knows about
  `ScanNode`; wiring the two together, and the `NSView` that consumes this draw list, is
  ticket 09's. The boxes carry what a view needs to decide *what* to draw — fill or no
  fill, label or no label, outline or not, hatch or not — and none of *how*.
- **Hover/selection stroke widths and the outline cap are constants only.** They are
  settled numbers that belong beside the merge threshold; using them is ticket 09's.
- **The classic squarify inner loop is left quadratic in row length.** It is the textbook
  algorithm and the prototype's, the cost is the 5.4 ms above, and an incremental min/max
  rewrite would risk perturbing golden geometry for a gain nobody has asked for. Recorded,
  not fixed.

**Worth a human's attention:** the aggregate's *fill* is a hatch — a pattern, not a colour.
The palette exposes its two neutral colours and §6.2's "visibly different, not any kind-hue"
is testable on those, but whether the drawn hatch actually reads as "combined" is a thing
only ticket 09 can see on screen.
