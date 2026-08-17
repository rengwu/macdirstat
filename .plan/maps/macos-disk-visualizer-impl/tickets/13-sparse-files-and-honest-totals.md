---
type: grilling
blocked_by: [04]
undermined_by: [12]
claimed_by: seaf59b7e4724
claimed_at: 2026-08-17T09:02:41Z
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

## Answer

**The engine will count blocks on disk and carry content length beside them.** The decision
is settled and `spec.md` is amended to match; the code still measures length alone, and
[ticket 16](./16-count-blocks-on-disk.md) owns changing it. This ticket is the decision and
the evidence for it, taken on the field machine (2026-08-17, M1 Pro, macOS 27.0) with
`fileAllocatedSizeKey` read alongside `fileSizeKey` on real trees.

### The measurements that decided it

| Tree | Content length | Blocks on disk | Ratio |
| --- | --- | --- | --- |
| `/Users/rengwu` (2,112,903 files) | 1,812 GiB | 277 GiB | **0.153** |
| `/System/Volumes/Data` (2,617,739 files) | 1,890 GiB | 348 GiB | 0.184 |
| `/System/Library/Frameworks` (25,456 files) | 1.51 GiB | 0.86 GiB | 0.568 |
| `Docker.raw` | 1024 GiB | 34.6 GiB | 0.034 |
| `data.img.raw` (OrbStack) | 460 GiB | 7.95 GiB | 0.017 |

Three findings the ticket's framing did not have:

1. **The error is not only sparse files, and not only in one direction.** macOS compresses
   its own binaries — `/bin/ls` is 154 KB long and occupies 41 KB — so length *over*-reports
   `/System` by 43%. A one-byte file occupies a 4 KiB block, so length *under*-reports every
   directory of small files. On the whole data volume the block slack across 2,529,061 files
   is **6.64 GiB**, or 2% of the true total: real, measurable, and negligible beside the
   1,548 GiB of phantom.
2. **Reading the second key is free.** `fileAllocatedSizeKey` rides the batched prefetch the
   probe already does. Three alternating warm passes over `/System/Library/Frameworks`:
   10 keys 5.153 s, 11 keys plus the read 5.160 s — **0.1%**, inside the noise. Directories
   return no allocated size at all (the key is absent, `st_blocks` is 0), so a folder's own
   bytes stay zero exactly as today and nothing double-counts.
3. **Counting blocks agrees with the disk to 0.3%.** Summing allocated blocks over
   `/System/Volumes/Data` **with hard links deduplicated the way the engine deduplicates
   them** gives 332.97 GiB against the volume's own used figure of 331.98 GiB — 0.98 GiB
   apart. Undeduplicated it reads 347.59 GiB, and the whole of that 14.62 GiB difference is
   66,920 second names of multiply-linked inodes. The residue has known parts pulling both
   ways: 199 directories this walk could not read and folder metadata counted as zero pull
   it down, clones and snapshots push it up.

### The decision

- **Blocks on disk are the measure.** They drive the treemap's area, the tree's Size column
  and share-of-parent, the status-bar total, and the progress figures.
- **Content length is carried beside them, rolled up through folders** — `ownBytes`/
  `subtreeBytes` gain a length twin, four `Int64` on `ScanNode` where there were two. The
  cost is 16 bytes per node: **~58 MB on the 3.63 M-node scan of `/`**, against a measured
  peak of 695 MB and the 8 GiB ceiling. Rolled up rather than per-file because the
  divergence is a *folder* story — `~/Library` is 1.05 TiB of length and a few dozen GB of
  disk, and a file-only pair can only tell that one file at a time.
- **The tree's column header stays "Size."** The inspector labels its figure *on disk* and
  adds the length line only when the two differ by more than a display step, so it reads as
  a finding rather than as clutter on every ordinary file. No second column: it would be
  identical on ~99% of rows.
- **Throughput becomes items per second.** The 2.91 GiB/s reading was phantom bytes over
  elapsed time; even corrected, a byte rate here would still not be a disk speed, because
  the scanner reads directory listings and never file contents. Items per second is the
  only rate on that card that is a measurement. Bytes per second is removed, not relabelled.
- **The progress fraction stays, honestly.** Numerator and denominator are now the same
  quantity. It is capped at 99% while a scan is running, and if the counted total ever
  passes the volume's used figure the percentage is withdrawn for the rest of the scan and
  the card falls back to counted total, item count and elapsed. No state claims 100% before
  a scan ends.
- **A finished volume scan reconciles out loud** — "333 GB counted · 332 GB used". At 0.3%
  agreement that line is evidence the picture is real; when it *disagrees* it is because
  something could not be read or was skipped, which is exactly when the user needs to know
  the map is incomplete.

### What this does to ticket 04's settled semantics

Four rules are untouched, and one of them stops being an override:

- **Hard-link ownership** — first in-scope path owns, later names zero — is unaffected, and
  is now *more* defensible: the two names genuinely share one set of blocks, which is what
  the measure now counts. Its dependence on the locale-independent name sort is unchanged.
- **A deduplicated name is still one item at zero bytes.** Unaffected.
- **Packages measured through, presented as one box.** Unaffected.
- **Symlinks receive zero.** Unaffected — and the rule now *agrees* with the measurement
  instead of overriding it. A symlink reports its target path's length (102 bytes in the
  fixture) and zero blocks.

Two change:

- **The size-unreadable rule now names which size.** The on-disk figure decides: an entry
  whose blocks cannot be read is Unreadable, is never given its length as a substitute, and
  still never enters the identity index — owning an inode of unknown size would zero out a
  later readable name (ticket 04's judgment call, intact).
- **The third-party cloud provider case is fixed by the measure, with no rule change.**
  §3.4 says a provider that surfaces no download status "safely counts the present logical
  file". On this machine that made ten `~/Library/CloudStorage/MacDroid-…` videos count at
  up to 10.22 GiB each while occupying **zero blocks** — they are not on the disk at all.
  Counting blocks gives them zero on their own. They stay visible and weightless, and the
  inspector can say "10.2 GiB in length, nothing on disk". The rule stands as written.

**Clones flip direction and are accepted.** Two clones of one file each report their full
allocated size (measured: a `clonefile` copy of a 1 MiB file reports 1 MiB allocated, as does
its source), so a clone-heavy volume now over-reports where length under-reported it. §3.4
already accepts not deduplicating clones because no cheap metadata gives exact shared-block
attribution; this makes the residual error visible in the other direction. Recorded, not
chased — and on this volume it is inside the 0.3% that separates the deduplicated total from
the disk's own figure.

### Omitted deliberately

No code changed. The human's call was to keep this ticket a decision and open
[ticket 16](./16-count-blocks-on-disk.md) for the build, which owns the engine change, the
roll-up, the inspector line, the status bar, the progress card, the four test targets, and
the §9.2 fixture assertion pinning the sparse file to its allocated size. Two implementation
positions are recorded there rather than settled here: renaming `ownBytes`/`subtreeBytes` so
every one of their 205 call sites says which measure it means, and where the reconciliation
line lives. `spec.md` §3.1, §3.2, §3.4, §3.6 and §5.5 are amended by this ticket, so the
specification and the code disagree until 16 lands — deliberately, and stated at the top of
16.

A glossary at `CONTEXT.md` now pins the two measures by name, because "size" was the word
for both and this decision only works if they can be told apart in a sentence.
