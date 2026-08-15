---
type: task
blocked_by: [03]
undermined_by: []
---

# ScanCore: identity, resilience & exclusion semantics

## Question

Complete the scan engine's measurement honesty: the filesystem-identity rules (hard links,
clones, packages) and the resilience/exclusion rules (recoverable errors, cloud gating,
bounded detail, volume capacity/free, live change). All of this is scripted-probe testable
and finishes the engine's semantic contract. Fixed by spec §3.4, §3.5, §5.7.

Add to the scan-engine package, on top of ticket 03's traversal:

**Identity semantics (spec §3.4):**
- **Hard-link dedup by filesystem identity**, with the identity index populated **only for
  `linkCount > 1`** and bypassed when the volume reports no hard-link support. Under the
  deterministic order the first in-scope path owns the bytes; later in-scope paths stay
  visible with **zero** attributed bytes, a "counted elsewhere" marker, and the owner path
  when available. Names outside the root are neither sought nor shown.
- **APFS clones counted separately** — distinct identities each contribute their ordinary
  logical length.
- **Packages measured recursively** during the scan so the aggregate is exact, while
  presented initially as one collapsed item/box (the detailed child hierarchy may be
  materialized lazily without changing the aggregate).

**Resilience & exclusions (spec §3.5, §5.7):**
- **Recoverable errors never abort and never guess sizes**: unreadable dir/entry,
  disappearance, malformed metadata → entry marked Unreadable, every affected ancestor
  Incomplete, size stays zero, siblings continue, `.completed` still reached, exact
  per-category counts. No synthetic "Unknown" derived from physical usage.
- **Bounded error detail**: retain up to 1,000 detailed records, then keep only the exact
  running total with a `truncated` flag.
- **Cloud materialization gating**: only `.downloaded`/`.current` items count; a
  `.notDownloaded` placeholder is omitted, has no node, and increments the exact exclusion
  count, with **no** download/network request; an unavailable/third-party status safely
  counts the present logical file.
- **Volume capacity/free carried separately** in the result — never turned into an
  attributed node byte count.
- **Live change is best-effort**: a vanished already-listed entry becomes a recoverable
  error; no second pass or automatic restart.

## Done when

- `ScanCoreTests` (scripted identities/statuses) prove: first stable path owns bytes;
  duplicate stays visible with owner path and zero bytes; an outside name is absent;
  distinct clone identities both count; the identity index is consulted only when link
  count > 1 and bypassed when unsupported.
- Package rollup is exact while the presentation stays a single item/box.
- Recoverable-error scripts show siblings continuing, Unreadable/Incomplete propagation,
  zero attributed size, `.completed` reached, and exact category counts; injecting 2,500
  failures yields exact total 2,500, first 1,000 detailed records, and `truncated == true`.
- Cloud scripts (`.current`, `.downloaded`, `.notDownloaded`, unavailable) count the first
  two, omit and count the placeholder, and safely count the unavailable one; a spy proves
  no download/open-data call occurs.
- Volume-mode results expose injected capacity/free with no `capacity - free` value
  reaching any node or formatter.
- A barrier probe proves disappearance is recoverable with no second pass or automatic
  restart.
