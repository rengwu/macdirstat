---
type: task
blocked_by: [13]
undermined_by: []
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
