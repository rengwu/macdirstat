---
type: task
blocked_by: [05, 08]
undermined_by: []
claimed_by: s98c03115bc69
claimed_at: 2026-08-16T17:51:47Z
---

# Performance & scale suite

## Question

Prove the algorithmic and memory bars at scale: the generated Smoke/Representative/Large/
Stress workloads, the operation-count and memory-ceiling checks, and the bounded treemap
relayout — on the reference machine, in Release, without sanitizers. This is the opt-in
pre-release-candidate gate. Fixed by spec §8 and §9.1/§9.3 (performance/memory proof).

Implement `MacDirStatPerformanceTests` and its fixtures:

- The **scale generator** with exact reproducible rungs (spec §9.2): Smoke (4,096 entries /
  768 MiB), Representative (400,000 / 200 GiB), Large (2,000,000 / 1 TiB), and the four
  Stress shapes (flat 100,000-entry directory; depth 64; one 40 GiB file + 10,000 tiny
  files; 10,000 links; 2,500 injected failures). Representative and Large run first through
  a **lazy scripted probe** that computes listings from seed/shape rather than retaining a
  second metadata copy; an opt-in `FixtureBuilder` may materialize the same manifest under
  an explicitly supplied empty, sentinel-marked directory using sparse files (real-I/O
  soak, not part of the normal loop).
- **Operation-count checks** via a counting probe: one shallow list per traversed
  directory, no descent across a device boundary, no file-content reads, no duplicate
  metadata fetch after a prefetched value; operation counts scale with entries + ancestor
  depth, not total bytes or a second pass.
- **Incremental-result barriers** at 25/50/75% proving useful progress and tree results
  before completion; snapshot-identity checks proving frozen subtrees are shared, not
  deep-copied; structural checks that nodes keep one name + parent link (no stored absolute
  URL) and the hard-link index stays limited to multiply-linked identities.
- **Memory gate**: sample peak resident size; Representative, Large, and each Stress shape
  finish without allocation failure or crash and **below 8 GiB peak RSS** on the reference
  machine. During Representative and Large, injected UI-model selection and Cancel keep
  working ("still usable"), not converted into a timing threshold.
- **Treemap at scale**: layout/draw on the resulting snapshots complete with a visible-box
  count bounded by the viewport/merge policy and no crash.

The suite runs in the Release-configuration performance scheme, without sanitizers; the CI
scheme excludes it. Wall-clock/relayout time is recorded as a diagnostic only, never a
pass/fail threshold.

## Done when

- All four rungs run on the M1/8 GB/NVMe reference machine in Release: Representative,
  Large, and each Stress shape finish without OOM/crash and below 8 GiB peak RSS, with the
  record capturing OS/hardware, generator version, seed, entry count, logical bytes,
  operation counts, peak RSS, terminal state, and diagnostic elapsed time.
- The counting probe confirms one shallow list per directory, no boundary crossing, no
  content reads, no duplicate metadata fetch, and operation counts scaling with
  entries + depth across geometrically larger inputs.
- Barriers at 25/50/75% show incremental progress/tree results; snapshot identity confirms
  shared frozen subtrees; structural checks confirm name-only nodes and a bounded hard-link
  index; UI-model selection and Cancel keep working during Representative and Large.
- Treemap layout/draw at scale complete with a bounded visible-box count and no crash.
- No wall-clock/throughput threshold is asserted anywhere.

## Answer

The opt-in pre-release-candidate gate exists and is green at every rung — and it found the
bug it was built to find. `MacDirStatPerformanceTests` is **48 tests over fifteen new
files**: a lazy scale generator with the exact §9.2 rungs, a counting probe, a peak-memory
sampler, a treemap-at-scale harness, an opt-in real-filesystem builder, and a record that
now lives at
[`records/performance-record.json`](../records/performance-record.json).
`Scripts/verify-scaffold.sh` exits 0 with every step PASS.

