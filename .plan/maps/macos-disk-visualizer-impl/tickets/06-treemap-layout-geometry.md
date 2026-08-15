---
type: task
blocked_by: [01, 02]
undermined_by: []
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
