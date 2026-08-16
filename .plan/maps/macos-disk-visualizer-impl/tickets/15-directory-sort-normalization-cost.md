---
type: task
blocked_by: [03]
undermined_by: []
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
