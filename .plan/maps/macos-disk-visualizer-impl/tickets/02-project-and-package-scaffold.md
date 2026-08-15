---
type: task
blocked_by: []
undermined_by: []
---

# Project & package scaffold

## Question

Stand up the buildable, testable skeleton the whole map builds on — the prefactor done
first, per the settled architecture (spec §4) and verification contract (spec §9). No
product behavior yet; this is the harness that lets every later ticket land green.

Build:

- **One macOS App target** in an Xcode project: Swift, programmatic AppKit lifecycle (no
  storyboard document app), **not** document-based, `SUPPORTS_MACCATALYST=NO`, deployment
  target **macOS 11.0**, universal (`arm64` + `x86_64`), SwiftUI linked for interop. It
  launches to an empty window.
- **Two framework-free local Swift packages**, Foundation-only (no UI framework import):
  the scan engine package and the treemap-layout package (named per spec §4.2/§5/§6). Each
  builds and tests standalone via `swift test`.
- **The six test targets** from the verification contract (spec §9.1), each building green
  with placeholder tests: pure scanner, production-probe filesystem, treemap geometry,
  presentation-model, UI, and performance.
- **The three shared schemes and the CI test plan** (spec §9.1): the default CI scheme
  (every target except performance), the Release-configuration performance scheme, and the
  compatibility-smoke UI plan.
- **A post-Big-Sur API source-review guard** (spec §4.4): a check that flags unguarded use
  of `SwiftUI.Table`, `Canvas`, `NavigationSplitView`, and SwiftUI `searchable`, and
  affirms `NSSearchField` as the permitted search control.

## Done when

- The empty universal app launches on macOS 11.0 and builds for both architectures; the
  universal Release build command (spec §9.1) succeeds.
- All four documented local commands (spec §9.1) run: both package `swift test` commands,
  the `MacDirStat-CI` test action, and the Release universal build. The CI scheme is green
  with placeholders.
- Deployment target is fixed at `11.0` in the app target and both packages; compiler
  availability checking rejects an unguarded post-Big-Sur API, and the source-review guard
  is wired.
- Both local packages import Foundation and no UI framework (enforced by a
  dependency/build check).
- The scaffold is committed following repo conventions; no scan or UI behavior is
  implemented here.
