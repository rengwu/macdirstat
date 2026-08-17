---
type: task
blocked_by: [03]
undermined_by: []
claimed_by: s77b69b0388cf
claimed_at: 2026-08-17T05:45:01Z
---

# The within-directory sort pays Unicode normalization on every comparison

## Question

Scanning a tree full of small directories — `node_modules` being the standard case — is
much slower than the syscall cost accounts for. `sample(1)` on the scan thread during a
whole-volume run showed it inside `_StringGutsSlice._slowCompare` →
`Unicode._NFDNormalizer._resume` → `Unicode._NFCNormalizer._resume`.

The source is `ScanSession.traverse`:

```swift
entries.sort { $0.name < $1.name }        // ScanSession.swift:173
```

Swift's `String <` orders by **Unicode canonical equivalence**, so each comparison
normalizes both operands. That is correct, locale-independent and deterministic — which is
what ticket 03 needed, since hard-link ownership depends on the order being the same on
every machine — but it is far more work than the requirement asks for. The cost is paid
`k log k` times per directory across roughly 1.4 M directories.

The neighbouring package already made this exact call the other way and wrote down why:
`PreparedTree.precedes` compares Unicode scalars explicitly rather than with `String <`
(`PreparedTree.swift:82-90`), noting that both are locale-independent and stable but only
one of them is what the spec says. The scanner did not get the same treatment.

**The order is load-bearing, so this is not a free swap.** Changing the comparator changes
which of two multiply-linked names owns an inode whenever their names differ only in
normalization — a real, if rare, difference in output. It also has to stay stable across
machines and across runs. So the ticket is: pick a cheaper comparator that keeps every
guarantee ticket 03 relies on, and say what changed.

Worth measuring before committing to a fix — the sample proves the frames are hot, not what
fraction of wall-clock they own. If the sort turns out to be a small share next to the
`contentsOfDirectory` prefetch, that is a finding worth recording and the ticket can close
having measured rather than changed.

## Done when

- The share of scan wall-clock spent in the within-directory sort is measured on a
  directory-heavy real tree and recorded, before and after any change.
- If a comparator change is made: it is locale-independent, deterministic across machines
  and runs, and the effect on hard-link ownership for names differing only in normalization
  is stated explicitly and covered by a test.
- The two packages agree, or the difference between the scanner's order and
  `PreparedTree.precedes` is documented at both sites with the reason.
- `ScanCoreTests`' existing determinism and ownership tests pass unchanged, and the
  performance suite's operation counts do not regress.

## Answer

Measured first, and the measurement says the sort was never the bottleneck. It changed
anyway, for a different reason the measurement exposed: **the old comparator did not order
these names at all — it tied them, and let the filesystem break the tie.**

### What it costs

Two real directory-heavy trees, scanned warm through the production probe, with `list` and
the sort timed separately (one comparator per pass — timing several inside one listing
charges the first for the cache misses the others then avoid, which is how an early run of
this ranked the two backwards). Full record, method and machine:
[`records/sort-cost.md`](../records/sort-cost.md).

| Tree | Sort, `String <` | Sort, code-point | `list` |
| --- | --- | --- | --- |
| `/System/Library` — 447,367 entries in 156,701 directories, 56.5 s | 0.86 s = **1.50 %** | 0.39 s = **0.67 %** | **93.2 %** |
| a `node_modules` tree — 22,985 entries in 1,668 directories, 3.1 s | 0.065 s = **2.0 %** | 0.028 s = **0.86 %** | **95.0 %** |

Listing is 93–95 % of a scan. The new comparator is 2.2–2.4× cheaper, and that saving is
invisible end to end: the plain scan went 56.48 s → 56.85 s on `/System/Library` and
3.14 s → 3.10 s on the `node_modules` tree, which is run-to-run spread, not an improvement.
**Nobody should expect a scan of `/` to get faster from this.**

### Why it changed anyway

