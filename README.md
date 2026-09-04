# MacDirStat

A native macOS disk visualizer: scan one folder or volume, and read it as a
synchronized directory tree and a classic flat treemap. Read-only — the only
file actions are Open and Reveal.

## Layout

| Path | What it is |
| --- | --- |
| `MacDirStat.xcodeproj` | The app project: one macOS App target and one test target |
| `App/MacDirStat` | AppKit shell — programmatic lifecycle, no storyboard, not document-based |
| `App/MacDirStatTests` | The app's tests: formatting, status line, selection, inspector, treemap view |
| `Packages/ScanCore` | Foundation-only scan engine: traversal, aggregation, cancellation, progress, errors |
| `Packages/TreemapLayout` | Foundation-only rectangle layout: squarified geometry and the merge rule |
| `TestPlans/CI.xctestplan` | The one test plan |
| `Makefile` | Build, run and test tasks — `make help` lists them |

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

Deployment floor: **macOS 14**.

## Building and running

`make` wraps the `xcodebuild` invocations; `make help` lists every target.
Everything builds into `.build/xcode`, which is gitignored.

```sh
make run      # build the debug app and launch it
make rerun    # quit a running instance, rebuild, launch again
make console  # launch in the terminal with its console output attached
make stop     # quit a running instance
make release  # build the release app
```

The window remembers its dividers, column layout, sort order, Fast mode and
recent folders between launches. To get a first run back:

```sh
make reset
```

## Running the tests

The packages test on their own, headlessly:

```sh
make test-packages
```

Everything, including the app target, runs sequentially so a package failure
cannot be hidden by a green app test result:

```sh
make test
```

The underlying commands, if you would rather run them directly:

```sh
swift test --package-path Packages/ScanCore
swift test --package-path Packages/TreemapLayout

xcodebuild test -project MacDirStat.xcodeproj -scheme MacDirStat-CI \
  -testPlan CI -destination 'platform=macOS'

xcodebuild build -project MacDirStat.xcodeproj -scheme MacDirStat \
  -configuration Release -destination 'platform=macOS'
```

## How a scan reaches the screen

The engine walks the tree on its own thread and **hands it over once**, with the
terminal event. While the scan runs, the window shows the progress card — bytes
counted, files, folders, elapsed, items per second, the folder being read, and a
percentage on volume scans — and the tree and treemap fill in when it finishes.

That is deliberate. The engine used to republish the tree several times a second
by copying the folders it was still working on and reusing the finished ones by
reference, and those reused nodes kept pointing up into the live tree the scan
thread was still writing to. The % column divided by a total that was still
moving, and a selection held across a republish could outlive the copy it came
from. One tree makes both impossible rather than fixed.

## What the two size figures mean

**On-disk size** is the blocks an entry occupies, and it is the measure: it
drives the treemap's area, the Size column and every total. **Content length** is
how many bytes the content is; it is carried beside on-disk size and drives
nothing, so the inspector can explain the visible figure where the two diverge —
a sparse disk image, a compressed binary, a cloud placeholder. `CONTEXT.md` has
the full vocabulary.

The source chooser and folder picker also offer **Fast mode**. macOS does not
publish a reliable recursive size for directories, so the scanner still visits
the files inside an application bundle, but it requests only size metadata and
keeps the bundle as one aggregate node. It avoids sorting and materializing the
often enormous internal app tree while retaining the app's measured total.

## Design record

`.plan/maps/macos-disk-visualizer/spec.md` is the original specification. It is a
record, not a contract: the decisions listed at the top of that file supersede
the body wherever the two disagree.
