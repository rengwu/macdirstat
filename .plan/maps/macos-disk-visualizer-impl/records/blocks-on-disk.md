# Blocks on disk, on a real volume (ticket 16)

The field run that closes ticket 16: the shipped engine, measuring what ticket 13 decided
it should measure, pointed at `/` on the machine whose numbers made the case.

**Machine.** Apple M1 Pro, 16 GB, APFS on internal NVMe, macOS 27.0 (26A5368g),
Swift 6.3.3 / Xcode 26.6, Release (`-c release`), no sanitizers, full disk access granted.
**Not the §8.1 reference machine** (M1 / 8 GB) — the same caveat ticket 10's record carries.

## The scan

`/`, volume-root mode, production `FileManagerDirectoryProbe`. Two runs, minutes apart —
the second only to capture which directories could not be read. They are quoted together
because their agreement is worth as much as either number: 0.02% apart on a live volume.

| | Run 1 | Run 2 |
| --- | --- | --- |
| Blocks on disk | **344.16 GiB** | **344.24 GiB** |
| Content length | **1,817.97 GiB** | **1,818.05 GiB** |
| Ratio | **0.189** | 0.189 |
| Files | 2,915,958 | 2,917,398 |
| Elapsed | 579 s | 594 s |
| Peak physical footprint | 945 MB | 1,118 MB |
| Result | Incomplete — 261 unreadable directories | the same 261 |
| Exclusions | 8,893 remote-only cloud · 33 repeated directory · 9 crossed volume boundary | identical |

The exact figure from run 1 is 369,536,655,360 bytes on disk against 1,952,026,509,474 of
content length.

The top level, both measures side by side, is the whole ticket in one table:

| | On disk | Content length |
| --- | --- | --- |
| `Users` | **263.10 GiB** | 1,724.34 GiB |
| `Applications` | 27.66 GiB | 32.92 GiB |
| `private` | 21.93 GiB | 21.85 GiB |
| `System` | 18.65 GiB | 23.78 GiB |
| `Library` | 9.97 GiB | 11.71 GiB |

`Users` is the case ticket 13 was opened on: a terabyte and a half of it does not exist.
`private` is the one place length runs *under* blocks, because it is thousands of small
files paying block slack. `System` reads 27% larger by length than by blocks, which is
macOS compressing its own binaries.

## The reconciliation, and why it reads −10% rather than −0.3%

The volume reports **383.91 GiB used**; the scan counted 344.16 GiB. That is −10.36%, not
the "within a few percent" ticket 16 expected, and the difference is not error — it is
what `volumeAvailableCapacityKey` means on APFS.

`diskutil apfs list` for this container:

| Volume | Consumed | Reachable from `/`? |
| --- | --- | --- |
| Macintosh HD (system) | 25.1 GB | yes |
| Macintosh HD — Data | 356.6 GB | yes, through the firmlinks |
| Preboot | 23.1 GB | **no** — its own volume |
| Recovery | 3.0 GB | **no** — its own volume |
| VM | 3.2 GB | **no** — its own volume |
| **Total** | **412.2 GB = 383.9 GiB** | |

The used figure is **container-wide**: capacity and free space on APFS are properties of
the container, so every sibling volume's blocks are inside the denominator while §3.3
keeps them outside the numerator — correctly, and the scan records 9
`crossedVolumeBoundary` exclusions saying so.

Against the two volumes a scan of `/` can actually reach — 381.7 GB = 355.5 GiB — the
counted total is **−3.2%**. The remaining 11 GiB has two known parts, both pulling the
same way: three `com.apple.os.update-*` local snapshots hold blocks no filesystem walk can
reach, and 261 directories could not be read.

The 261 unreadable directories, by where they are:

| | |
| --- | --- |
| `private/var/…` | 177 |
| `System/Library/…` | 64 |
| `Library/Application Support`, `Library/Caches` | 11 |
| `Users/rengwu/…` | 4 |
| everything else | 5 |

Sampling `/private/var` two levels deep finds the shape of all of them: `/private/var/root`,
`/private/var/audit`, `/private/var/install`, `/private/var/ma`, `/private/var/jabberd` —
owned by `root` or a service account, mode `0700` or `0750`. This process had full disk
access and was not running as root, which is the ordinary case for a user scanning their
own machine. None of them is large, so they are not where the missing gigabytes are; what
they cost is the honest `Incomplete` on the result, which is the point of having it.

**This does not change the decision, and it does change how the line reads.** Ticket 13
wrote "333 GB counted · 332 GB used" from a scan of `/System/Volumes/Data`, where the root
*is* one volume and the agreement was 0.3%. A scan of `/` is structurally a few percent
below its denominator on any Mac with Preboot, Recovery and a VM volume. The line is still
worth showing — it is the only place the picture is checked against something outside
itself — but "counted below used" is the normal reading for a `/` scan, not a warning.
Recorded here rather than papered over; ticket 16's answer flags it.

## The progress rules, observed

- The fraction rose to **0.8964** and never higher. No snapshot of a running scan reported
  1.0, and none was withdrawn — this scan never passed volume-used.
- Throughput settled at **~6,000 items/s**, steady across the run. The old
  bytes-per-second reading on this machine was 2.91 GiB/s, which no disk here can do.

## Memory

945 MB peak against ticket 12's 695 MB on a scan of the same volume, and against the 8 GiB
ceiling of §8.4. Two extra `Int64` per node at ~3.6 M nodes is ~58 MB of that; the rest is
not accounted for here, and this is not a controlled comparison — different build,
different measure, a volume that keeps moving under both.

The controlled figure is the Large rung, re-run for this ticket and rewritten into
`performance-record.json`: **2,000,000 entries, peak 0.401 GiB, 86.8 bytes per entry**
against the same 8 GiB ceiling. That is *lower* than the 108 bytes per entry the previous
record held, which is not evidence that four `Int64` are cheaper than two — it is the
record's own warning being right. `footprintDeltaBytes` is a lower bound on a rung's cost
because every rung shares one host process with the ones before it, and the +16 bytes per
node this ticket costs is smaller than the spread that produces. The number worth reading
is the ceiling, and every rung is an order of magnitude under it.
