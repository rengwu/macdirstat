---
type: task
blocked_by: []
undermined_by: []
claimed_by: s30e8ed4e767d
claimed_at: 2026-08-16T07:28:20Z
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

## Answer

The skeleton is standing: `MacDirStat.xcodeproj` with the app target and three test
targets, `Packages/ScanCore` and `Packages/TreemapLayout` with the other three, four
shared schemes, four test plans, and three build-time guards that all have self-tests.
All four documented commands run green on Xcode 26.6, and `Scripts/verify-scaffold.sh`
exits 0 — see "Closed on a machine with Xcode" below for the one defect that surfaced.

**What was built**

- **App target** — programmatic AppKit lifecycle (`main.swift` → `AppDelegate` →
  `MainWindowController` → `MainMenu`), no storyboard, not document-based,
  `SUPPORTS_MACCATALYST = NO`, floor `MACOSX_DEPLOYMENT_TARGET = 11.0`, `ARCHS = arm64
  x86_64` with `ONLY_ACTIVE_ARCH = NO` in Release. It launches to one empty 1100×700
  window. `SwiftUIInterop.swift` links SwiftUI in the one shape §4.1 permits — an
  `NSHostingController` around a leaf view, never the hot path.
- **Two Foundation-only packages** with the floor pinned in each manifest. Neither
  imports a UI framework — not even CoreGraphics, so `TreemapLayout` will own its
  geometry types rather than borrow drawing ones.
- **Six test targets**, each with placeholders that state what will replace them:
  `ScanCoreTests`, `ScanCoreFileSystemTests`, `TreemapLayoutTests`, `MacDirStatTests`,
  `MacDirStatUITests`, `MacDirStatPerformanceTests`.
- **Schemes and plans** — `MacDirStat-CI` (plan `CI`: every target except performance),
  `MacDirStat-Performance` (plan `Performance`: Release, sanitizers explicitly off),
  `MacDirStat-CompatibilitySmoke` (plan `CompatibilitySmoke`), plus the plain `MacDirStat`
  scheme the documented Release build command names. §9.1 wants Thread Sanitizer as an
  *additional* run, so that is a second plan, `CI-ThreadSanitizer`, on the same scheme —
  which keeps the documented `-testPlan CI` command exactly as written instead of
  making every CI run pay for TSan.
- **Guards** (`Scripts/`), wired as a build phase on the app target and runnable
  standalone: `check-post-bigsur-apis.sh` (the §4.4 watch-list, with a
  `// compat-reviewed:` escape hatch), `check-package-purity.sh` (Foundation-only, read
  from the compiler's own `-emit-imported-modules` list rather than by grepping for
  "import"), and `check-project-integrity.py` (object graph, file references, schemes,
  test plans and the pinned build settings still agree). Each has a self-test under
  `Scripts/tests/` — 9, 7 and 18 cases — so a guard that stops guarding fails loudly.
  `Scripts/verify-scaffold.sh` runs the lot and exits 2, not 0, when a step is skipped.

**Closed on a machine with Xcode (Xcode 26.6, 2026-08-16)**

The ticket originally shipped from a machine with the Command Line Tools only, so three of
the four documented commands had never run and the hand-authored `.xcodeproj` was unproven
as a *build*. All of it has now been run. `Scripts/verify-scaffold.sh` exits **0**: both
package `swift test`s, `MacDirStat-CI -testPlan CI`, and the universal Release build all
pass, and the Release binary carries both slices at `minos 11.0`. **The pbxproj needed no
repair** — it built first try, which is the part that was most at risk.

One real defect surfaced, in the one place the gate was not looking. `Performance.xctestplan`
set `mallocStackLoggingOptions.loggingType` to `"none"`; that is not a value Xcode accepts
(the enum is `all` / `liveAllocationsOnly`, and *off* is the key's absence). Xcode rejects
the whole plan — `the test plan "Performance" could not be read` — so the entire
performance scheme was dead on arrival. Every existing check passed anyway, because the
file is valid JSON with the right targets and the right sanitizer flags; only Xcode reading
it for real can catch a bad enum value. Fixed by dropping the key, which is how Xcode itself
encodes "off", preserving the plan's intent.

The gate had a matching hole: it ran the `CI` plan and no other, so the three remaining
plans were never proven to so much as parse. `verify-scaffold.sh` now has a twelfth step
that runs `CI-ThreadSanitizer`, `Performance` and `CompatibilitySmoke` once each. Verified
as a guard, not just as a step: with the bad `loggingType` reinstated the new step FAILs and
the script exits 1 while all eleven older steps still report PASS.

All four schemes and all four plans are now green (the compatibility-smoke plan runs its
launch check and skips its six pending ones, per tickets 07–09).

What *was* proven about the app itself, without Xcode: the sources typecheck for `arm64`
and `x86_64` at the 11.0 floor; hand-linked into a universal bundle from the same sources
they produce a binary with both slices and `minos 11.0`; and that bundle launches and puts
its window on screen. That last check earned its keep — it caught the window collapsing to
its 720×480 minimum, because assigning an unsized view to the content view controller
overrides the initial content rect. Fixed, re-verified at 1100×728.

**Worth a human's attention:** §4.4 and §9.3 both say compiler availability checking
*rejects* unguarded post-Big-Sur APIs. It does not always. A `Canvas` inside a `some View`
body compiles with only a **warning** ("conformance … is only available in macOS 12.0 or
newer") and would crash on Big Sur. The source-review guard is therefore load-bearing, not
a second opinion — hence it fails the build rather than merely flagging.

**Omitted deliberately**

- **No sandbox entitlements.** Security-scoped access (§10) implies a sandbox, but
  sandboxing collides with whole-volume scanning via `mountedVolumeURLs`, and signing and
  distribution are out of scope for v1. Left off so ticket 07 can decide it with the
  chooser in hand rather than have it pre-decided here.
- No scan, layout or UI behaviour, no fixtures, no `DirectoryProbe` — tickets 03–10. The
  placeholder tests assert only what a scaffold can honestly assert.
- Release keeps `ENABLE_TESTABILITY = NO`; if the performance suite needs `@testable`,
  ticket 10 flips it knowingly.