**The finding: a real scan cost 13,615 bytes of resident footprint per entry; it now costs
158.** `FileManagerDirectoryProbe.list` had no autorelease pool. `contentsOfDirectory`
returns one `URL` per entry carrying ten prefetched resource values, all Foundation
objects on the autorelease path — and the traversal is a single long synchronous run
inside a detached task with no suspension point in it, so it is *one job* on the
cooperative pool and the thread's pool is never drained until the scan ends. The process
therefore held every listing it had ever made. Measured on a materialized 65,536-entry
tree: **0.871 GiB peak before, 0.049 GiB after**. Extrapolated to the 2.4-million-file
volume a user actually scanned, 13,615 B/entry is **32.7 GB** — which brackets the 28 GB
that was observed in the field and attributed to nothing in particular. The fix is a
five-line `autoreleasepool` in the probe. Without it this ticket's own bar is
unreachable: a materialized Large rung would have wanted ~26 GiB against a ceiling of 8.

**What the ladder measures.** Smoke 4,096 / 768 MiB, Representative 400,000 / 200 GiB,
Large 2,000,000 / 1 TiB, and the four stress shapes, all as *arithmetic* rather than as
the sum of a random draw: a short ladder of exact `(count, size)` rungs plus a tail
divided by `divmod`, so a rung hits its byte target to the byte and stores nothing per
file. Listings are computed from the last path component and the seed, which is what makes
two million entries measurable inside the process doing the measuring — sixty-four Large
workloads held at once cost under 4 MiB. On this machine, in Release, without sanitizers:

| rung | entries | logical | operations | peak footprint | terminal |
| --- | --- | --- | --- | --- | --- |
| Smoke | 4,096 | 768 MiB | 258 | 0.062 GiB | completed / exact |
| Representative | 400,000 | 200 GiB | 40,002 | 0.259 GiB | completed / exact |
| Large | 2,000,000 | 1 TiB | 200,002 | 0.322 GiB | completed / exact |
| flat 100k | 100,001 | 8 GiB | 3 | 0.074 GiB | completed / exact |
| depth 64 | 585 | 2 GiB | 67 | 0.062 GiB | completed / exact |
| 40 GiB + 10k tiny | 10,002 | 40 GiB | 3 | 0.076 GiB | completed / exact |
| 10,000 links | 31,001 | 11 GiB | 3 | 0.076 GiB | completed / exact |
| 2,500 failures | 22,501 | 1.2 GiB | 1,253 | 0.076 GiB | completed / incomplete(2,500) |
| 65,536 materialized | 65,536 | 12 GiB | — | 0.079 GiB | completed / exact |

Large holds two million nodes for **88 bytes of footprint each**, which settles a question
the field report left open: the tree is not what was costing 28 GB, and snapshot copying
never was either.

**Operation counts, exactly rather than asymptotically.** One list per directory —
`listCount` equals the tree's own directory count in both directions, so neither a missed
directory nor a repeated one can hide. Metadata is fetched once, for the root, and the
counting probe *throws* on any other metadata read, so a duplicate fetch fails the scan
rather than inflating a number. Total operations are `directories + 2` at 4,096, 16,384
and 65,536 entries. A control rung with the same shape and **a hundred times the bytes**
produces a byte-identical operation count. Four decoys on another volume are listed zero
times, counted as exclusions rather than errors, and leave the tree Exact. "No file-content
reads" stays where it belongs — the seam has no third verb, held there by `ScanCoreTests`
over its own source; what is checked here is that nothing *but* those three verbs ran.

**Barriers, sharing, structure.** The traversal moves a sticky phase marker forward at
25/50/75% and again at the last listing, so a quarter's snapshots cannot be credited with
the finished tree's numbers; every quarter delivers tree and progress with strictly growing
bytes and files. Snapshot identity is asserted by `===` over a whole subtree — and getting
that right needed a correction worth recording: **`isFrozen` cannot tell a shared subtree
from a copied one**, because the snapshot of an *open* node is a copy that is itself marked
frozen. What separates them is position, since the walk descends the instant it appends, so
only the root's last child can be open. `Mirror` proves no stored `URL` on a node and no
more than ten stored properties. The identity index's bound is proven by the case that can
actually be *seen*: 500 pairs of files sharing an identity while reporting `linkCount == 1`
all own their bytes, so none of them was indexed.

