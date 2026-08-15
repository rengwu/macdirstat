---
type: task
blocked_by: [01, 02, 03, 04, 05, 06, 07]
undermined_by: []
claimed_by: s0dd55e066976
claimed_at: 2026-08-15T06:16:30Z
---

# Write the implementation-ready product specification

## Question

How do the resolved product, interaction, filesystem, architecture, treemap, quality, and verification decisions combine into one coherent contract for the first implementation? Reconcile contradictions and capture interfaces between subsystems without inventing new product decisions.

## Done when

`.plan/maps/macos-disk-visualizer/spec.md` is linked from this ticket, covers every destination requirement and resolved decision, names all exclusions, contains acceptance criteria and verification guidance, and leaves no material product or technical choice for an implementation session. The answer also states that a separate implementation map can now be charted.

## Answer

Wrote the implementation-ready specification at
[`spec.md`](../spec.md). It consolidates all seven resolved tickets into one
authoritative contract and invents no new product decisions.

**What it covers.** §1–2 product summary, scope, and every exclusion (mutation,
analytics/history, multiple roots, network/cloud/disk-image/nested roots, release
infrastructure, persisted documents) plus the deferred-within-v1 items and the explicit
unset boundaries. §3 the full measurement contract from Tickets 01/03 (logical
`fileSizeKey` only; IEC formatting; one-root/one-device; entry-type semantics for
hidden/symlink/hard-link/clone/package/cloud; error/cancellation/live-change; the seven
acceptance cases). §4 architecture and project shape from Ticket 02 (AppKit-first hybrid,
macOS 11.0 floor, two Foundation-only packages, the concurrency/UI boundary, the
compatibility watch-list, rejected alternatives). §5 the `ScanCore` engine from Ticket 03
(actor `Scanner`, `AsyncStream<ScanEvent>`, serial iterative shallow DFS, data model,
state contract, progress, cancellation, error bounds). §6 the treemap from Ticket 05.
§7 the accepted three-pane workspace and interaction model from Ticket 04. §8 the quality
bars from Ticket 06 (reference hardware, workload ladder, algorithmic-not-wall-clock
performance, 8 GB/never-OOM memory ceiling, resilience matrix, formatting). §9 the layered
verification strategy from Ticket 07 (targets, schemes, commands, fixtures, traceability,
a11y mechanics). §10 the subsystem interface seams. §11 the reconciled contradictions and
known gaps. §12 an implementation-ready acceptance checklist. §13 the next step.

**Contradictions reconciled (§11), per the ticket's mandate.** (1) The treemap sub-2×2 pt
policy is resolved in favor of Ticket 06's **merge** rule (exactly one per-directory,
exactly-sized, hit-testable aggregate box; 100% area truthfulness) over Ticket 05's
earlier render-only culling; §6.2 states the single reconciled rule. (2) The macOS 11
disk-image-root detection gap (Ticket 03) is recorded as an accepted, bounded residual —
network exclusion and the device boundary remain fully enforced. (3) The accessibility
coverage gap (Ticket 06) is stated as an explicit deferred boundary: mechanics required,
no coverage threshold committed.

**What I did not do.** I invented no new product decisions and did not reopen any settled
ticket. Ticket 05's prose still carries its original culling wording with `06` in its
`undermined_by`; only a human may formally revise it — this spec is the reconciliation the
map's Done-when requires. Deferred-within-v1 presentation details (tree columns/sort,
inspector field set, package drill-in, progress copy, exact palette hues) are named as
deferred with fixed enclosing behavior; none blocks implementation.

A separate implementation map can now be charted at
`.plan/maps/macos-disk-visualizer-impl/`, decomposing this contract into build tickets
sequenced along the §10 seams.
