---
type: task
blocked_by: [04, 05]
undermined_by: []
claimed_by: s3c7423cad14f
claimed_at: 2026-08-17T04:14:27Z
---

# The volume-boundary check re-enters the data volume, doubling every scan

## Question

A whole-volume scan of `/` counts every byte and every entry on the machine **twice**.
Found by running the app against `/` on an M1 Pro (2026-08-17): 3.78 TiB and 7.35 M files
reported against a 460 GiB disk holding 332 GiB and ~3.7 M inodes, with `Docker.raw`
appearing as two separate boxes in the treemap.

**Why it happens.** On APFS the system volume and the data volume are presented to users
as one volume, and macOS reports the **same** device identity for both:

```text
dev=16777230  /
dev=16777230  /System/Volumes/Data
```

`ScanSession.isOnRootVolume` (`ScanSession.swift:353`) compares
`volumeIdentifierKey` against the root's, so it sees no boundary and descends into
`/System/Volumes/Data`. That directory is the data volume's root, and its children are the
*same directories* already reached from `/` through firmlinks — same device, same inode:

```text
dev=16777230 ino=16741      /Users
dev=16777230 ino=16741      /System/Volumes/Data/Users
dev=16777230 ino=33720345   /Applications
dev=16777230 ino=33720345   /System/Volumes/Data/Applications
dev=16777230 ino=33720127   /private
dev=16777230 ino=33720127   /System/Volumes/Data/private
```

So the whole data volume is walked a second time. The traversal terminates — there is no
`/System/Volumes/Data/System/Volumes/Data`, so it is a doubling, not a loop — but it
doubles wall-clock time, doubles the node count, doubles the memory footprint, and makes
every reported total wrong.

**Why the hard-link index does not catch it.** These entries have a link count of 1, so
`HardLinkIndex.claim` returns `.notALink` before it ever consults the identity map
(`HardLinkIndex.swift:57`). The dedup mechanism ticket 04 built is aimed at multiply-linked
*files*; this is re-entry through a *directory*.

**The likely fix, for evaluation not for assumption.** A visited-directory identity set:
record `fileIdentity` for each directory as it is descended, and skip a directory whose
identity has already been descended. It is close to free — `fileResourceIdentifierKey` is
already in the probe's prefetch set (`FileManagerDirectoryProbe.swift:33`) and is populated
for directories, so no extra syscall is needed — and it is bounded by directory count, not
entry count (~1.4 M here). APFS has no hard-linked directories, so a repeated directory
identity is always re-entry and never a legitimate second name. It also generalizes: it
would catch any future graft, not just the one Apple ships today.

Weigh it against the alternatives before committing: skipping a hardcoded list of synthetic
mount points (`/System/Volumes/Data`, `/.vol`, `/dev`, `/home`, `/net`), which is brittle
and Apple-version-specific; or reading `statfs`'s `f_mntfromname` to distinguish mounts that
share a device identity, which is a second syscall per directory.

Decide, too, how the skipped re-entry is reported. It is not an error — nothing went wrong —
so on ticket 04's rule it is an **exclusion**, and the ancestors stay Complete and the
result Exact. Whether it deserves its own exclusion reason alongside `crossedVolumeBoundary`
is part of this ticket.

## Done when

- A scan of a root that is reachable by two paths on one device counts each entry once, and
  the tree contains one node per real directory.
- `ScanCoreFileSystemTests` covers it against the real filesystem: a fixture where one
  directory is reachable twice under the scan root produces one contribution, proven by
  totals and by node count, with a positive control that fails if the guard is removed.
- `ScanCoreTests` covers it headlessly through `ScriptedDirectoryProbe`, including the case
  where a directory identity cannot be read — which must descend, never skip, since omitting
  real bytes is the worse error (the rule `isOnRootVolume` already follows).
- The guard's memory cost is measured in the performance suite and recorded: it is
  proportional to directories descended, and the Large rung stays inside the 8 GiB ceiling.
- A real scan of `/` on the reference machine reports a total within a plausible distance of
  `df`'s used figure once ticket 13 has settled what is measured, and `Docker.raw` appears
  exactly once in the treemap.
- The chosen reporting for a skipped re-entry is implemented and asserted (exclusion, not
  error; ancestors stay Complete).

## Answer

A whole-volume scan no longer counts anything twice, and the bytes land on the paths a
person recognises. On this machine a scan of `/` now reports **1.78 TB across 2,914,241
files and 3,625,028 nodes** in 9 minutes at a 695 MB footprint, with `/Users` at 1.68 TB,
`Docker.raw` appearing **once**, and 33 skipped re-entries — against the field report's
3.78 TiB and 7.35 M files. `/System/Volumes/Data` is walked last and contributes the
11.4 MB in 83 nodes that exist only there. Fed through `TreemapLayout` at 2,560×1,600,
that tree lays out into 31,238 boxes with **one** `Docker.raw` rectangle, which is the
field report's two boxes answered on real data rather than on a fixture.

**What was built**

- **`VisitedDirectoryIndex`** — its own type, like `HardLinkIndex`, because the claim
  about it is a *memory* claim: one dictionary entry per directory **opened**, keyed by
  `fileResourceIdentifierKey`, which Apple documents as equal exactly for "the same file
  system item" and which the probe already prefetches, so the guard costs no extra
  syscall. Chosen over the two alternatives the ticket named: a hardcoded list of Apple's
  synthetic mounts is brittle and version-specific, and `statfs`'s `f_mntfromname` is a
  second syscall per directory. An identity set also generalises — it caught a *second*
  re-entry path nobody knew about (below).
