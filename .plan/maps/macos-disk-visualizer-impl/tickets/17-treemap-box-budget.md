---
type: task
blocked_by: [06, 08, 14]
undermined_by: []
claimed_by: s8ed8907abffe
claimed_at: 2026-08-18T04:08:56Z
---

# The box count is the window's, not ours, and a maximized 4K window pays for it

## Question

Reported from the field: the app goes sluggish when its window is maximized on a 4K
display, and the report named the cause correctly — the number of boxes.

Rules 1–3 of §6 fix that number to **the viewport's area over 4 pt²**. The merge rule is a
floor on what may be drawn, never a cap on how many: double the window's area and you
double the rectangles, and both costs follow.

- **Relayout.** Ticket 10 measured 137,056 visible boxes and **1.17 s** at 2560×1600 on the
  Large rung. A maximized 4K window is roughly twice that area. The walk's cost tracks the
  children it reads — 1,335,183 of them at that rung — and that is what a resize pays, per
  size the window passes through.
- **Repaint.** Measured at 3840×2160 at 2×, fills plus hairlines — two of the six passes in
  `draw(_:)` — cost **194 ms at 45k boxes and 412 ms at 140k**. That is on the main thread.
- **And it was being paid on every pointer move.** `updateHover` set `needsDisplay = true`,
  which repaints the whole map to move a 1 pt stroke between two rectangles. This, not the
  box count on its own, is what made a large window feel slow: the cost of a full repaint
  was arriving at mouse-move frequency.

Raising the merge threshold is the obvious lever and it is a weak one. Swept on a 103k-node
fixture at 3840×2160, going from 2 pt to 16 pt cuts boxes 42,679 → 11,459 but moves layout
only 173 ms → 141 ms, because a bigger threshold folds *leaves within* a directory while
every directory still gets opened and read. It also coarsens small windows that never had a
problem, since a threshold cannot tell whether the picture is over budget.

## Done when

- The box count, and the children read to produce it, are bounded by a number we chose
  rather than by the display's resolution — with the geometry unchanged for any map that
  fits inside the bound.
- Area truthfulness is untouched: nothing is dropped, the filled boxes still tile the
  viewport, and anything folded still reports its exact combined bytes and item count.
- Moving the pointer does not repaint the map.

## Answer

**A budget on boxes, spent two ways, and a repaint that only touches what changed.**

`TreemapLayoutBudget` caps *boxes*, because boxes are what both costs scale with, and it is
spent per directory and across the walk:

- **Per directory, by area share.** A region may draw the fraction of the budget its
  rectangle takes of the viewport; children beyond that fold into the aggregate box §6.2
  already gives every directory, under the same rule and reporting the same exact numbers.
  Shares telescope — a directory's children's rectangles sum to its own — so a whole tiling
  level sums back to the budget. Applied *before* the first squarify, so a directory of
  100,000 children in a region that may draw 40 is never tiled 100,000 ways first.
- **Across the walk.** Budgeted, the walk runs largest-rectangle-first (a max-heap on
  rectangle area, ties by creation order so two runs agree box for box) and stops opening
  directories once the cap is reached. Depth-first would have handed the whole budget to
  whichever branch was walked first; largest-first degrades from the bottom, the same
  direction the merge rule already degrades in. What stays unopened stays on screen as one
  box for its whole subtree at its exact attributed area — selectable, named, and browsable
  in the tree pane.

The cap is `TreemapMetrics.standardVisibleBoxBudget` = **30,000**, one constant, chosen off
the repaint curve above. Unbudgeted — the default, and every existing caller — the queue is
the LIFO stack it always was and the geometry is unchanged box for box; the budget is the
app's setting, applied at the coordinator.

`draw(_:)` now honours its `dirtyRect`, snaps each rectangle once instead of once per pass,
fills in one batched call per kind group, and strokes all hairlines and all directory
outlines as one path each. Hover invalidates the two rectangles that changed and nothing
else. The stretched resize preview is batched the same way, because that is the frame a
live resize actually shows.

Not done: the 1.17 s relayout was allocation churn as much as box count (map, *Not yet
specified*), and the budget cuts the churn in proportion without removing it.
