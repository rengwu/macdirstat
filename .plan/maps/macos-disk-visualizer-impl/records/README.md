# Performance & scale records

`performance-record.json` is what `MacDirStatPerformanceTests` wrote the last time
somebody ran the full ladder. It is the artefact spec §9.1 asks a pre-release-candidate
run to leave behind: the machine, the build, the generator version and seed, and for each
rung its entry count, logical bytes, operation counts, peak physical footprint, terminal
state and diagnostic elapsed time.

## Regenerating it

The performance plan has two configurations. The default one runs Smoke and the cheap
stress shapes in a few seconds and writes its record to a temporary directory —
`Scripts/verify-scaffold.sh` runs that one, so the local gate stays fast and the working
tree stays clean.

The opt-in one climbs the whole ladder and writes here:

```sh
xcodebuild test -project MacDirStat.xcodeproj -scheme MacDirStat-Performance \
  -configuration Release -destination 'platform=macOS' \
  -only-test-configuration 'Release, all rungs'
```

Release, no sanitizers, on the reference machine of §8.1 (Apple Silicon M1, 8 GB, NVMe).
The record says in `isReferenceMachine` and `referenceMachineNote` whether the run it
holds was actually taken there; a run on anything else is still worth keeping and is
still held to the same 8 GiB ceiling, but it is not the run the bar was written against.

## The real-filesystem soak

The `-materialized` rungs are written to a real disk as sparse files and scanned through
the production `FileManagerDirectoryProbe`, which is the only path in the suite that pays
Foundation's per-entry cost. It is off unless the staging directory exists:

```sh
mkdir -p .performance-fixture   # gitignored; must be empty
```

The builder refuses a directory that is missing, occupied, or one of the places nothing
should ever be staged, and removes only a tree whose sentinel it recognises.

## The visited-directory guard

Two rungs come in a pair: `representative` and `representative-no-directory-identities`.
They are the same 400,000 entries, generated identically, differing only in whether each
directory entry carries a `fileResourceIdentifier` — so the difference between their peak
footprints is what the guard that stops a scan of `/` counting the disk twice costs in
memory (ticket 12). The control runs **first** on purpose: both share one host process, so
a cost that is real has to exceed the arena the earlier rung already grew.

`smoke-with-repeated-directories` is the correctness half of the same subject: four names
repeating the identity of directories the walk has already opened, each of which really
does hand back its subtree if anything lists it.

## The within-directory sort

`sort-cost.md` is a prose record rather than a rung: what the sort at the end of every
directory listing costs, measured on two real directory-heavy trees before and after
ticket 15 changed the comparator, plus the comparator timed on its own over five name
mixes. It is written by hand from what
`MacDirStatPerformanceTests/DirectorySortCostTests` prints, because the half that
matters most reads a real tree the harness did not build and so cannot run unattended.

## The treemap's relayout cost

Three things ticket 14 added, all at the Large rung and all at 2,560×1,600:

- **`treemapPlacedNodeCount` beside `treemapPreparedChildCount`** on every `-with-treemap`
  rung. The first is how many entries have a rectangle to lose; the second is how many the
  layout actually read. They used to be the same number, because the engine materialized a
  parallel tree of class instances before placing anything. The pair is the cost claim:
  the work follows the picture, so the same tree at 640×400 reads a fraction of what it
  reads at 2,560×1,600.
- **`large-treemap-layout-pass`** measures one layout's own peak footprint, sampled around
  the pass rather than around the scan, so the transient allocation is visible instead of
  folded into the scan's figure.
- **`large-treemap-main-thread`** is the freeze itself, measured: the longest the main
  actor was ever unable to run while layouts happened in the background, beside the same
  measurement taken while one layout ran inline. The second is the control — an instrument
  that cannot see a main-thread layout would prove nothing about its absence.

## Reading the columns

`measurementNotes` in the JSON says what each number means and, more importantly, which
of them cannot be read at face value — in particular `footprintDeltaBytes`, which is a
lower bound on a rung's cost rather than the cost, because every rung shares one host
process with the others.
