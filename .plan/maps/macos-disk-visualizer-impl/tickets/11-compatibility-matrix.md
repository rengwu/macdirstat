---
type: task
blocked_by: [09, 10]
undermined_by: []
---

# Compatibility matrix (release gate)

## Question

Prove the universal release artifact actually runs the whole workflow on every supported
macOS, and record it — the final integrate-and-verify gate before declaring a release
candidate compatible. A deployment-target build is necessary but is **not** accepted as a
substitute for running the app on Big Sur. Fixed by spec §9.1 and §9.3 (compatibility
matrix) and the accessibility walkthrough of §9.4.

Do:

- Assemble the **`MacDirStat-CompatibilitySmoke`** UI test plan (spec §9.1): launch, folder
  scan, incremental-result, cancel, selection, Open/Reveal-spy, and partially-failed-state
  checks against deterministic injected streams plus at least one real disposable-fixture
  scan.
- Produce the **universal Release artifact** (`x86_64` + `arm64`) via the documented build
  command, and confirm compiler availability checking rejects unguarded post-Big-Sur APIs
  and the source-review guard flags `SwiftUI.Table`, `Canvas`, `NavigationSplitView`, and
  SwiftUI `searchable`.
- Run the **`MacDirStat-CI` gate once under Thread Sanitizer** as an additional diagnostic
  (consuming events on `@MainActor`), separate from the un-sanitized performance run.
- Run the compatibility smoke on **at least one host per major macOS version from 11
  through the current stable release**, using the **same** universal artifact — mandatory
  endpoints **Big Sur 11.7.x on the 2015-era Intel/8 GB/SATA floor** and **current stable
  macOS on Apple Silicon**. Where a host's Xcode can run the UI plan it automates the
  checklist; otherwise the same copied artifact and fixture are exercised manually.
- Perform **one VoiceOver + Accessibility Inspector walkthrough** of the empty, scanning,
  selected-file/directory/aggregate, cancelled, and error states on Big Sur and current
  macOS, recording defects (no pass-percentage or task-coverage threshold is applied).

## Done when

- The universal Release build succeeds for both architectures and the availability/
  source-review guards hold; the CI gate passes once under Thread Sanitizer.
- A runtime record exists for every major macOS from 11 through current stable (mandatory
  Big Sur/2015-Intel and current/Apple-Silicon endpoints), each entry capturing exact
  OS/build, architecture, hardware or VM, artifact commit, and pass/fail for launch, Smoke
  scan totals, incremental updates, cancellation/retained results, partial errors,
  treemap selection, keyboard commands, and disposable-file Open/Reveal.
- On the 2015-era Intel floor the Smoke workflow is correct, cancellable, non-crashing,
  and allows UI interaction while scanning (no scan-time/throughput threshold applied).
- The VoiceOver/Accessibility Inspector walkthrough is completed on Big Sur and current
  macOS with defects recorded.
- This runtime record — not availability compilation alone — stands as the compatibility
  claim, satisfying the specification's acceptance criteria (§12) for a release candidate.

## Ruled out

Closed by the 2026-08-18 floor decision, which is recorded at the top of `spec.md`: **the
deployment floor is macOS 14 and the build is no longer a universal `arm64 + x86_64`
slice.** Every deliverable this ticket asks for is either impossible or meaningless now:

- The `MacDirStat-CompatibilitySmoke` plan, the UI-test target it would run in, and the
  Thread Sanitizer plan were all deleted in the same pass.
- There is no universal Release artifact to carry between hosts, because `ARCHS` is
  unpinned and the build follows the standard setting.
- The post-Big-Sur source guard that would flag `SwiftUI.Table`, `Canvas`,
  `NavigationSplitView` and `searchable` is deleted, along with the whole watch-list — those
  APIs are all available at the macOS 14 floor, so there is nothing left to flag.
- Running on "Big Sur 11.7.x on the 2015-era Intel floor" is testing four major versions
  below the floor the app now declares. It would not launch.

Its `blocked_by: [09, 10]` is also unsatisfiable in the direction it assumed: ticket 10's
deliverable no longer exists.

**Nothing here was proven, so this is a boundary and not an answer.** One piece of it is a
real loss and does not deserve to disappear with the rest: the **VoiceOver + Accessibility
Inspector walkthrough**, which ticket 09 explicitly defers to this ticket. That walkthrough
survives as a one-host check on current macOS and moves to
[ticket 09](./09-lifecycle-legibility-and-accessibility.md), where the mechanics it would
exercise are built. Nothing else here is recoverable, and a floor of macOS 14 is why.
