---
type: task
blocked_by: [05, 08]
undermined_by: []
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
