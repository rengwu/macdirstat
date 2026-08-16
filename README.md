# MacDirStat

A native macOS disk visualizer: scan one folder or volume, and read it as a
synchronized directory tree and a classic flat treemap. Read-only — the only
file actions are Open and Reveal.

The authoritative contract is
[`.plan/maps/macos-disk-visualizer/spec.md`](.plan/maps/macos-disk-visualizer/spec.md).
Section references below (§) point into it.

## Layout

| Path | What it is |
| --- | --- |
| `MacDirStat.xcodeproj` | The app project: one macOS App target and three test targets (§4.2) |
| `App/MacDirStat` | AppKit shell — programmatic lifecycle, no storyboard, not document-based (§4.1) |
| `Packages/ScanCore` | Foundation-only scan engine: traversal, aggregation, cancellation, progress, errors (§3, §5) |
| `Packages/TreemapLayout` | Foundation-only rectangle layout: squarified geometry and the merge rule (§6) |
| `TestPlans` | The CI, thread-sanitizer, performance and compatibility-smoke plans (§9.1) |
| `Scripts` | The build-time guards and the local verification gate |

The two packages import Foundation and nothing else — not AppKit, not SwiftUI,
not even CoreGraphics — so they test headlessly and own their own geometry
types.

## Requirements

**Xcode is required**, not just the Command Line Tools: `xcodebuild` and the
XCTest framework both ship with it. With the Command Line Tools alone you can
build the packages and typecheck the app, but you cannot run a single test.

```sh
sudo xcode-select -s /Applications/Xcode.app
```

Deployment floor: **macOS 11.0 Big Sur**, universal (`arm64` + `x86_64`).

## The four local commands (§9.1)

```sh
swift test --package-path Packages/ScanCore
swift test --package-path Packages/TreemapLayout

xcodebuild test -project MacDirStat.xcodeproj -scheme MacDirStat-CI \
  -testPlan CI -destination 'platform=macOS'

xcodebuild build -project MacDirStat.xcodeproj -scheme MacDirStat \
  -configuration Release -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=11.0
```

Or run everything at once:

```sh
Scripts/verify-scaffold.sh
```

It exits `0` when every step ran and passed, `1` on failure, and `2` when a step
had to be skipped — a skipped step is not a green gate.

## Schemes and plans (§9.1)

| Scheme | Plan | Purpose |
| --- | --- | --- |
| `MacDirStat` | — | Build and run the app |
| `MacDirStat-CI` | `CI` | Every test target except performance; the one-command gate |
| `MacDirStat-CI` | `CI-ThreadSanitizer` | The same targets once under TSan, required before an RC |
| `MacDirStat-Performance` | `Performance` | Release, no sanitizers, reference machine, opt-in before an RC |
| `MacDirStat-CompatibilitySmoke` | `CompatibilitySmoke` | Launch/scan/cancel/selection workflow on each supported macOS |

The six test targets: `ScanCoreTests`, `ScanCoreFileSystemTests`,
`TreemapLayoutTests`, `MacDirStatTests`, `MacDirStatUITests`,
`MacDirStatPerformanceTests`.

## Guards

These run on every app build and from `Scripts/verify-scaffold.sh`. Each has its
own self-test under `Scripts/tests/`, so a guard that has stopped guarding shows
up as a failure rather than as silence.

| Script | What it enforces |
| --- | --- |
| `check-post-bigsur-apis.sh` | No unreviewed `SwiftUI.Table`, `Canvas`, `NavigationSplitView` or `searchable` — all above the 11.0 floor; `NSSearchField` is the permitted search control (§4.4) |
| `check-package-purity.sh` | Both packages import Foundation and no UI framework, taken from the compiler's own import list, and pin the 11.0 floor (§4.2) |
| `check-project-integrity.py` | The project's object graph, file references, schemes, test plans and pinned build settings still agree with each other |

A genuinely reviewed and guarded use of a watch-list API is exempted with a
marker on the line or the line above it:

```swift
// compat-reviewed: guarded by if #available(macOS 12.0, *), Big Sur takes the fallback
```
