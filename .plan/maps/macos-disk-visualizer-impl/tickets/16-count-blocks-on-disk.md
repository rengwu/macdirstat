---
type: task
blocked_by: [13]
undermined_by: []
claimed_by: s4c2b104a35a1
claimed_at: 2026-08-17T13:05:22Z
---

# Count blocks on disk, carry length beside them

## Question

[Ticket 13](./13-sparse-files-and-honest-totals.md) settled what the app measures and
`spec.md` is already amended to match. **The code is not.** It still measures
`fileSizeKey` alone, so the specification and the implementation disagree until this ticket
lands — deliberately, and this is the ticket that closes it. Read 13's answer first: it
carries the measurements, the reasoning, and the two rules that change.

The decision, in one paragraph: the engine counts **blocks actually on disk**
(`fileAllocatedSizeKey`) and carries **content length** (`fileSizeKey`) beside it, rolled up
through folders. Blocks drive the treemap, the tree's Size column, share-of-parent, the
totals and the progress figures. Length appears in the inspector, only when it differs. The
throughput reading becomes items per second. The progress percentage is capped at 99% while
scanning and withdrawn entirely if the counted total passes the volume's used figure. A
finished volume scan says "333 GB counted · 332 GB used".

Why it matters, from the field machine: `/Users/rengwu` reports **1,812 GiB** of length and
occupies **277 GiB** — 6.5× too big, on a 460 GB disk. Deduplicated the way this engine
deduplicates, blocks-on-disk lands within **0.3%** of what the volume itself reports.

**What has to change**

- **`EntryMeta`** gains the allocated size, and `FileManagerDirectoryProbe.entryKeys` gains
  `.fileAllocatedSizeKey`. Measured cost of the extra key on a real 25k-file tree: **0.1%**,
  inside the noise. The `lstat` fallback has `st_blocks` for it (× 512).
- **`ScanNode`** carries both measures rolled up: four `Int64` where there are two. This
  moves the stored-property guard in `IncrementalResultTests` from 11 to 13 — move it with a
  written reason, as ticket 14 did, and re-measure bytes per node against the Large rung
  (the budget is +16 bytes/node, ~58 MB at 3.63 M nodes, against a 695 MB measured peak).
- **`ScanSession.attribute`** attributes blocks where it attributes length today, and rolls
  both up the ancestor chain on the same walk. `attributedNodeCount` keys on the *visible*
  measure — blocks — since that is what has a rectangle to lose.
- **The two rule changes** from 13: an entry whose *blocks* cannot be read is Unreadable and
  is never given its length instead, and stays out of the identity index. The third-party
  cloud rule is **not** edited — the measure fixes that case on its own.
- **`ProgressSnapshot`**: `bytesPerSecond` → an items-per-second figure; `approximateFraction`
  divides blocks counted by volume-used, capped at 0.99 while running, and returns `nil` for
  the rest of the scan once the counted total exceeds volume-used (a scan that is *finished*
  may report 1.0). `DisplayFormatting.throughput` and the workspace's telemetry column follow.
- **The inspector** labels its size *on disk* and adds the length line only when the two
  differ by more than a display step. The tree's column header stays "Size".
- **The reconciliation line** for a finished volume scan. Where it lives is open — the status
  bar already carries the scanned total, and the inspector already describes the root.
- **Every expected number in the suites moves.** `RealFixtureManifest`'s totals are
  currently sums of logical lengths, including a 3 GiB sparse file and a 1 GiB sparse file
  inside the package that occupy **nothing**. The manifest has to state both measures, and
  the §9.2 fixture's sparse hidden file gains the assertion 13 asks for: its attributed
  bytes are its *allocated* size, pinned, so a later change cannot silently move it. Note
  that `ProductionProbeTests` already reads `fileAllocatedSizeKey` for its comparison — the
  key is not new to the test target, only to the engine.
- **`spec.md` needs no further edit.** 13 amended §3.1, §3.2, §3.4, §3.6 and §5.5. If the
  build contradicts any of that wording, flag it rather than quietly re-amending.

