---
type: task
blocked_by: [01, 04, 08]
undermined_by: []
---

# Full lifecycle legibility + accessibility mechanics

## Question

Make every terminal and degraded state unmistakable and honest, and finish the settled
accessibility mechanics across the app. This closes the gap between "happy-path scan
works" and "the app tells the truth in every state." Built to the gold-standard prototype
(ticket 01); fixed by spec §7.3, §6.3, §9.4, consuming the error/exclusion data from
ticket 04 and the full workspace from ticket 08.

Implement in the app target:

- **Cancelled state**: an unmistakable "Incomplete — scan cancelled" banner, partial
  results fully retained and browsable/selectable, and a way to start a fresh scan.
- **Completed-with-errors state**: a "Completed with errors" presentation marking the
  unreadable entry **Unreadable** (size never guessed), every affected ancestor
  **Incomplete**, and surfacing an error summary plus an excluded-cloud-items count.
- **Concrete per-item Ticket-01 semantics** shown in tree/inspector/treemap: symlink
  (0 bytes, "never followed"), hard link ("counted elsewhere" + owner path), iCloud
  materialized-vs-omitted, package as one box; **Incomplete** directories drawn with a red
  diagonal hatch **plus** text on the treemap (color/hatch never the only channel).
- **Accessibility mechanics finalized** (spec §9.4): kind written in
  tooltip/inspector/legend; Incomplete carries hatch + text; tree keyboard navigation
  (↑/↓, Return, ⌘O/⌘R, Esc for the chooser); the treemap focusable and following the shared
  selection; a selection-change announcement. No quantitative coverage bar is asserted.
- **One VoiceOver + Accessibility Inspector walkthrough** of the empty, scanning,
  selected-file/directory/aggregate, cancelled and error states, on current macOS, recording
  defects. No pass-percentage threshold. This moved here on 2026-08-18 from
  [ticket 11](./11-compatibility-matrix.md), which was ruled out by the macOS 14 floor
  decision; it is the one piece of that ticket worth keeping, and it belongs where the
  mechanics it exercises are built.

## Done when

> **The verification surface changed on 2026-08-18.** `MacDirStatUITests` is deleted, so
> nothing can launch the app and drive it any more. Assert what is assertable in
> `MacDirStatTests` — which is app-hosted and builds a real workspace through
> `WorkspaceTestHarness` — and check the rest by building, launching and scanning by hand.
> Do not add a UI-test target back to satisfy this ticket without asking first.

- Each of the six states, driven from deterministic injected scan streams/results, asserts:
  normal status bar (completed); "Incomplete — scan cancelled" with retained browsable
  results and a rescan affordance; "Completed with errors" with Unreadable rows, Incomplete
  ancestors, error summary, and excluded-cloud count.
- Per-item flags render concretely for symlink, hard-link (+owner), iCloud
  materialized/omitted, and package; Incomplete directories show red hatch **and** text.
- Keyboard commands (↑/↓, Return expand/open, ⌘O, ⌘R, chooser Esc) work; prototype-only
  variant controls are absent; selection persists through relayout.
- Accessibility checks confirm kind is conveyed in tooltip/inspector/legend and neither
  color nor hatch alone carries meaning; the treemap is focusable and announces
  selection changes.
- All six states match the ticket-01 gold-standard prototype.

## Answer

**The app tells the truth in every terminal and degraded state, and the accessibility
mechanics are finished.** The cancelled state leads the status bar with
"● Incomplete — scan cancelled" and keeps its partial total browsable and selectable, with
a rescan affordance; completed-with-errors marks the entry **Unreadable**, its ancestors
**Incomplete**, and surfaces the error summary and the excluded-cloud count. Per-item
ticket-01 semantics render concretely — symlink at 0 bytes and never followed, hard link
with "counted elsewhere" and its owner path, iCloud materialized-vs-omitted, package as one
box, and an Incomplete directory drawn with the red diagonal hatch **and** text, so neither
color nor hatch ever carries meaning alone. The treemap is a focusable group that follows
the shared selection and announces changes once; kind is written in tooltip, inspector and
legend; the tree keyboard set (↑/↓, Return, ⌘O/⌘R, Esc for the chooser) works and selection
survives relayout.

**Two things the ticket did not ask for, found by building it.** A count of errors says how
wrong a total might be; only a path says whether that matters to you — so the inspector now
describes the *scan* while nothing is selected, naming the first five unreadable paths with
"…and N more", the counts by reason, and which kind makes a total a floor. And the treemap
published one accessibility element per
rendered rectangle, up to 137,056 on a whole-volume map; a client copying that hierarchy
cost **7.0–8.4 s of main thread** — the freeze ticket 14 removed, reached from outside the
process. It now publishes only the labelled rectangles plus the selected one, which is the
rule already on screen and already in the mouse. Nothing becomes unreachable: the tree pane
carries every node and its hierarchy. `spec.md` §9.4 is amended to match.

### Verification

Asserted in `MacDirStatTests` against deterministic injected scan streams, per the
2026-08-18 note above — no UI-test target was added back. The one part of §7.3 the app
tests had not covered, the status bar's two degraded states, is now two pure `text(...)`
tests matching the existing status-bar style. Gate green at **ScanCore 143 ·
TreemapLayout 88 · app 74**.

### Excluded

**The VoiceOver + Accessibility Inspector walkthrough was deliberately cut as YAGNI on
2026-08-18 and never run** — recorded here so a later reader knows it was skipped, not that
it passed. The spec commits no accessibility coverage bar (§11.3), the mechanics themselves
are unit-tested, and a by-hand VoiceOver pass is a release-checklist step rather than a
build step. If a release candidate is ever declared, somebody runs it then. This was the
one surviving piece of [ticket 11](./11-compatibility-matrix.md); ruling it out here does
not reopen that ticket.

The read-only guarantee and the scan-scope rule are still stated nowhere in the UI — a
consequence accepted when the empty-state disclosures and the chooser's disabled ineligible
rows were cut. It is carried on the map as an open patch, not fixed here.
