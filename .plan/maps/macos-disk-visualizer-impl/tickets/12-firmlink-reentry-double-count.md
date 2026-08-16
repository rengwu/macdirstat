---
type: task
blocked_by: [04, 05]
undermined_by: []
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
