---
type: task
blocked_by: [06, 08, 10]
undermined_by: []
claimed_by: s540d52aaae45
claimed_at: 2026-08-17T06:59:05Z
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

## Answer

The freeze is gone, and it was two defects wearing one symptom. Both are fixed and
both are measured — including once against a real tree through the shipped app's own
accessibility interface, which is the only measurement in this repository taken from
outside the process.

**1 — The pre-pass is gone; the walk reads what it draws.** `PreparedTree` no longer
builds a parallel tree of `PreparedNode` class instances over every positive-byte node
before placing anything. It is now `PreparedTree.children(of:)`: one array of three-field
value structs for **one directory**, built the moment that directory is about to be
subdivided and never otherwise. A directory that folded into an aggregate is never
opened, and neither is anything beneath it. The merge fixpoint tracks survivors by index
into that array instead of by `ObjectIdentifier` of an allocated node, so the per-node
class allocation the `sample(1)` capture caught is gone entirely.

**The price is one number the layout can no longer compute for itself.** An aggregate
reports *"N items below individual size"*, counted over everything in the subtrees it
folded — and a layout that never opens those subtrees cannot count them. So
`TreemapInputNode` gained a fifth requirement, `treemapPresentedItemCount`, with a
walking default for fixtures and an O(1) answer in production: `ScanNode` now rolls up
`attributedNodeCount` on the same ancestor walk that rolls up `subtreeBytes`, by carrying
a running "newly attributed" delta up the chain. That is an eleventh stored property on
a class multiplied by two million at Large, and `IncrementalResultTests`' cap moved from
ten to eleven to say so; eight bytes a node is what bought the pruning.

**2 — The layout does not run on the main thread.** `TreemapLayoutCoordinator` (in the
package, so both test targets can drive it) owns *when*: one layout at a time, newest
request wins, computed on a detached task and handed back on the main actor. `TreemapView`
asks and draws whatever has arrived. Two consequences the old synchronous view never had:
a result may describe an older tree at the current viewport, which is honest and is drawn
as-is; or it may describe another **viewport**, in which case hit testing, hover and
accessibility all refuse it — and `draw(_:)` paints it stretched, unlabelled and
unsnapped, because during a divider drag the alternative is a grey window on every frame.
`TreemapNodeRef` became `Sendable` for this: the expansion set is now a frozen
`PackageExpansionSet` value rather than the mutable main-actor class.

**3 — The cadence is back to ticket 01's 4 Hz.** `cc212c8`'s 10 s was hiding this
freeze, not preventing it. With the cost bounded and off the main thread it has nothing
left to hide, so `ScanPresentationModel.treeInterval` is 0.25 s again. A snapshot the
layout cannot keep up with now costs a skipped picture, which is what coalescing is for.

**Measured** (M1 Pro / 16 GB — *not* §8.1's reference machine; Release except where noted):

| | before | after |
| --- | --- | --- |
| Large-rung relayout at 2,560×1,600 | 2.27 s | **1.17 s** |
| worst main-thread stall, Large | ≈ the layout | **0.019 s** (control, inline: **1.15 s**) |
| entries read per relayout, Large | 2,000,000 | **1,335,183** |
| the same tree at 640×400 | 2,000,000 | **221,869** |
| layout pass peak footprint, Large | folded into the scan's | **0.199 GiB, +58 MiB** |

The last two rows are the cost claim: the tree is identical at both viewports, so the
work is following the picture. The Large rung is a broad, shallow shape where two thirds
of all entries are direct children of a drawn directory — on a real volume the fraction
falls further, because depth is where the pruning bites. What is read is read *flat*:
1,198,128 folded roots stand for 1,862,944 entries.

**The field check.** `RealVolumeResponsivenessUITests` drives the shipped app through
`XCUIApplication` while it scans a directory named by `MACDIRSTAT_UI_SCAN_ROOT` — an
accessibility query is answered by the app's **main thread**, so the time it takes is a
reading of how long that thread was unavailable. Against `/System/Library` (447,367
entries, Debug): worst response for the window's own frame **0.36 s**, and a `sample(1)`
of the live process during the scan puts the main thread **91% idle in
`_BlockUntilNextEventMatchingListInMode`**, with every `TreemapLayout` frame in the
capture underneath `TreemapLayoutCoordinator.startPending()` and none on the main thread.
That is the ticket's opening observation, re-run and inverted.

**Two judgment calls.**

1. **`ScanCore` grew a field.** The alternative was memoizing subtree counts in the app
   by node identity — a dictionary of millions of entries, and still an O(total nodes)
   walk the first time. Rolling the count up where the bytes are rolled up costs one
   `Int` per node and nothing per layout. It is engine work in a view ticket, and it is
   recorded here rather than done quietly.
2. **The stretched preview.** §6.4 forbids caching geometry to avoid recomputing it; the
   recompute is always already running when a preview is drawn, and the preview is never
   hit-tested, never given to accessibility and never snapped to the pixel grid. Without
   it, going asynchronous would have traded a scan-time freeze for a resize-time flicker.

**Deliberately not done.** The remaining 1.17 s at Large is allocation churn, not
algorithm: two arrays per directory opened (the adapter's children, then the prepared
ones) and four more per merge round. Reusing buffers across directories would cut it and
would perturb nothing, but §8.2 commits no wall-clock bar and the main thread no longer
waits for it — recorded, like ticket 06's quadratic squarify inner loop, rather than
fixed. Also unfixed, and newly visible: a full accessibility hierarchy copy of a
whole-volume map takes **7–8 s**, because the treemap publishes one element per rendered
rectangle. That is main-thread work a VoiceOver client asks for, it is a real number
about a real user, and it is a different subject from this ticket's — flagged on the map.

Verification: `Scripts/verify-scaffold.sh` — twelve steps, exit 0. 164 `ScanCore` tests,
88 `TreemapLayout` tests, 58 app tests, 60 performance tests (48 → 60, all rungs green),
and the record at
[`records/performance-record.json`](../records/performance-record.json) carries the new
`large-treemap-layout-pass` and `large-treemap-main-thread` rows.
