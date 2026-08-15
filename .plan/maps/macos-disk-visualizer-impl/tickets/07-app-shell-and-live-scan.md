---
type: task
blocked_by: [01, 03, 05]
undermined_by: []
---

# App shell + tree + chooser + live scan (+ formatting)

## Question

The first on-screen tracer bullet: choose a folder, watch the directory tree fill live
with cancellable progress, and see correctly formatted totals. This delivers the AppKit
shell, the tree pane, the chooser, the scanning/progress/cancel flow, the status bar, and
the display formatting utilities they all use. Built to the gold-standard prototype
(ticket 01); fixed by spec §4.1, §7.1, §7.3, and the formatting rules of §3.2/§8.6.

Implement in the app target:

- The **shell**: `NSApplicationDelegate` + programmatic `NSWindowController` hosting an
  `NSSplitViewController` with three split items — source-list `NSOutlineView` tree
  (left), the treemap area as the growable item (center, placeholder until ticket 08), and
  a collapsible ~300 pt inspector (right, placeholder until ticket 08). Unified toolbar;
  bottom status bar.
- **Display formatting** (spec §3.2/§8.6): a custom IEC formatter (3 significant figures,
  no `ByteCountFormatter`), locale-aware digit grouping / exact byte counts via
  `NumberFormatter`, share-of-parent percentages to 1 decimal with a `< 0.1%` floor, and
  `0 bytes` / `1 byte` handling. Proven in `MacDirStatTests`.
- **The directory tree** driven by the engine's frozen snapshots, populating incrementally
  during a scan, with the columns/default-sort/percent-bar treatment settled by the
  ticket-01 prototype.
- **The chooser**: a toolbar "Choose…" sheet listing eligible sources (internal +
  directly-attached drives, plus a folder via `NSOpenPanel` with `canChooseDirectories`),
  with ineligible sources (network / disk image / cloud) shown disabled with an inline
  reason. Esc dismisses.
- **Empty and scanning states**: a centered empty call-to-action stating read-only +
  hidden-included + eligibility; a centered scanning progress card with live telemetry
  (measured bytes, files, folders, elapsed, current path, throughput), an explicitly
  approximate % only for whole-volume scans, and a prominent Cancel; the tree populates
  behind it. Completed state shows the normal status bar (totals, file/folder counts,
  capacity/free for volumes, error/exclusion counts, size-color legend).

Consumes the production probe from ticket 05 for real `NSOpenPanel` scans; the full
cancelled/error-state legibility and the treemap/inspector/selection are later tickets.

## Done when

- A real folder chosen via `NSOpenPanel` scans end-to-end: the tree fills incrementally,
  the progress card shows live telemetry with a working Cancel, and on completion the
  status bar shows correct IEC totals and counts. The scan runs off-main and a UI
  event/selection completes while a paused probe holds the scan (main actor not blocked).
- A view-hierarchy test asserts the programmatic AppKit lifecycle, three
  `NSSplitViewController` items, source-list tree left, growable center item, unified
  toolbar/status bar, and a collapsible ~300 pt inspector right; SwiftUI hosting (if used)
  is confined to leaf panels.
- Chooser-model tests show eligible local/internal/external sources and disabled
  network/cloud/disk-image classifications with inline reasons; Esc dismisses. One manual
  pass exercises the real `NSOpenPanel` and mounted-volume list.
- Formatting tests (locale-fixed) cover 0, 1, 1023, 1024, every unit boundary through TiB,
  rounding carry, three significant figures, `en_US` and a comma-decimal locale (grouping
  without changing KiB labels), and percentages at 0 / <0.05% / exactly 0.05% / ordinary /
  100% producing one decimal and `< 0.1%` rather than `0.0%`.
- Empty, choosing, scanning, and completed states match the ticket-01 prototype; no
  mutation affordance exists anywhere in the shell.