**Two positions left open on purpose**

1. **Naming.** `ownBytes`/`subtreeBytes` appear at **205 sites across 35 files** and would
   keep their names while changing meaning — the reading hazard this ticket most likely
   leaves behind. Renaming them so every call site says which measure it means is the
   disciplined move and a large mechanical diff on top of a semantic one. Decide, and say
   why in the answer. `CONTEXT.md` pins the two terms.
2. **Where the reconciliation line lives**, and whether it appears at all when the two
   figures agree.

## Done when

- The engine attributes blocks on disk, carries length rolled up beside them, and both are
  reachable from a `ScanNode` without walking its subtree.
- The two changed rules hold under test: an entry with unreadable blocks is Unreadable with
  no length substituted and no identity-index entry; a file with length and zero blocks (the
  sparse fixture, a third-party cloud placeholder) counts as zero and stays visible.
- The §9.2 fixture pins the sparse hidden file's attributed bytes to its allocated size, and
  `RealFixtureManifest` states both measures.
- Throughput reads items per second; no bytes-per-second figure survives anywhere in the UI.
- No state of the app shows 100% while a scan is running, proven by a test over the
  progress stream — including the case where counted bytes exceed the volume's used figure.
- A finished volume scan shows counted total against volume-used.
- The inspector shows the length line when and only when it differs from the on-disk figure.
- `Scripts/verify-scaffold.sh` exits 0 — CI, Thread Sanitizer, universal Release,
  Performance and Compatibility plans — and the per-node memory bar is re-measured at the
  Large rung with the two extra fields.
