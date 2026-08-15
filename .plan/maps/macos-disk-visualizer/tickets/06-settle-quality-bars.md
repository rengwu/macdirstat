---
type: grilling
blocked_by: [03, 04, 05]
undermined_by: []
claimed_by: sfa87828811ed
claimed_at: 2026-08-14T17:34:13Z
---

# Settle performance, resilience, and accessibility bars

## Question

What measurable quality bars must the locally built MVP meet? Decide representative scan scale and hardware assumptions, UI responsiveness and cancellation latency, memory expectations, behavior under permission and filesystem errors, VoiceOver and keyboard coverage, number and byte formatting, and the minimum acceptable behavior when the treemap cannot display every entry individually.

## Done when

The ticket records measurable acceptance thresholds and representative fixtures for performance, resilience, and accessibility, including explicit tradeoffs where strict guarantees would exceed the MVP destination.

## Answer

This ticket sets the MVP's measurable quality bars, quoted against a defined
reference machine and a defined workload ladder. Where a strict guarantee would
exceed the read-only, locally buildable MVP destination — or depend on hardware
we do not control — the bar is deliberately stated as best-effort or deferred,
and that tradeoff is named. Settled with a human across a grilling session.

### Reference hardware (all numbers are quoted against these)

- **Performance-reference machine:** Apple Silicon M1, 8 GB unified memory, NVMe
  SSD. Every performance and memory expectation below is stated on this machine.
- **Compatibility floor:** a 2015-era dual-core Intel Mac, 8 GB RAM, SATA SSD (a
  representative oldest-supported macOS 11 Big Sur host). On the floor we
  guarantee **correctness, no-crash, and a non-frozen UI only** — never a speed
  number. Scan speed there is disk-I/O-bound and outside our control.

### Representative scan-scale ladder (fixtures; construction deferred to #07)

Workload is measured in **entries = files + directories**. Four rungs, each
binding the bars differently:

- **Smoke** — ~1–5k entries, < 1 GiB. Inner test-loop scale.
- **Representative** — ~300–500k entries, ~150–250 GiB. A real populated home
  folder / system volume. *This is the rung the expectations below anchor to.*
- **Large** — ~2M entries, ~1 TiB. A big, full external drive. Bars here are "no
  catastrophic degradation, still usable," not hard numbers.
- **Stress** — pathological *shapes*, not size: one flat directory of ~100k
  entries; a ≥ 20-level deep chain; one ~40 GiB file beside thousands of tiny
  ones; thousands of hard links; thousands of unreadable/vanishing entries. Bars
  here are correctness + no-crash + memory-bounded only.

These are scan-performance fixtures, distinct from Ticket #05's treemap-render
datasets. Reproducible, read-only construction is Ticket #07's job.

### Performance — algorithmic, not wall-clock

No second-count guarantees. Disk throughput is not ours to promise. The
commitment is **algorithmic efficiency**:

