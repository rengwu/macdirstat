# MacDirStat

**See what’s taking up space on your Mac.**

MacDirStat is a native macOS disk visualizer with a directory tree and a classic
flat treemap. Pick a folder or disk, scan it, and select a rectangle to find the
file behind it. It’s free, open source, and read-only.

![MacDirStat showing a directory tree, a treemap colored by file type, and details for a selected video](docs/images/macdirstat.png)

*The app scanning sample files. Rectangle area represents on-disk size.*

[Get started](#get-started) · [Releases](https://github.com/rengwu/macdirstat/releases) · [Report a bug](https://github.com/rengwu/macdirstat/issues) · [MIT license](LICENSE)

## What it does

- **Find large files visually.** The tree and treemap share one selection; the
  detail pane shows the selected item’s size, path, and share of its folder.
- **Scan local folders and disks.** Hidden files are included. Network volumes
  aren’t supported.
- **Keep app bundles compact.** Fast mode measures their contents but shows each
  package as one item. Turn it off before scanning to browse inside packages.
- **Stop a scan and explore what it found.** Cancelled scans retain their partial
  results, with totals marked as lower bounds.
- **Open or reveal a file in Finder.** MacDirStat has no delete, move, or cleanup
  actions.

## Get started

**Requires macOS 14 Sonoma or later. Builds for Apple Silicon and Intel Macs.**

There is no packaged download yet. Developer ID signing and notarization are
still pending; for now, build from source. Packaged downloads will appear on the
[Releases page](https://github.com/rengwu/macdirstat/releases).

### Build and install

Building requires the **full Xcode app**, including its macOS SDK. The standalone
Command Line Tools are not enough to build and test the app. You do not need a
paid Apple Developer account for a local build.

1. Install Xcode and open it once to finish setup. If needed, select it with
   `sudo xcode-select -s /Applications/Xcode.app`.
2. Clone the repository and build:

   ```sh
   git clone https://github.com/rengwu/macdirstat.git
   cd macdirstat
   make release
   ```

3. Open the build folder:

   ```sh
   open .build/xcode/Build/Products/Release
   ```

4. Drag **MacDirStat.app** to **Applications**, then launch it.

To run directly from a development checkout, use `make run`.

## Your first scan

1. Click **Choose…**, or press **⌘O**.
2. Select a disk, or use **Choose Folder…** to add a folder.
3. Choose whether to use **Fast mode**, then click **Search**.
4. Watch the progress card while the scan runs. The tree and treemap appear when
   it finishes; **Cancel** stops early and keeps what was found.
5. Select a file in the tree or treemap to inspect it. Expand folders in the tree
   to browse, or use **Reveal in Finder** to locate the selected item.

| Shortcut | Action |
| --- | --- |
| ⌘O | Choose a folder or disk to scan |
| ⌘R | Reveal the selected item in Finder |
| ⌥⌘C | Copy the selected item’s path |
| ⌘D | Show or hide the detail pane |

### Reading the sizes

**On-disk size** drives rectangle area and the Size column. **Content length**
is the file’s logical length; the detail pane shows it when the displayed figures
differ, such as for sparse files or compressed files. Sizes use binary units
(KiB, MiB, GiB).

A scan with unreadable entries is marked **Incomplete**: its totals are lower
bounds. The result describes the files the scan could measure, rather than a
promise of how much space deleting them would recover. Fast mode retains measured
package totals without keeping their internal file trees.

## Privacy

MacDirStat scans filesystem metadata locally, without reading file contents.
There are no accounts, analytics, or scan uploads. Opening a selected file hands
it to its default application through macOS.

Scan results are held in memory and are not saved between launches. The app saves
window settings, scan preferences, and recent folder paths locally. Clear recent
paths with **File → Open Recent → Clear Menu**.

## Feedback and bugs

[Open an issue](https://github.com/rengwu/macdirstat/issues) with the app version,
your macOS version, whether your Mac uses Apple Silicon or Intel, and the steps
to reproduce the problem. For scan issues, include whether Fast mode was enabled
and whether you scanned a folder, internal disk, or external disk. A small sample
folder that reproduces the issue is especially useful.

Screenshots can include filenames and paths; remove any private details before
sharing them.

## Development

Built with Swift and AppKit. The scan engine and treemap layout are separate
Foundation-only packages with no third-party package dependencies.

See [the development guide](docs/DEVELOPING.md) for build commands, tests, and
repository structure, or [CONTEXT.md](CONTEXT.md) for measurement terminology.

## License

[MIT](LICENSE) — Copyright (c) 2026 John Goh.
