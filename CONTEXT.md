# Domain language

The words this project uses for the things it measures. If two of these can be swapped in
a sentence without changing its meaning, one of them is being used wrongly.

## Measures

**On-disk size** — the blocks an entry actually occupies. The measure: it drives the
treemap's area, the tree's Size column, share-of-parent, and every total the app reports.
When the app says "size" without qualification, it means this.

**Content length** — how many bytes an entry's content *is*, which is what copying it
elsewhere would cost. Carried beside on-disk size and rolled up the same way, but drives
nothing on screen. It explains the visible figure where the two diverge: a sparse VM image
is 1 TiB of content length occupying 34.6 GiB, and a cloud placeholder is content length
occupying nothing.

The two are equal for most files and wildly unequal for the ones a user goes looking for.
Never write "size" where the distinction matters.

## Counting

**Attributed** — bytes a node is charged with. An entry that exists but is charged nothing
is *weightless*, not absent: it keeps its row, its name and its place in the tree, and only
its rectangle is missing. The second name of a hard link, a re-entered directory and a
cloud placeholder are all weightless.

**Owner** — of two paths that reach the same bytes, the one charged for them. Ownership
falls to the first path a scan reaches under its within-directory name order, which is why
that order has to be identical on two machines holding the same tree.

**Exclusion** — something a policy chose not to count: a crossed volume boundary, a
remote-only placeholder, a directory reached by a second path. An exclusion is **not an
error**. Nothing went wrong, ancestors stay Complete, and the result stays Exact.

**Error** — something that could not be read. Errors, and only errors, make a total a
floor rather than a figure.

## States

**Complete / Incomplete** — whether everything beneath a node was read. Incomplete means
the number shown is a floor.

**Unreadable** — this entry itself could not be read. Its size is never guessed and never
substituted from the other measure.

**Exact / Incomplete (result)** — whether the scan as a whole read everything it set out
to. Cancelling makes a result Incomplete; excluding a mounted volume does not.

## Shapes

**Root** — the one folder or volume a scan was pointed at. One per scan.

**Package** — a directory macOS presents as a single item. A detailed scan measures
*through* it and retains its descendants. Fast mode instead measures those descendants in
one lightweight aggregate pass and retains only the package node. Both present one row and
one box; only a detailed package can be drilled into.

**Aggregate** — one treemap box standing in for many entries too small to draw. It reports
how many entries it folded. It is not a node and has no path, so it cannot be opened.