- Single-pass, streaming, iterative depth-first traversal (per #03) with
  prefetched URL resource keys and no redundant metadata reads.
- Results appear **incrementally** as discovered — never batched until the end —
  so the UI is useful before the scan completes.
- Throughput is explicitly **best-effort, disk-bound**. The MVP does not accept
  or advertise a completion-time SLA. (Tradeoff: we optimize what we own — the
  algorithm and I/O batching — and refuse to be measured on disk speed we do
  not own.)

### UI responsiveness & cancellation — noted, not bars

These are **not** MVP acceptance bars; they are recorded for later tuning. The
load-bearing architectural invariants from #02/#03 still stand and are not
reopened:

- The scan runs off-main on a cancellable `Task`, so scanning cannot freeze the
  UI.
- Progress/tree updates are coalesced/throttled (~15 Hz scalars, ~4 Hz tree;
  #03) rather than per-file.
- Cancellation is cooperative (`Task.isCancelled` checked per-directory and
  per-256-entry batch; #03) and retains all partial results.

No p99 / millisecond latency thresholds are committed at MVP. (Tradeoff:
responsiveness polish is secondary to correct disk scanning and will be ironed
out in later sessions.)

### Memory

- **Hard ceiling:** total resident memory stays **within the 8 GB reference
  machine and never OOMs**, at every rung including Large and Stress.
- **How the ceiling is held (from #03, not reopened):** name-only `ScanNode`s;
  URLs rebuilt on demand rather than stored; hard-link index populated only for
  `linkCount > 1`; no file *contents* ever read; UI snapshots share frozen
  subtrees by reference (O(1) per update, no deep copies).
- Representative is expected to sit far below the ceiling (order hundreds of MB);
  Large is expected to remain comfortably within 8 GB. The single acceptance bar
  is "fits in 8 GB, never OOM."

### Resilience

- **Zero crashes** across a defined resilience fixture matrix: permission-denied
  directory, unreadable file, mid-scan deletion (vanishing entry), cloud
  placeholder (omitted + counted), hard-link duplicate, and one huge flat
  directory.
- The scan still reaches **`.completed`** on that matrix (recoverable errors
  never abort it; #01/#03), with every recoverable error represented (entry →
  **Unreadable**, ancestors → **Incomplete**, size never guessed) and **exact**
  total error and exclusion counts.
- **Bounded error detail:** retain up to **1,000** detailed error records (name +
  reason); beyond that, keep only the exact running total, so a pathological
  error storm cannot blow the memory ceiling.
- Pre-flight root-eligibility failure ⇒ `.failed`; every mid-scan filesystem
  problem ⇒ recorded and traversal continues (#03, restated as the resilience
  contract).
- The resilience fixture matrix is named here; reproducible construction is
  Ticket #07.

### Number & byte formatting

- Display sizes: **binary IEC** units (KiB/MiB/GiB/TiB; #01) at **3 significant
  figures** (`1.23 GiB`, `12.3 GiB`, `123 GiB`); the unit steps up at ≥ 1024 of
  the current unit.
- **`ByteCountFormatter` is disallowed for display:** even with `.binary` count
  style it labels output "KB/MB", not the IEC "KiB/MiB" #01 requires. Display
  uses a **custom IEC formatter**; a locale-aware `NumberFormatter` handles digit
  grouping and decimal separators for the exact byte count and for entry counts
  (e.g. `1,234,567 files`).
- The inspector shows the **exact grouped byte count** (#01) alongside the IEC
  value.
- Share-of-parent **percentages** to 1 decimal; values below 0.05% render
  `< 0.1%`, never `0.0%`.
- **Zero** renders `0 bytes`; the singular is handled (`1 byte`).

### Treemap when it cannot show every entry — merge, never disappear

This **supersedes Ticket #05's render-only culling policy** (see flag below). The
rule is: the treemap is **always area-truthful and nothing with real bytes
disappears.**

- **No minimum-area bound / no culling-to-background.** Within each directory,
  all children whose individual squarified rectangle would fall below the
  **2×2 pt** visibility threshold are **merged into exactly one aggregate box**
  whose area equals the exact sum of their attributed bytes. (The 2×2 pt figure
  becomes the *merge* trigger, not a *drop* trigger.)
- The merge trigger applies to any child — leaf **or** an entire too-small
  subtree — so a directory that is collectively tiny folds into its parent's
  single aggregate box.
- **Distinct fill:** the aggregate box uses a neutral, visibly different fill
  (e.g. a subtle hatch), not any single kind-hue, because it is a mixed-kind
  bucket — it must read as "combined," not as one file.
- **Selectable and honest:** the aggregate box is hit-testable; its
  tooltip/inspector report "N items below individual size, combined X"; every
  individual item remains fully listed and selectable in the **tree**, which
  always enumerates everything.
- **Result — area truthfulness is total:** visible rendered area (individual
  boxes + aggregate boxes) = **100%** of attributed bytes, with no empty
  directory-background gaps. Area stays strictly proportional to logical bytes
  (#01); no log scaling, no synthetic "other" box beyond this exactly sized
  merge bucket.
- **Zero-attributed-byte items** (empty files, symlinks, hard-link non-owners,
  unreadable entries with unknowable size) still get **no rectangle** — they have
  no area to draw — but they never vanish from the product: they remain in the
  tree and inspector (#01/#05). "Don't let anything disappear" is honored at the
  app level; the treemap represents everything that has area, and the tree
  represents everything.
- **Render/relayout stays bounded** by the count of *visible* boxes (individual +
  aggregate), not by total node count, so all four rungs — including Stress —
  remain drawable. The treemap does **not** promise per-entry visibility;
  per-entry access is via the synchronized tree. That is the stated tradeoff.

### Accessibility — deferred (explicit boundary)

Per human decision in this session, **#06 sets no measurable VoiceOver or
keyboard-coverage bars.** They are deferred to a later session. The a11y
*mechanics* already fixed in #04/#05 (treemap rects as accessibility children
labelled name/size/kind; `NSAccessibilityAnnouncementNotification` on selection;
tree keyboard nav; color never the only channel) still stand — but no coverage
thresholds are committed here.

**Consequence flagged for humans:** the map's Done-when for #06 lists
accessibility, and Tickets #07 (verification) and #08 (spec) both inherit from
this ticket — they will pick up "accessibility bars unspecified" unless a later
session fills the gap. This is a known, deliberate hole, not an oversight.

### Flags for a human

1. **Ticket #05 conflict (treemap culling).** The merge policy above replaces
   #05's settled "render-only culling below 2×2 pt → directory background shows
   through → hover hits the directory." I have added `06` to #05's
   `undermined_by` to mark this for human judgment (this does not reopen #05).
   Ticket #08, tasked to reconcile contradictions, must adopt the merge policy as
   the reconciled rule. Only a human may formally revise #05's text.
2. **Accessibility gap** (above): no coverage bars set; #07/#08 inherit the gap.

### Omitted / deferred

- VoiceOver/keyboard coverage thresholds (deferred, above).
- Responsiveness/cancellation latency numbers (noted, not committed).
- Reproducible fixture *construction* and the mapping of bars → concrete checks
  (Ticket #07).
- Any wall-clock/throughput SLA (deliberately not committed).