`String <` orders by canonical equivalence, so `"cafe\u{0301}.bin"` and `"caf\u{00E9}.bin"`
compare **equal in both directions**. A sort leaves tied elements where it found them, so
the order of those two names — and the hard-link owner that follows from it — was decided by
the order the filesystem happened to list them in. That is exactly the input ticket 03's
locale-independence argument was protecting against, still open by another door.
`ScanCore.NameOrder.precedes` compares Unicode scalars: locale-independent, identical on
every machine and every run, and a **total** order over distinct names.

**The effect on ownership, stated plainly.** For two names of one inode differing only in
normalization, the decomposed spelling now owns the bytes (`U+0065` before `U+00E9`) and the
precomposed one is `.hardLinkElsewhere` pointing at it — on every machine. Before, whichever
name the filesystem listed first owned them.
`NameOrderTests.test_hardLinkOwnershipBetweenTwoSpellingsOfOneNameDoesNotFollowListingOrder`
covers it, asserting over **UTF-8 bytes**: `String ==` is canonical equivalence too, and the
first draft of that test passed under both comparators because of it.

Elsewhere the orders differ only where composing would change the first scalar
(`"e\u{0301}clair"` precedes `"f"` by code point and follows it canonically). ASCII names —
`/System/Library` holds 18 non-ASCII in 447,367 — are unaffected, asserted exhaustively over
a name corpus and over the performance suite's synthetic mixes.

### The mechanism, because it is not what the ticket assumed

The field sample's NFD/NFC frames were not caused by names needing normalization.
`URL.lastPathComponent` returns a string whose UTF-8 is **not contiguous**, and canonical
comparison of a non-native string leaves its bitwise fast path for the normalizing one. On
natively stored strings the ranking reverses — canonical is 2.5–8.8× *faster* for ASCII — so
a micro-benchmark over string literals contradicts the in-scan measurement and both are
right about different strings. Decomposed non-ASCII names are the one case where canonical
comparison is slow on any representation: 10–11× the code-point comparison. The wider lead
this opens (every name a scan holds is non-native, and comparison is only one of the things
done to a name) is now a patch on the map; it is unmeasured and nothing depends on it.

### Both packages, and the app, now say the same thing

- `ScanSession.traverse` sorts with `NameOrder.precedes`, and `NameOrder`'s documentation
  names `PreparedTree.precedes` as the other site.
- `PreparedTree.precedes` names `NameOrder` back, and its **name-equality** test moved from
  `String !=` to scalar-wise: it claimed code-point order and then sent canonically
  equivalent names to the discovery-position tie-break, which is the same bug one level down.
- `WorkspaceViewController.sortedChildren` compares names with `NameOrder` too (`public` for
  that), so a tree row and the treemap box it shares a selection with cannot disagree about
  which of two siblings comes first.

### Verification

`Scripts/verify-scaffold.sh` exits 0 with every step PASS. 160 tests in the ScanCore package
(6 new in `ScanCoreTests`, 1 new in `ScanCoreFileSystemTests`), 72 in `TreemapLayoutTests`
(1 new); the two scan-level tests and the treemap one were each confirmed to fail against
the old comparator before being kept. Operation counts in the performance suite are
unchanged — a comparator moves no syscalls. `DirectorySortCostTests` is new in
`MacDirStatPerformanceTests`: the comparator half runs always, the share-of-a-real-scan half
reads a tree named by `MACDIRSTAT_SORT_COST_TREE` and skips without one.

### Omitted deliberately

- **No wall-clock assertion anywhere.** §8.2 commits algorithmic and memory bars only, so
  every number here prints as `[diagnostic]` and is transcribed into the record by hand.
- **No real-filesystem proof of the pair being ordered.** A case-insensitive APFS volume is
  normalization-insensitive too, so this Mac cannot hold both spellings at once; the new
  filesystem test creates the pair, discovers which kind of volume it is on, asserts what
  that kind implies, and prints which one it was — rather than passing quietly on a machine
  where the interesting case cannot exist.
- **Copying names into native storage** — the bigger cost this uncovered — is left to the
  map as an unmeasured patch, since it is a per-entry allocation in the probe and belongs
  with ticket 05's adapter, not here.
