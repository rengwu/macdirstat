# The within-directory sort: what it costs, before and after (ticket 15)

A `sample(1)` taken on the scan thread during a whole-volume run showed
`_StringGutsSlice._slowCompare` → `Unicode._NFDNormalizer._resume` →
`Unicode._NFCNormalizer._resume`, under `ScanSession.traverse`'s
`entries.sort { $0.name < $1.name }`. A sample proves frames are *hot*; it does not
say what share of the run they own. This is the measurement, and what changed after it.

**Machine.** Apple M1 Pro, 16 GB, APFS on internal NVMe, macOS 27.0 (26A5368g),
Swift 6.3.3 / Xcode 26.6, Release (`-c release`), no sanitizers. **Not the §8.1
reference machine** (M1 / 8 GB), same as ticket 10's record — the numbers here are
ratios within one machine's run, which is what the question needs, but an absolute
wall-clock figure from this file is not a reference-machine figure.

## The share of a real scan

Two real directory-heavy trees, scanned through the production
`FileManagerDirectoryProbe`. Each scan is preceded by a full warm-up scan, so the
metadata cache is warm and the numbers are about CPU rather than about first-touch
I/O. `list` and the sort are timed separately by a probe decorator that times the
underlying listing, then sorts a private copy of the same entries — the copy made
before the stopwatch starts. **One comparator per scan pass**: timing several inside
one listing charges the first for every cache miss the others then avoid, and an
earlier run of this ranked the two comparators backwards for exactly that reason.

| Tree | Entries | Directories | Non-ASCII names |
| --- | --- | --- | --- |
| `/System/Library` | 447,367 | 156,701 | 18 |
| `~/Desktop/Projects/chartr` (`node_modules`) | 22,985 | 1,668 | 0 |

| Tree | Comparator | Sort | Share of scan | `list` share |
| --- | --- | --- | --- | --- |
| `/System/Library` | `String <` | 0.863 / 0.887 s | **1.50 / 1.47 %** | 93.2 / 93.1 % |
| `/System/Library` | code-point | 0.385 / 0.395 s | **0.67 / 0.65 %** | 93.2 % |
| `node_modules` tree | `String <` | 0.064–0.067 s | **1.99–2.06 %** | 95.0 % |
| `node_modules` tree | code-point | 0.027–0.029 s | **0.85–0.90 %** | 94.9 % |

A third candidate was measured and dropped: comparing the `utf8` view lexicographically
gives the identical order and sat between the two (0.50 s = 0.85 % on `/System/Library`).
Scalars won on the numbers and on the fact that `PreparedTree.precedes` already compares
them, so the two packages could be made to agree by writing down one rule rather than two.

Both comparators are timed in every run — the probe sorts its own copy, so the figures
above do not depend on which comparator the scanner itself was compiled with. Paired
figures are the run before the change and the run after it, and they agree to within a
few per cent, which is what "the measurement is of the comparator, not of the build"
looks like.

What the change moved is the scan's own wall clock, and there it is invisible:

| Tree | Plain scan, `String <` in the scanner | Plain scan, code-point in the scanner |
| --- | --- | --- |
| `/System/Library` | 56.48 s | 56.85 s |
| `node_modules` tree | 3.14 s / 3.11 s | 3.10 s / 3.11 s |

**The sort was never the bottleneck.** Listing is 93–95 % of a scan's wall clock; the
sort is under 2 % of it before the change and under 1 % after. A 0.5 s saving on a 57 s
scan is smaller than the spread between two runs of the same build, and the table says
so rather than claiming an improvement it cannot see. The change was made for the total
order (see the ticket's answer), not for the 0.5 s.

## The comparator on its own

The same listings sorted repeatedly, best of seven, outside any scan
(`DirectorySortCostTests.test_theComparatorsAreTimedOverTheNameMixesARealVolumeHolds`
runs the synthetic half of this on every performance run).

| Name mix | `String <` | code-point | ratio |
| --- | --- | --- | --- |
| short ASCII (≤ 15 B), native strings | 0.0005 s | 0.0013 s | canonical **2.5× faster** |
| long ASCII (> 15 B), native strings | 0.0012 s | 0.0106 s | canonical **8.8× faster** |
| non-ASCII precomposed | 0.0022 s | 0.0016 s | code-point 1.4× faster |
| non-ASCII **decomposed** | 0.0175 s | 0.0015 s | code-point **11.4× faster** |
| CJK | 0.0015 s | 0.0020 s | canonical 1.3× faster |
| harvested names, as `URL.lastPathComponent` | 0.0404 s | 0.0068 s | code-point **5.9× faster** |
| the same names, copied into native strings | 0.0023 s | 0.0027 s | about equal |

**Why the two halves of this record disagree.** On strings Swift owns — the ones a
literal or a `String(decoding:)` produces — canonical comparison is the *faster* of
the two for ASCII names, because it compares raw bits. On the strings a scan actually
holds it is 5.9× slower, and those are the same names: the difference is only how they
are stored. `URL.lastPathComponent` hands back a string that is not natively contiguous
(`utf8.withContiguousStorageIfAvailable` returns `nil` for names of every length,
including the ≥ 16-byte ones where a native string would answer), and canonical
comparison of a non-native string leaves its fast path for the normalizing one. That
is what the field sample caught: not names that needed normalizing — a real volume is
essentially all-ASCII, 18 non-ASCII names in 447,367 — but a comparison that could not
prove they did not.

The decomposed row is the other half of it, and it is not hypothetical on a Mac: HFS+
stores names decomposed, so a volume migrated from it, a disk image, or a file
delivered by a tool that normalizes to NFD hands the scanner names where canonical
comparison costs 11× more than code-point order.

## Reproducing it

The synthetic comparator half runs with the performance plan and needs nothing:

```sh
xcodebuild test -project MacDirStat.xcodeproj -scheme MacDirStat-Performance \
  -configuration Release -destination 'platform=macOS' \
  -only-testing:MacDirStatPerformanceTests/DirectorySortCostTests
```

The share-of-a-real-scan half needs a real tree, and reads only:

```sh
TEST_RUNNER_MACDIRSTAT_SORT_COST_TREE=/System/Library xcodebuild test … \
  -only-testing:MacDirStatPerformanceTests/DirectorySortCostTests
```

The `TEST_RUNNER_` prefix is how `xcodebuild` hands an environment variable to the test
runner; without it the variable stays in the shell and the test skips. The committed
harness reproduces the numbers above: on the `node_modules` tree it reported 1.92–2.05 %
for `String <` against 0.81–0.86 % for code-point order.

Nothing in either half asserts on wall clock: §8.2 commits algorithmic and memory bars
only and explicitly refuses a throughput SLA, so the numbers are printed as
`[diagnostic]` and transcribed here.