- **A real volume is scanned before this is called done** (the map's standing rule). The
  scan of `/` that reported 1.78 TB should land near a third of that, and within a few
  percent of what the volume itself reports.

## Answer

**The code now measures what the specification says it measures.** `EntryMeta` carries
`diskSize` (`fileAllocatedSizeKey`) beside `contentLength` (`fileSizeKey`); `ScanNode`
carries `ownDiskBytes`/`subtreeDiskBytes` and `ownContentBytes`/`subtreeContentBytes`,
rolled up on one ancestor walk, both reachable without walking a subtree. Blocks drive the
treemap, the tree, every total and the progress figures; length is shown only where it
differs. The `lstat` fallback reaches the same quantity through `st_blocks × 512`.
`attributedNodeCount` keys on blocks, because blocks are what has a rectangle to lose. The
two rule changes hold under test: an entry whose blocks cannot be read is Unreadable, is
never given its length instead, and never enters the identity index; a file with length and
no blocks — the sparse fixture, the third-party cloud placeholder — counts zero and stays
visible with its length beside it.

**Proved on `/`, twice, before this was called done.** 344.16 GiB on disk against
**1,817.97 GiB of content length** — the old measure was 5.3× the disk. `/Users` alone is
263.10 GiB occupying, 1,724.34 GiB in length. Two runs minutes apart agree to 0.02%;
2.92 M files, 579 s, 945 MB peak. Full record:
[`records/blocks-on-disk.md`](../records/blocks-on-disk.md).

### The two positions the ticket left open

**1. `ownBytes`/`subtreeBytes` are renamed.** Every one of the 205 call sites now says
which measure it means: `ownDiskBytes`/`subtreeDiskBytes` for blocks,
`ownContentBytes`/`subtreeContentBytes` for length, `EntryMeta.diskSize`/`.contentLength`,
`ProgressSnapshot.attributedDiskBytes`. The mechanical diff is large and it is the cheap
half: a name that keeps its spelling while changing its meaning is a trap that costs
somebody an afternoon a year from now, and the compiler visits every site exactly once
today. `CONTEXT.md` already pinned the two words; the code now uses them.

**2. The reconciliation line lives in the status bar, and it is shown whenever there is a
used figure to show it against** — including when the two agree. It belongs there because
it is a statement about the *scan*, not about whatever the user has selected, and the
status bar already carries the scanned total. Always, not only on disagreement, because
agreement is the evidence that the picture is real and evidence only reads as evidence if
it is there every time; a line that appears only when something is wrong is a warning, and
this is not one. `StatusBarViewController.text(…)` is now a static function over its
inputs, so what it says is a unit test rather than a screenshot.

### What the field run found that the ticket did not expect

**The reconciliation on a scan of `/` reads about −10%, and that is APFS, not an error.**
`volumeAvailableCapacityKey` is a property of the *container*, so the used figure spans
every volume in it — Preboot (23.1 GB), Recovery (3.0 GB) and VM (3.2 GB) are inside the
denominator while §3.3 correctly keeps them outside the numerator, and the scan records 9
`crossedVolumeBoundary` exclusions saying so. Against the two volumes a scan of `/` can
actually reach, the counted total is **−3.2%**; the rest is three `com.apple.os.update-*`
local snapshots holding blocks no walk can reach and 261 root-owned directories a
non-root process cannot read. Ticket 13's 0.3% was measured on `/System/Volumes/Data`,
where the root really is one volume. **The line is still right to ship** — it is the only
place the picture is checked against something outside itself — but "counted below used"
is the ordinary reading for a `/` scan and not a signal that anything went wrong. Flagged
on the map rather than re-decided.

**Two test fixtures had to grow by orders of magnitude, and the reason is the change
itself.** Every real file occupies at least one block, so a "long tail of tiny files"
beside a 4 MB file no longer produces an aggregate box at all — sixty 16-byte files are
sixty whole blocks. The merge-bucket tests now stage a half-gigabyte dominant file through
`F_PREALLOCATE`, which reserves blocks without writing them (the mirror of the sparse
helper, and instant). Likewise `SecurityScopeBalanceTests` cancelled after the second
listing and asserted a non-zero total: the first entry this fixture attributes is
`.hidden.bin`, three gigabytes of length occupying **nothing**, so that scan now has a
legitimately zero total and the cancellation point moved to the fourth listing.

**A materialized performance rung now occupies nothing at all.** `WorkloadFixtureBuilder`
stages with `ftruncate`, so the real-filesystem soak is 260,000 entries of pure hole. That
turned out to be the best assertion available: the engine reports **0 blocks** and the
manifest's byte total in the length carried beside it — the sparse case at scale, on a
real filesystem, through the production probe.

### Verification

- `swift test` on both packages: **176 ScanCore** (10 new in `TwoMeasureTests`, plus the
  rewritten progress-fraction pair) and TreemapLayout, green.
- CI test plan green; the **full performance ladder** re-run and its record rewritten.
  Large rung: 2,000,000 entries, peak **0.401 GiB**, **86.8 bytes per entry** against the
  8 GiB ceiling — no regression visible, though the +16 bytes/node this change costs is
  smaller than the run-to-run spread of a figure the record itself calls a lower bound.
- The stored-property guard moved 11 → 13 with its reason written at the assertion.
- `Scripts/verify-scaffold.sh` **exits 0**: guards, both packages, both architectures at
  the 11.0 floor, CI, Thread Sanitizer, universal Release, Performance and Compatibility.
  It failed once first, and worth saying why so the next person does not go looking in the
  code: the UI-test runner returned *"Timed out while enabling automation mode"* on that
  attempt, an automation-permission fault on the host with every unit suite inside the same
  run green. It passed unchanged on the retry.

### Omitted, and one thing to flag

`spec.md` is **not** edited — §§3.1, 3.2, 3.4, 3.6 and 5.5 already describe this build, and
nothing here contradicts them. One thing does need a patch, and it is not a re-decision:
**§5.2 still names the node's fields `ownBytes`/`subtreeBytes`**, which no longer exist.
The map carries it.

No second Size column, no per-file length row on ordinary files, and no change to §3.4's
cloud rule — the measure fixes that case on its own, exactly as ticket 13 said it would.
