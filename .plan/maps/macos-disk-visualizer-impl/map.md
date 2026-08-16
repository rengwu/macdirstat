# macOS Disk Visualizer — Implementation

## Destination

Build the first shippable-locally version of the macOS Disk Visualizer to the settled
[specification](../macos-disk-visualizer/spec.md): a native Swift/AppKit macOS app,
universal (`arm64` + `x86_64`) with a macOS 11.0 floor, that scans one selected local
folder or volume with visible cancellable progress and presents synchronized
directory-tree and classic-flat treemap views driven by one shared selection, with
read-only Open and Reveal actions. Done when every acceptance criterion in the
specification (§12) is met and the full verification gate (§9) passes: the `MacDirStat-CI`
scheme green (with one Thread Sanitizer run), the universal Release build succeeding, the
performance/scale suite within the 8 GB/no-OOM ceiling, and the compatibility runtime
matrix recorded across macOS 11 through current.

## Notes

- The authoritative contract is [`spec.md`](../macos-disk-visualizer/spec.md) in the
  planning map. Every ticket here traces to it; read the referenced sections before
  working a ticket. Do not reopen settled product or technical decisions — flag conflicts
  for a human instead.
- This is the implementation map paired with the planning map
  `.plan/maps/macos-disk-visualizer/`. The planning map's `spec.md`, prototypes, and
  assets are the durable upstream record.
- Tickets are tracer-bullet vertical slices worked the frontier way: any ticket whose
  `blocked_by` tickets are all resolved is takeable. Start frontier: **01** (whole-app
  prototype) and **02** (scaffold) run in parallel.
- The **whole-app gold-standard prototype (01)** is the authoritative visual/behavioral
  reference for all on-screen work. It settles the spec's deferred-within-v1 presentation
  details (tree columns/sort, inspector field set, package drill-in, progress copy,
  palette hues). Tickets 06–09 build to it.
- Read-only is structural and non-negotiable: no dependency exposes a write/download
  method; the only file actions are Open and Reveal. Verification proves it three ways
  (fixture fingerprint, no-write-method, action spies).
- Prefer Apple primary documentation for platform and API facts, consistent with the
  spec's cited findings.

## Decisions so far

- [Whole-app gold-standard prototype](./tickets/01-whole-app-gold-standard-prototype.md) —
  `prototype/whole-app-variants.html` is the authoritative visual/behavioral reference for
  06–09. Settles the deferred-within-v1 details (tree columns `Name │ Size │ % │ Items`
  default Size ▼ with an inline bar in the % cell; package drill-in subdivides without
  changing outer area; inspector field set plus a right-click Open/Reveal menu; 10 Hz
  scalars / 4 Hz tree with "About N% of used space"; 11 respaced kind hues; legend only
  once a scan has color) and closes the three spec gaps blocking 06: **merge rule
  iterates to fixpoint**, **merge box pinned last** in child order, **outlines capped at
  3 levels**. Status-bar counts are tree-visible, not scanner-enumerated. §§6.1, 6.2, 7.1
  and 7.3 need amending to match — the prototype is authoritative where they disagree.

## Not yet specified

- **Spec text lags the prototype.** Ticket 01's answer supersedes six clauses across
  §§6.1, 6.2, 7.1 and 7.3 (merge iteration, merge-box order, outline depth cap,
  tree-visible counts, Cancelled banner → status-bar chip, empty-state and chooser
  disclosures removed). `spec.md` still carries the old wording. These are settled
  decisions, not open questions — the patch is the edit to `spec.md`, not a re-decision.
- **The read-only guarantee and the scan-scope rule are stated nowhere in the UI.** A
  consequence a human accepted knowingly when the empty-state disclosures and the
  chooser's disabled ineligible rows were cut. Worth one look before 09 ships: a user
  whose network volume is simply absent from the chooser gets no reason for it.

## Out of scope

- File mutation of any kind — deletion, cleanup, moving, renaming, duplicate detection —
  and any file-management workflow. The first version is read-only (Open/Reveal only).
- Historical comparison, scheduled or background scanning, and analytics.
- Multiple roots per scan; network volumes, cloud-provider roots, mounted disk images,
  and nested mounted volumes as scan scope.
- Signing, notarization, packaging, distribution, crash reporting, and update mechanisms.
- Persisted documents — a scan is a transient session; the app is not document-based.
- Quantitative accessibility coverage bars, and any wall-clock / throughput / UI-latency
  SLA (the spec commits algorithmic and memory bars only; accessibility mechanics are
  required but no coverage threshold is set).
