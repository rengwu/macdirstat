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

## Answer

Built. **`prototype/whole-app-variants.html`** is the authoritative visual and behavioral
reference for tickets 06–09 — the whole three-pane app, all six lifecycle states, the
chooser, the canvas treemap with merge buckets, and every §3.4 per-item semantic, in one
double-click file. The geometry bench **`prototype/merge-rule-variants.html`** is its
evidence: the same fixtures and viewport under three merge strategies with metrics, kept
deliberately on the same layout engine. Where the prototype and `spec.md` disagree, **the
prototype wins and the spec is what needs amending** — see "Spec amendments required".

### Decided — the deferred-within-v1 presentation details

1. **Tree columns.** `Name │ Size │ % │ Items`, sortable headers, default **Size ▼**. The
   % cell carries the number *and* an inline proportional bar in the same cell. No
   separate bar column, no Kind column. Implementation note for 08: this needs a custom
   `NSTableCellView` drawing the bar — not stock `NSTableColumn` behavior.
2. **Package drill-in.** Expanding a package in the tree subdivides its treemap box
   exactly like a folder; the outer rect's area never changes (verified: 81661.8 pt²
   both collapsed and expanded).
3. **Inspector field set.** As realized in the prototype, plus **a right-click context
   menu carrying Open and Reveal and only ever those two** — on tree rows and on treemap
   rectangles. Right-click selects first, so the menu always acts on what it points at.
   An aggregate box gets no menu; it is not a file. §7.1's "no mutation affordance
   anywhere" governs this menu too.
4. **Progress cadence and copy.** Scalars (bytes, files, folders, elapsed, %) refresh at
   **10 Hz** — live-looking without strobing the digits. The current-path line, the tree
   and the treemap refresh at **4 Hz**; a path line at 10 Hz is an unreadable blur.
   Terminal state repaints exactly once, immediately. Both sit inside §5.5's ≤15 Hz /
   ≤4 Hz budget. Whole-volume copy is exactly **"About N% of used space"** — "About"
   carries the explicit approximation §5.5 requires. Folder scans show no fraction and
   no explanatory line; the indeterminate bar already means "unknown".
5. **Palette.** The 11 kind hues + gray "other", saturation 55%, lightness 52% light /
   60% dark. Hues respaced during realization: `system` sat at 220, ten degrees from
   `code` at 210, and the two swatches were indistinguishable in the legend and in the
   map. Closest pair was 10°, is now 25° —
   `0 · 25 · 50 · 90 · 150 · 180 · 210 · 245 · 280 · 310 · 335`. §6.3 calls these
   "tunable, not load-bearing", so this is a good default, not a contract.
6. **Legend.** A second status-bar row, all 12 kind swatches plus "Merged", never behind
   an interaction — but **only once a scan has produced color**. Empty and Choosing show
   a one-row status bar.

### Decided — spec gaps that blocked ticket 06

7. **The merge rule: iterate to fixpoint.** §6.2 says merge children "whose individual
   squarified rectangle would fall below 2×2 pt" but never says whether to iterate, and
   removing tiny children repacks the survivors so a child can flip across the threshold.
   Squarify → merge slivers → re-squarify, until stable. Evidence at 520×390:

   | fixture | fixpoint | single-pass | one correction pass |
   | --- | --- | --- | --- |
   | Realistic home | **0 slivers** | 9, min 0.49 pt | 0 |
   | 10⁴:1 skew | **0** | 84 | 0 |
   | Flat 2,500 | **0** | 28, min 1.59 pt | 25 — does not converge |
   | Deep ×20 / 40 tails | **0** | 0 | 0 |

   Area truthfulness is 100.0000% under all three, so it is not the discriminating axis;
   sliver count is. Single-pass reasons about area and therefore cannot control shape.
   One correction pass provably does not converge. Cost of fixpoint is ≤81 squarify
   passes, <5 ms.
8. **Merge-box sort position: pinned last.** §6.1 fixes child order as bytes-desc for
   real children and is silent on the aggregate. Pinning it last rather than sorting it
   by combined bytes takes the flat fixture from 5 fixpoint rounds to 2 — and is the
   difference between one-correction leaving 25 slivers and 0. Both are deterministic, so
   both satisfy §9.3's golden-rect requirement; only one can be in the spec.