**Treemap at scale.** Large lays out at 2,560×1,600 into **137,056 visible boxes against a
merge-policy bound of 1,024,000**, folding 1,862,944 items into 126,144 aggregates in at
most three rounds, and the draw list paints end to end into a bitmap without a crash. The
flat-100k shape is the one that shows the bound is the *viewport's* and not the tree's: at
2,560×1,600 nothing merges and 100,000 boxes is the honest picture; at 640×400 the same
tree folds to one aggregate. One correction to the ticket-06 phrasing: "zero surviving
sub-2 pt slivers" is true of *children* only — an aggregate is where the slivers went and a
directory whose leftovers add up to a thin strip has to draw that strip, so the two are
counted apart.

**Four judgment calls.**

1. **`@testable import MacDirStat` is impossible here, so the treemap adapter is duplicated
   (twenty lines).** The app module is built without `-enable-testing` in Release, and
   turning it on would perturb the very Release binary the suite exists to measure. It
   costs nothing in coverage — the claim under test is `TreemapLayout.layout`'s, which is
   production code in its own package. The same constraint is why "injected UI-model
   selection" is proven against `ScanNode` identity and a real hit test rather than against
   the app's `SelectionModel`, which `MacDirStatTests` already covers in both directions.
2. **The suite has two test-plan configurations, and the local gate runs only the light
   one.** §9.1 calls performance opt-in, but `verify-scaffold.sh` also runs the plan on
   every local check because ticket 02 shipped a plan Xcode rejected and nothing noticed.
   Those pull apart, so: `Release, no sanitizer` runs Smoke and the cheap shapes in seven
   seconds, `Release, all rungs` climbs the whole ladder in forty and writes the record.
   `xcodebuild` runs *every* configuration when told none, so the gate now names the light
   one explicitly.
3. **There is one per-entry memory assertion, and it is an addition to the spec.** §8.4
   fixes the 8 GiB ceiling and calls the per-rung expectation "diagnostic, not a
   threshold". But the ceiling alone could not have caught what was actually wrong: no rung
   small enough to run unattended crosses 8 GiB at 13,615 B/entry, and the machine that did
   cross it was a user's. So a real-filesystem scan of 16,384 entries now asserts under
   **2 KiB per entry** — thirteen times the measured 158 and six times below the broken
   13,615, loose enough to catch the mechanism rather than become a tuning knob. Flagged
   here rather than added quietly.
4. **`footprintDeltaBytes` is recorded as a lower bound, not a cost.** Every rung shares one
   host process and macOS's allocator does not hand freed pages straight back, so a rung
   that fits inside an arena an earlier rung already grew reads as costing nothing.
   `malloc_zone_pressure_relief` helps and does not fix it. The ceiling is asserted on the
   absolute peak, which does not care; the record says this in `measurementNotes` rather
   than letting a reader believe Representative was free.

**Two things a human should look at.**

- **This is not the reference machine.** §8.1 fixes it as M1 / 8 GB / NVMe; this ran on an
  M1 Pro with 16 GB. The record says so in `isReferenceMachine` and explains why the
  ceiling is still asserted unchanged — it bounds the process, not the host — but a machine
  with more memory swaps later, so a pass here is not a pass there. Every rung came in at
  under 0.33 GiB against 8 GiB, so the margin is 24×, but the run should be repeated on the
  reference machine before an RC.
- **The 10 s tree throttle now has a number behind it, and it is not the leak.** A full
  Large relayout takes **2.27 s** at 2,560×1,600. The memory fix does not change that, so
  ticket 01's settled "4 Hz tree" cannot be honoured at two million nodes for reasons that
  have nothing to do with the 28 GB — it is `PreparedTree` rebuilding every positive-byte
  node on every layout. The throttle conflict is real and stays open; it is a decision, not
  a measurement, and it is recorded as a patch rather than settled here.

**Omitted deliberately.** No wall-clock or throughput threshold is asserted anywhere;
elapsed time appears only in the record and in `[performance]` log lines, both labelled
diagnostic. The materialized rungs carry no operation counts, because the production probe
has no counters and instrumenting it would put test machinery in the shipping path — the
operation-count claims are proven on the scripted rungs, where the probe does count. The
compatibility runtime matrix is ticket 11's. The `PreparedTree` relayout cost above is
named but not fixed: it is ticket 06/08 code and a decision the human owns.
