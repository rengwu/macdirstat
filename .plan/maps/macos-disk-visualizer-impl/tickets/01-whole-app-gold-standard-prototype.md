---
type: prototype
blocked_by: []
undermined_by: []
---

# Whole-app gold-standard prototype

## Question

Produce **one self-contained, runnable prototype** of the entire planned app as the final
authoritative visual and behavioral reference before implementation locks down. It
realizes the settled [specification](../../macos-disk-visualizer/spec.md) faithfully and
becomes the gold-standard artifact that tickets 06–09 build to.

Build a disposable prototype (single self-contained file, double-click to run — the
existing planning-map prototypes under `prototype/` are the shape to follow) that shows a
human the whole app as it will actually look and behave:

- The **three-pane workspace** — directory tree, treemap, inspector — with the unified
  toolbar and the bottom status bar (scanned total, file/folder counts, capacity/free for
  volumes, error/exclusion counts, size-color legend). See spec §7.1.
- **All six lifecycle states**: empty, choosing, scanning, completed, cancelled, and
  completed-with-errors — each fully rendered, not stubbed. See spec §7.3.
- The **chooser** with eligible sources plus ineligible ones (network / disk image /
  cloud) shown disabled with an inline reason. See spec §7.1.
- The **classic-flat treemap with merge-bucket aggregates** — the reconciled §6.2 rule
  (sub-2×2 pt content folds into one exactly-sized, selectable, distinctly-filled
  aggregate box per directory; nothing with real bytes disappears; area is 100%
  truthful). The prior treemap prototype predates this reconciliation and must not be
  copied verbatim.
- **Per-item Ticket-01 semantics shown concretely**: symlink (0 bytes, "never followed"),
  hard link ("counted elsewhere" + owner path), iCloud materialized-vs-omitted, package
  as one box, unreadable + Incomplete ancestors.
- **Bidirectional single-source selection** across tree ↔ treemap ↔ inspector, and the
  read-only Open / Reveal affordances (no mutation affordance anywhere).

This ticket also **settles the presentation details the spec deferred within v1** (spec
§2, "deferred within v1"), recording them concretely in the artifact and a short decision
note so downstream tickets inherit them:

- exact directory-tree columns (size / % / count / kind), default sort, and percent-bar
  treatment;
- the final inspector field set, and whether Open/Reveal also appear in a context menu;
- the collapsed-package → expand-to-children drill-in interaction (the aggregate is
  already fixed by spec §3.4; only the child presentation is open);
- the final progress cadence and the exact whole-volume approximate-% copy;
- the exact palette hues for the 11 kind groups + "other", in light and dark appearance.

This is a realization/validation pass, **not** a re-decision of settled semantics. If any
settled decision proves wrong or self-contradictory when made concrete, **flag it for a
human in the answer** rather than silently changing it.

## Done when

- A single self-contained runnable artifact exists under this map (e.g. `prototype/`) and
  a human has reacted to it across every one of the six lifecycle states and the
  selection/inspector/treemap interactions above.
- The artifact reflects the **reconciled merge-bucket** treemap behavior, not the old
  culling behavior.
- The deferred-within-v1 presentation details listed above are each decided and recorded
  (in the artifact and a concise decision note in this ticket's answer), unambiguous
  enough for tickets 06–09 to implement without further product choices.
- Any friction with, or suspected error in, the settled spec is explicitly flagged for a
  human; no settled semantic decision is silently altered.
- The answer states that this artifact is the authoritative visual/behavioral reference
  for the on-screen tickets, and names anything intentionally left illustrative.
