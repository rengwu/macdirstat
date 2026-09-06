# Developing MacDirStat

Start with the [README](../README.md#build-and-install) for requirements and a
first build. Full Xcode is required; the deployment target is macOS 14.

## Build and run

`make help` lists all tasks. App builds go into `.build/xcode`, which is
Git-ignored.

```sh
make run      # build the debug app and launch it
make rerun    # quit the dev instance, rebuild, and launch again
make console  # launch with console output attached
make stop     # quit the dev instance
make release  # build the Release app for Intel and Apple Silicon
```

The Release app is at
`.build/xcode/Build/Products/Release/MacDirStat.app`. The current configuration
signs locally with an ad hoc identity; `make release` does not notarize or
package the app for public distribution. The MIT license is copied into the app’s
resources.

The app remembers divider positions, columns, sort order, Fast mode, and recent
folders. To reset this local state:

```sh
make reset
```

## Tests

```sh
make test           # both packages, then the app tests; stops on failure
make test-packages  # ScanCore and TreemapLayout tests only
make test-app       # AppKit app tests only
```

The packages can also be tested directly:

```sh
swift test --package-path Packages/ScanCore
swift test --package-path Packages/TreemapLayout
```

The app test command is:

```sh
xcodebuild test -project MacDirStat.xcodeproj -scheme MacDirStat-CI \
  -testPlan CI -destination 'platform=macOS' -derivedDataPath .build/xcode
```

## Repository structure

| Path | Purpose |
| --- | --- |
| `MacDirStat.xcodeproj` | macOS app and app test targets |
| `App/MacDirStat` | Programmatic AppKit interface and lifecycle |
| `App/MacDirStatTests` | Workspace, selection, inspector, and treemap tests |
| `Packages/ScanCore` | Traversal, aggregation, hard-link accounting, cancellation, progress, and errors |
| `Packages/TreemapLayout` | Squarified layout, hit testing, and small-item aggregation |
| `TestPlans/CI.xctestplan` | App test plan |
| `Makefile` | Build, launch, test, and cleanup tasks |

Both packages import Foundation without AppKit, SwiftUI, or CoreGraphics. They
own their geometry types and can be tested without launching the app.

## From scan to screen

The scan engine builds a private tree on its scan task. During a scan, the UI
receives scalar progress: bytes, counts, elapsed time, and the current path. At
the terminal event, the engine hands over one finished or cancelled result tree.
The tree is immutable after publication, and the UI uses it for the directory
list, inspector, and treemap. Treemap layout runs off the main thread.

Fast mode measures package contents without retaining their internal tree.
Hard-link contributions from packages are reconciled with the same per-scan
ownership index used for ordinary files.

[CONTEXT.md](../CONTEXT.md) defines the two size measures, byte attribution,
completeness, exclusions, and package behavior.

## Design history

[The original specification](../.plan/maps/macos-disk-visualizer/spec.md) records
the design history. It is a record, not a contract: decisions at its top
supersede the body wherever they disagree.
