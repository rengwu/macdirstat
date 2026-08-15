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
  selection; a selection-change announcement. No quantitative coverage bar is asserted (the
  VoiceOver/Accessibility Inspector walkthrough is the release-checklist item in ticket 11).

## Done when

- `MacDirStatUITests` launch each of the six states from deterministic injected scan
  streams/results and assert: normal status bar (completed); "Incomplete — scan cancelled"
  with retained browsable results and a rescan affordance; "Completed with errors" with
  Unreadable rows, Incomplete ancestors, error summary, and excluded-cloud count.
- Per-item flags render concretely for symlink, hard-link (+owner), iCloud
  materialized/omitted, and package; Incomplete directories show red hatch **and** text.
- Keyboard commands (↑/↓, Return expand/open, ⌘O, ⌘R, chooser Esc) work; prototype-only
  variant controls are absent; selection persists through relayout.
- Accessibility checks confirm kind is conveyed in tooltip/inspector/legend and neither
  color nor hatch alone carries meaning; the treemap is focusable and announces
  selection changes.
- All six states match the ticket-01 gold-standard prototype.