9. **Outline depth: capped at 3 levels below the root.** §6.1 outlines every directory
   below the root at 1 pt and §6.4 accepts 14–20+ level chains degrading to strips, which
   means 18 overdrawn strokes on a 6 pt strip. On the ×20 chain, capping at 3 draws 3
   outlines instead of 20 with **no visible difference** — the fills already carry the
   boundaries.
10. **Status-bar counts: what the tree shows.** A package is one file and contributes no
    folders (1,351 files · 20 folders, not 1,361 · 39). Deliberately *not*
    expansion-dependent — twirling a disclosure triangle must not change the totals.
    Byte totals still include package internals per §3.4, so the tally and the byte total
    measure different things by design. The inspector's per-node "Contains" row keeps the
    scanner's numbers, which is the question that row actually asks.

Also settled while building: **symlinks and hard-link non-owners display identically** —
`0 bytes`, with the real length on a separate "Logical length" row. The ticket-04
prototype showed `—` vs `0 bytes`, which contradicted §3.4 giving both zero attributed
bytes.

### Spec amendments required

These are **decisions, not open questions.** A human chose each one from the running
artifact; do not resolve them back toward the current spec text.

- **§6.2** must say the merge rule iterates to fixpoint.
- **§6.1** must state the merge box's position in child order (last), and must cap
  directory outlines at 3 levels below the root rather than "every directory".
- **§7.1** must state that file/folder counts are tree-visible counts, not scanner
  enumeration.
- **§7.3** asked for an "unmistakable **banner**" on Cancelled. It is a status-bar chip
  (bold, amber, leading dot, with `Start a fresh scan…`), backed by the tree's per-row
  `Incomplete` badges. Completed-with-errors is likewise a chip pair plus
  `Error summary…`.
- **§7.1** asked the empty state to state read-only + hidden-files-included + drive
  eligibility "up front". It states none of them; the empty state is icon, headline, one
  line, button.
- **§7.1** asked the chooser to show ineligible sources disabled-with-reason, "not
  hidden, so the scope rule is legible". They are filtered out entirely.

**Consequence a human should look at once, carried forward rather than reversed:** with
those last three cuts, the scope rule and the read-only guarantee are now stated nowhere
in the UI. A user who plugs in a Time Machine volume and doesn't find it in the chooser
gets no explanation for its absence. The scanner still refuses network volumes, disk
images and cloud roots — only the disclosure went away.

### Intentionally illustrative — do not build to these

- **The fixture.** Names, sizes, paths, the 1,361-entry shape, the 62%-revealed cancelled
  state, and the specific error/exclusion entries are staged to exercise the states.
- **The state switcher, the `?state=` URL parameter, and the light/dark toggle.** Prototype
  chrome. §7.2 already requires the variant switcher ship hidden/absent.
- **Every AppKit call is named, never made.** Open and Reveal raise a toast naming
  `NSWorkspace.shared.open` / `activateFileViewerSelecting`.
- **HTML/CSS/canvas mechanics generally.** Fonts are the system stack, not SF proper;
  metrics are px standing in for pt; the treemap is a `<canvas>`, not an `NSView`. One
  trap specifically: `<canvas>` is a replaced element, so `position:absolute; inset:0`
  does not stretch it — fixed by setting `style.width/height` explicitly. **This cannot
  happen in AppKit** (an `NSView` gets bounds from Auto Layout, Core Graphics applies the
  backing scale) and must not enter the spec as a finding.
- **The scan animation** — a 3.4 s eased reveal over a static fixture, not a traversal.
  The cadence decision above is real; the timeline it runs on is not.

### Verification performed

Both files smoke-tested headlessly (extract the `<script>`, stub the DOM, import as ESM;
plus headless-Chrome renders of every state). Verified: exact integer bytes throughout;
package aggregate unchanged by drill-in (81661.8 pt² both ways); symlink and hard-link
non-owner both zero-attributed; **100.0000% treemap area truthfulness**; **zero sub-2 pt
slivers** on all four bench fixtures under the chosen rule; all six lifecycle states
render; context menu, selection sync, and sort all exercised.

### Known loose end

Both prototypes are committed (`43c1c2a`). What was never preserved is the **losing**
variants — multi-column tree, source-list tree, opaque/explicit package modes, and the
popover/inspector/none legend placements. They were culled before that commit and exist
only in the originating session's history. The prototype skill wants losers kept on a
throwaway branch as a primary source. **The decisions themselves are recorded in the
prototype's header comment**, which is what tickets 06–09 actually need; reconstructing
the losing variants is optional and nobody has asked for it.
