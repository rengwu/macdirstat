---
type: task
blocked_by: [06, 08, 10]
undermined_by: []
---

# The treemap's whole-tree pre-pass runs on the main thread and freezes the app

## Question

During a scan of `/` the app became unresponsive for long stretches and stayed that way.
`sample(1)` on the live process showed the main thread inside **`PreparedTree.init(root:)`**
for the entire capture, allocating `TreemapNodeRef` and `PreparedNode` objects
(`PreparedTree.swift:44-62`).

The path: every tree snapshot carries a fresh root object, so `TreemapView.currentLayout`'s
`LayoutKey` — which keys on `ObjectIdentifier(root)` (`TreemapView.swift:147`) — misses on
every snapshot. It therefore calls `TreemapLayout.layout`, which builds a `PreparedTree`
over the **entire** tree before any culling happens, and it does this from inside
`draw(_:)` (`TreemapView.swift:178`) — on the main thread. At 8.7 M nodes that is a
multi-second walk allocating one class instance per node, repeated on every snapshot, and it
gets slower as the tree grows.

This is the same cost ticket 10 measured at 2.27 s for the Large rung, already recorded on
the map as an unresolved patch. What the field run adds is that the consequence is not
merely "4 Hz is unaffordable" — it is that the **main thread blocks**, so the throttle only
changes how often the app freezes, not whether it does. A real volume is four times the
Large rung, so the freeze is seconds, not milliseconds, and the 10 s throttle from `cc212c8`
does not hide it.

Two costs are tangled here and both need addressing:

- **The pre-pass is O(total nodes) when relayout was specified as O(rendered boxes).** The
  layout culls sub-2 pt boxes via the merge rule, but only *after* `PreparedTree` has
  materialized every positive-byte node in the tree. At the Large rung ticket 10 measured
  137,056 visible boxes against two million nodes — better than a factor of ten of the work
  is thrown away immediately. Pruning by area before or during the pre-pass, rather than
  after, is the obvious lever. `TreemapNodeRef.treemapPresentedChildren` also allocates a
  fresh array of adapter structs per node visited, which the pre-pass then discards.
- **It runs where it must not.** Even a cheap layout in `draw(_:)` will eventually be too
  slow for the main thread on a large enough tree. Moving layout off the main thread, or
  computing it incrementally as snapshots arrive rather than lazily at draw time, is a
  separate decision from making it cheaper.

Deciding the throttle is part of this ticket. Ticket 01 settled 4 Hz for the tree feed and
commit `cc212c8` quietly raised it to 10 s to hide this cost; once the cost is bounded, the
settled cadence should be restored or the departure from ticket 01 recorded as a decision
with its reason.

Note that ticket 12 roughly halves the node count on any whole-volume scan, which moves the
numbers but does not change the shape of the problem.

## Done when

- The main thread is never blocked by treemap layout: driving a scan of a tree at or above
  the Large rung leaves the window responsive throughout, demonstrated rather than argued —
  a UI test that measures main-thread stall, or an equivalent instrument, with a stated
  bound.
- Relayout cost is bounded by rendered boxes rather than total nodes, measured at the
  Performance suite's rungs and written into `records/performance-record.json` alongside the
  existing figures.
- The peak footprint of a layout pass is measured and recorded separately from the scan's,
  so the transient allocation is visible rather than folded into one number.
- The tree feed cadence is either restored to ticket 01's 4 Hz or the departure is recorded
  on the map as a decision with the measurement that justifies it.
- Existing treemap geometry tests still pass unchanged: this is a cost and threading change,
  not a geometry change, and the golden rectangles must not move.
