---
type: grilling
blocked_by: [04]
undermined_by: [12]
---

# Sparse files make the one measure indefensible, and the progress bar with it

## Question

The engine measures one thing: `fileSizeKey`, the logical content length
(`EntryMeta.swift:68`, `ScanSession.attribute`). For ordinary files that is the right
measure and the spec argues for it. For **sparse** files it is off by more than an order of
magnitude, and a disk visualizer that reports a file as thirty times larger than the space
it occupies is not doing its job.

Measured on the field machine (2026-08-17):

| File | Logical length | Blocks actually allocated |
| --- | --- | --- |
| `Docker.raw` | 1.00 TiB | 34.6 GiB |
| `data.img.raw` (OrbStack) | 460 GiB | 8.0 GiB |

Those two files alone contribute ~1.42 TiB of space that does not exist. Doubled by ticket
12's re-entry, they are the bulk of the 3.78 TiB the app reported for a 460 GiB disk. VM
images, database files and Time Machine local snapshots make this the normal case on a
developer's machine, not an exotic one.

**This is a decision, not a defect to be quietly patched.** The spec fixed the single
logical measure deliberately, and ticket 04's semantics — hard-link ownership, cloud
placeholders, packages measured through — are all phrased in terms of it. Changing what is
measured touches all of them. The options, at least:

- **Keep logical, disclose it.** Cheapest, and defensible for "what would this cost to
  copy elsewhere". Does nothing for the user staring at a treemap that does not match their
  disk.
- **Switch to allocated.** `fileAllocatedSizeKey` / `totalFileAllocatedSizeKey` are
  URL resource keys and would cost no extra syscall — the probe already batch-prefetches ten
  keys per entry (`FileManagerDirectoryProbe.swift:28`). Matches `df` and the Finder's "on
  disk" figure. But it changes every existing test's expected number, and it interacts with
  APFS clones: two clones of one file each report full allocated size, so a clone-heavy
  volume would over-report where it currently under-reports.
- **Measure both, present one, let the other explain.** Carry both on `ScanNode`, drive the
  treemap from one, and let the inspector show the pair when they diverge. Most honest,
  most memory (8 more bytes per node — measure it against the ceiling), and it needs a
  decision about which one drives the treemap.

**The progress bar is downstream of this and is the visible symptom.**
`approximateFraction` divides attributed logical bytes by the volume's *used* capacity
(`ScanSession.swift:435`) and clamps at 1.0. Two different units, so on this machine it
pegged at "About 100% of used space" more than twenty minutes before the scan finished and
sat there. Whatever this ticket settles about the measure, the bar must stop claiming a
precision it does not have — either divide like against like, or stop expressing progress as
a fraction of space and say something it can actually support.

Also settle what the reported throughput means. It read 2.91 GiB/s, which is the sparse
phantom bytes divided by elapsed time — a number no disk on the machine can produce, shown
to a user as if it were a measurement.

## Done when

- A written decision records which measure or measures the engine carries, what the treemap
  is driven by, what the inspector shows, and why — with the clone interaction and the
  memory cost per node addressed explicitly.
- The consequences for ticket 04's settled semantics are stated: whether hard-link
  ownership, the zero-byte deduplicated name, package measure-through and the
  size-unreadable rule change under the new measure, or are unaffected.
- The progress fraction and the throughput figure are either made dimensionally honest or
  replaced; whichever is chosen, no state of the app claims 100% while still scanning.
- `spec.md`'s wording on the single measure is amended to match the decision, or the
  decision explicitly records that the spec stands and the sparse case is accepted.
- The §9.2 fixture's sparse hidden file (built in ticket 05) gains an assertion pinning the
  chosen measure, so a later change cannot silently move it.