- **`ExclusionReason.repeatedDirectory`** and **`Attribution.directoryCountedElsewhere(owner:)`**
  — the reporting. It is an exclusion, never an error: ancestors stay Complete, the result
  stays Exact. The second name stays visible and weightless with the owning path attached,
  which is the rule the engine already applies to a second name for a hard-linked inode;
  removing it would be the dishonest answer, since the directory really is at that path.
  The inspector shows it as a note, beside the hard-link one.
- **A fourth requirement on the probe seam, `mountPointPaths()`** — one
  `getmntinfo_r_np(3)` per scan (the `_r_np` variant: plain `getmntinfo` answers out of a
  process-wide static buffer two scans would race on). Both source-text guards that pin
  the seam's width were updated deliberately, which is what they are for.
- **Two ordering rules in the traversal**, because when one directory has two paths, which
  path keeps it is a presentation decision: a **mount point inside the root's own volume is
  opened last of all**, and a **hidden subdirectory is opened after its visible siblings**.
  The identity check moved to the moment a directory is *opened* rather than the moment it
  is met, so a held-back directory takes its verdict at its real arrival.
- **Tests**: 15 in a new `RepeatedDirectoryTests` (scripted, including the positive control
  where the same fixture doubles with the guard off), 5 in a new `RepeatedDirectoryProofTests`
  (real filesystem), a `smoke-with-repeated-directories` rung with four real grafts, and a
  memory measurement of the guard. **153 tests in the two packages**, 53 in `MacDirStatTests`.

**Three judgment calls**

1. **A mount point is never offered to the index.** `/` and `/System/Volumes/Data` report
   the **same file identity** (inode 2) and the same volume identifier while being two
   different directories: the second holds `.Spotlight-V100`, `.DocumentRevisions-V100`,
   `.fseventsd`, `MobileSoftwareUpdate`, `mnt` and `sw`, which are reachable nowhere else.
   Identity alone would therefore skip the data volume's root wholesale and silently lose
   them — a fix that swaps a double count for an under-count. The mount table is the one
   fact that tells the two roots apart, so a mount point is walked (last), never skipped.
   Where no mount table is available — every scripted probe, and any host that could not
   read one — the guard falls back to identity alone: still nothing counted twice, but a
   second volume root is skipped whole. That is asserted, with the loss named in the test.
2. **Hidden subdirectories are opened after their visible siblings.** Found by running the
   thing: the first working version of this fix attributed **all 1.78 TB to `/.nofollow`**,
   a synthetic alias of the whole filesystem macOS hangs off the volume root — not a mount
   point, its own identity synthetic, and a dot sorts before every letter, so it reached
   every directory first and `/Users` came out empty. `/.vol` and `/.resolve` are the same
   shape. Deferring hidden directories fixes the whole family without naming any of them.
   It changes descent order only: the tree keeps its listing order, and nothing about what
   is counted moves.
3. **An identity that cannot be read descends**, exactly as `isOnRootVolume` already does
   for an unknown volume: omitting real bytes is the worse error. Asserted headlessly.

**What the guard costs**, from the regenerated record (Release, full ladder, this
machine): the Large rung peaks at **332.6 MiB** against the 8 GiB ceiling with its 200,000
directories indexed, and the paired rungs — `representative` against
`representative-no-directory-identities`, identical but for whether a directory carries an
identity — differ by **0.1 MiB across 40,000 directories**, under 3 bytes each. That is an
upper bound rather than a precise figure, because the second rung runs in an arena the
first already grew; the test says so and the record's notes say so. The real `/` scan is
the figure with no such caveat: 695 MB for 3.6 M nodes and ~578,000 directories indexed.

**Measured, not assumed** (M1 Pro, 2026-08-17, unsandboxed Release CLI over the real `/`):
`/Users` and `/System/Volumes/Data/Users` really do report one identity and one volume
identifier, with `linkCount == 1` — so `HardLinkIndex.claim` answers `.notALink` without
consulting its map, which is why the existing dedup could not have caught this. Both facts
are now tests. The guard also *terminates* a scan that would otherwise not: `/.nofollow`
contains `/.nofollow`.

**The full gate is green.** `Scripts/verify-scaffold.sh` reports PASS on all twelve steps:
both packages (153 + 71 tests), `MacDirStatTests` 53/53 under the CI plan *and* under
Thread Sanitizer, `MacDirStatUITests` 9 (5 skipped by the compatibility policy), the
universal Release build, the other three plans, the full performance ladder, and every
guard script. The UI-test runner had refused to start earlier in this session —
`LocalAuthentication Code=-4 "System authentication is running."`, reproduced on a
stashed pristine tree, so never this work — and it started once the machine's pending
authentication cleared.

**Omitted deliberately**

- **The `df` comparison stays open**, exactly as the ticket says it must: 1.78 TB is
  logical bytes against 385 GB of used space, and that gap is a 1 TiB sparse `Docker.raw`
  occupying 34.6 GiB. Ticket 13 owns what is measured; nothing here changes it.
- **No app-level test for the inspector's new note.** `ScanPresentationModel` builds its
  own `FileManagerDirectoryProbe`, and `ScanNode` is not constructible outside `ScanCore`,
  so the app's harness can only scan trees a real filesystem can stage — and no
  unprivileged API grafts a directory. The engine-level attribution is covered both ways.
- **The performance record was regenerated here, not on the reference machine** (§8.1's
  M1/8 GB), which the record says of itself, as the map already notes for every number on
  file.
