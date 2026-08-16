---
type: task
blocked_by: [01, 03, 05]
undermined_by: []
claimed_by: s005ce3cb933a
claimed_at: 2026-08-16T12:44:36Z
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

## Answer

Built the first complete on-screen tracer bullet in the AppKit app target. The single
programmatic window now contains a source-list `NSOutlineView`, a growable center pane,
and a collapsible 260–360 pt inspector in `NSSplitViewController`, with a unified toolbar
and a one/two-row bottom status bar. The tree is fed only when ScanCore supplies a new
frozen tree snapshot (4 Hz), while scalar progress refreshes at 10 Hz and the path line is
separately held to 4 Hz. Its settled columns are `Name │ Size │ % │ Items`, default Size
descending, with an inline percent bar; package descendants remain collapsed initially.
Terminal totals use tree-visible file/folder counts, so packages count once while their
measured descendant bytes remain in the total.

Added the production scan presentation model and real `FileManagerDirectoryProbe` flow.
Folder choices go through `NSOpenPanel(canChooseDirectories: true)`; mounted local disks
come from `mountedVolumeURLs`; scanning remains off-main, incrementally populates the
tree behind an indeterminate/determinate progress card, reports the settled telemetry and
`About N% of used space` copy, and Cancel calls ScanCore while continuing to consume the
partial terminal result. Completed status includes IEC total, visible counts,
volume-capacity/free facts, error/exclusion counts, and the kind legend once bytes exist.

The chooser follows ticket 01 where the stale question disagrees: ineligible network,
cloud, and modeled disk-image candidates retain explicit, tested classifications and
reasons, but are filtered from the sheet rather than displayed disabled. Likewise the
empty state is the accepted minimal icon/headline/one-line/button version, with no
read-only/scope disclosures. Escape dismisses the source sheet. The app remains
unsandboxed: distribution is out of scope and enabling the sandbox would conflict with
whole-volume enumeration; security-scoped access remains balanced by ScanCore but is not
treated as eligibility.

Added a custom locale-aware IEC formatter with exactly three significant figures and no
`ByteCountFormatter`, exact grouped byte/count formatting, singular byte handling, and
the settled percentage floor/rounding. Unit coverage fixes `en_US` and `de_DE` across
0/1/1023/1024 and every boundary through TiB, rounding carry, exact 0.05%, ordinary and
100% shares. Presentation tests cover source policy, Escape, shell hierarchy, tree setup,
a suspended scanner/main-actor responsiveness, and a real temporary-folder total. UI
tests exercise the mounted-source sheet and select a disposable folder end-to-end through
the real open panel. Ticket-07 compatibility rows for launch and folder scan now run;
cross-host incremental-fixture activation remains ticket 11, while the live UI boundary
is covered headlessly here.

`Scripts/verify-scaffold.sh` now compiles app/package imports through Xcode for both
architectures (a bare `swiftc` cannot resolve local Xcode package products), and its
integrity self-test copies package manifests rather than gigabytes of ignored `.build`
artifacts. The final one-command gate exits 0: 130 ScanCore tests, 71 TreemapLayout tests,
10 app presentation tests, the CI and Thread Sanitizer plans, universal Release build,
Performance plan, Compatibility plan, all guards, and both floor-pinned architecture
compiles pass.

Deliberately omitted ticket 08's real treemap drawing/selection and inspector content,
and ticket 09's full cancelled/error presentation plus Open/Reveal actions. Their panes
remain explicit placeholders; no mutation affordance was introduced.
