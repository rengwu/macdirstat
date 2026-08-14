---
type: grilling
blocked_by: []
undermined_by: []
---

# Settle filesystem and scan semantics

## Question

What exactly counts as content beneath a selected folder or mounted drive in the first version? Settle the reported size measure, treatment of hidden files, symbolic links, hard links, macOS packages, volume boundaries, unreadable paths, filesystem metadata, and partial results after cancellation or recoverable errors. The choices must preserve a read-only scan and avoid loops or misleading double-counting.

## Done when

The ticket records an unambiguous rule for every listed filesystem case, identifies what the UI reports when content cannot be read, and provides representative examples that an implementation and its tests can apply without further product judgment.

## Answer

The scan represents the ordinary logical length of locally present file content. Rectangle area and directory totals use that measure; extended attributes, resource forks, filesystem metadata, sparse-file allocation, compression savings, and APFS shared-clone allocation are excluded. Sizes use binary IEC units (KiB, MiB, GiB, TiB), with exact byte counts available in item details. This intentionally favors a cheap, consistent, performant content-size view over an estimate of physical blocks consumed.

One scan has exactly one selected root. Eligible roots are folders or volumes on internal storage or directly attached physical storage such as USB or Thunderbolt SSDs and hard disks. Network volumes, cloud-provider roots, mounted disk images, and nested mounted volumes are outside the scan scope. Traversal stays on the root's filesystem device.

Hidden files and directories are included. Symbolic links are displayed as links but never followed; they receive no attributed content bytes. Finder aliases that are ordinary files remain ordinary files.

Hard links are deduplicated by filesystem identity within the scan. If any path for an inode occurs beneath the selected root, the first in-scope path encountered owns its logical bytes. Later in-scope paths remain visible with zero attributed bytes, a “Hard link—counted elsewhere” marker, and a reference to the owning path when available. The scanner does not search outside the root for other names of the inode. APFS clones are not deduplicated because inexpensive metadata does not provide exact shared-block attribution; each clone contributes its ordinary logical length.

macOS packages are measured by enumerating their descendants during the initial scan so their aggregate is accurate. They initially appear as one collapsed package item and one treemap box. The UI need not materialize the package's detailed child hierarchy until the user expands or selects it; that implementation choice must not change the already measured aggregate.

Cloud or file-provider items are included only when their contents are already materialized on local storage. Scanning must not initiate a download or network request. Remote-only placeholders are omitted. Omitted cloud or network content does not appear in the directory tree or treemap, but the completed or partial scan reports how many entries were excluded.

Permission failures, disappearing files, malformed metadata, and other recoverable filesystem errors do not fail the overall scan. An unreadable entry remains visible where possible, its size is not guessed, and it is marked “Unreadable.” Every affected ancestor is marked “Incomplete,” and the scan exposes an error summary. For a whole-volume scan, capacity and free space may be shown separately, but no synthetic “Unknown” byte count may be derived by subtracting logical totals from physical volume usage.

Cancellation stops traversal promptly and retains everything already discovered. The tree and treemap remain usable for read-only selection, Open, and Reveal operations, with an unmistakable “Incomplete—scan cancelled” state and a way to start a fresh scan.

The filesystem may change during traversal. Results are therefore a best-effort point-in-time view rather than a snapshot: entries that vanish become recoverable errors, new or changed entries need not be discovered consistently, and the app does not restart automatically. Users explicitly rescan when they need a refreshed view.

Representative acceptance cases are:

- A hidden 2 GiB file contributes 2 GiB and appears normally.
- A symbolic link to a 2 GiB file contributes zero content bytes and is not traversed.
- Two hard-link paths under the root contribute the file's logical bytes once; a hard-link path outside the root is neither sought nor displayed.
- A package containing 500 MiB of descendants contributes 500 MiB while initially occupying one box.
- A locally downloaded 100 MiB cloud file contributes 100 MiB; a remote-only neighbor is omitted and increments the exclusion count without being downloaded.
- An unreadable child does not abort sibling traversal; its ancestors and final result are incomplete rather than falsely reported as exact.
- Cancelling after some entries are aggregated leaves those partial results visible and labelled incomplete.
