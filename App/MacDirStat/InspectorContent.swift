import Foundation
import ScanCore
import TreemapLayout

/// Everything the inspector shows about one selection, as data.
///
/// The view renders this and decides nothing. That is what makes "the inspector
/// shows IEC **and** exact grouped bytes, the full path, the ticket-01 flags and
/// the aggregate summary" a unit test rather than a screenshot review.
struct InspectorContent: Equatable {
    struct Row: Equatable {
        var label: String
        var value: String
    }

    enum Severity: Equatable {
        case info
        case warning
        case error
    }

    struct Note: Equatable {
        var severity: Severity
        var glyph: String
        var title: String
        var detail: String
    }

    /// What the colour chip beside the title stands for.
    enum Swatch: Equatable {
        case kind(TreemapKindGroup)
        case directory
        case merged
    }

    var swatch: Swatch
    var title: String
    /// The kind line under the title: "Folder", "Package", "Image · Hidden"…
    var subtitle: String
    /// IEC, three significant figures — or "Unknown" for an unreadable entry,
    /// whose size is never guessed (spec §3.5).
    var sizeText: String
    /// The qualifier beside it: "total", "logical", "combined", "not guessed".
    var sizeCaption: String
    /// The same number again, exact and grouped. Both are required (§6.3): the
    /// IEC figure is readable, the exact one is checkable.
    var exactBytesText: String
    var rows: [Row]
    /// Absolute path, reconstructed from the parent chain. `nil` for an
    /// aggregate, which is not a file and has no path.
    var path: String?
    var notes: [Note]
    /// The first few folded entries, for an aggregate box.
    var sampleNames: [String] = []
    var additionalSampleCount: Int = 0
    /// Whether Open and Reveal apply. False for an aggregate — §7.2's "without
    /// inventing an individual node" means there is nothing to open.
    var showsActions: Bool
    var footnote: String?
}

/// The facts a selection has to be described against: where the scan is rooted,
/// what its total is, and the volume's capacity when there is one.
struct SelectionContext {
    var rootURL: URL
    var rootNode: ScanNode
    var totalBytes: Int64
    var volumeCapacity: VolumeCapacity?
    var isVolumeScan: Bool

    init(
        rootURL: URL,
        rootNode: ScanNode,
        volumeCapacity: VolumeCapacity? = nil,
        isVolumeScan: Bool = false
    ) {
        self.rootURL = rootURL
        self.rootNode = rootNode
        self.totalBytes = rootNode.subtreeDiskBytes
        self.volumeCapacity = volumeCapacity
        self.isVolumeScan = isVolumeScan
    }
}

/// Builds the inspector's content and the treemap's tooltip from one selection,
/// so the two can never disagree about what an item is.
struct InspectorContentBuilder {
    let formatter: DisplayFormatter

    init(formatter: DisplayFormatter = DisplayFormatter()) {
        self.formatter = formatter
    }

    // MARK: - Inspector

    func content(for selection: WorkspaceSelection, in context: SelectionContext) -> InspectorContent {
        switch selection {
        case .node(let node):
            return nodeContent(node, in: context)
        case .aggregate(let descriptor):
            return aggregateContent(descriptor, in: context)
        }
    }

    private func nodeContent(_ node: ScanNode, in context: SelectionContext) -> InspectorContent {
        let bytes = node.subtreeDiskBytes
        let isUnreadable = node.readState == .unreadable
        let isRoot = node === context.rootNode

        var rows: [InspectorContent.Row] = []
        // The length line, and **only** where the two measures differ by more
        // than a display step (ticket 13). On ~99% of rows they are the same
        // number, and a row that repeats the figure above it is clutter; on the
        // ones where they diverge — a sparse disk image, a compressed system
        // binary, a cloud placeholder that is here in name only — it is the
        // finding the user came for.
        if let length = divergentContentLength(node), !isUnreadable {
            rows.append(.init(label: "Content length", value: length))
        }
        if node.isDirectoryLike {
            // **Scanner semantics, both halves.** A package's internals count
            // here, because "Contains" is asking what is inside this item
            // (ticket 01, decision 10) — which is exactly where this parts
            // company with the tree's Items column. Both numbers are read from
            // the node: `fileCount` is maintained live by the scan, and the
            // folder tally is folded before the tree is published, so selecting
            // a large directory no longer walks it.
            rows.append(
                .init(
                    label: "Contains",
                    value: "\(formatter.count(node.fileCount)) files · \(formatter.count(Int64(node.folderDescendantCount))) folders"
                )
            )
        }
        rows.append(.init(label: "Kind", value: kindLabel(node)))
        rows.append(.init(label: "% of scan", value: formatter.share(childBytes: bytes, parentBytes: context.totalBytes)))
        rows.append(
            .init(
                label: "% of parent",
                value: node.parent.map { formatter.share(childBytes: bytes, parentBytes: $0.subtreeDiskBytes) } ?? "100%"
            )
        )
        if isRoot, let capacity = context.volumeCapacity, context.isVolumeScan {
            rows.append(.init(label: "Capacity", value: formatter.bytes(capacity.totalBytes)))
            rows.append(.init(label: "Free", value: formatter.bytes(capacity.availableBytes)))
        }

        return InspectorContent(
            swatch: node.kind == .directory ? .directory : .kind(TreemapPalette.group(forFileNamed: node.name)),
            title: node.name,
            subtitle: subtitle(node),
            sizeText: isUnreadable ? "Unknown" : formatter.bytes(bytes),
            sizeCaption: sizeCaption(node),
            exactBytesText: isUnreadable ? "size never guessed" : formatter.exactBytes(bytes),
            rows: rows,
            path: node.url(root: context.rootURL).path,
            notes: notes(for: node, in: context),
            showsActions: true,
            footnote: nil
        )
    }

    private func aggregateContent(
        _ descriptor: AggregateDescriptor,
        in context: SelectionContext
    ) -> InspectorContent {
        let count = formatter.count(Int64(descriptor.itemCount))
        let combined = formatter.bytes(descriptor.bytes)
        let samples = Array(descriptor.mergedRootNames.prefix(5))

        return InspectorContent(
            swatch: .merged,
            title: "\(count) merged items",
            subtitle: "Aggregate box in \(descriptor.directory.name)",
            sizeText: combined,
            sizeCaption: "combined",
            exactBytesText: formatter.exactBytes(descriptor.bytes),
            rows: [
                .init(label: "Items", value: count),
                .init(
                    label: "% of scan",
                    value: formatter.share(childBytes: descriptor.bytes, parentBytes: context.totalBytes)
                ),
                .init(
                    label: "% of parent",
                    value: formatter.share(
                        childBytes: descriptor.bytes,
                        parentBytes: descriptor.directory.subtreeDiskBytes
                    )
                ),
            ],
            path: nil,
            notes: [
                .init(
                    severity: .info,
                    glyph: "▦",
                    title: "\(count) items below individual size, combined \(combined).",
                    detail: """
                        Each would have drawn smaller than 2×2 pt, so they are shown as one \
                        exactly-sized box. Nothing is hidden — every one is still listed and \
                        selectable in the tree.
                        """
                )
            ],
            sampleNames: samples,
            additionalSampleCount: max(0, descriptor.mergedRootNames.count - samples.count),
            showsActions: false,
            footnote: """
                An aggregate is not a file. Open and Reveal are unavailable — select an \
                individual item in the tree instead.
                """
        )
    }

    // MARK: - The scan itself

    /// What the finished scan could not read, and what it skipped on purpose —
    /// shown in the inspector while nothing is selected, which is the state the
    /// window is in the moment a scan finishes.
    ///
    /// The status bar already carries the counts. This is where they get names:
    /// a user who reads "261 errors" and cannot find out *which* folders has
    /// been told the total is a lower bound and given no way to judge by how
    /// much.
    ///
    /// `nil` when there is nothing to report — a completed scan that read
    /// everything leaves the pane's "select an item" placeholder alone rather
    /// than pushing an all-clear nobody asked for.
    func scanSummary(result: ScanResult, in context: SelectionContext) -> InspectorContent? {
        let wasCancelled = result.reason == .cancelled
        guard wasCancelled || !result.errors.isEmpty || !result.exclusions.isEmpty else { return nil }

        var rows: [InspectorContent.Row] = []
        for category in ErrorCategory.allCases {
            guard let count = result.errors.byCategory[category], count > 0 else { continue }
            rows.append(.init(label: Self.label(for: category), value: formatter.count(Int64(count))))
        }
        for reason in ExclusionReason.allCases {
            guard let count = result.exclusions.byReason[reason], count > 0 else { continue }
            rows.append(.init(label: Self.label(for: reason), value: formatter.count(Int64(count))))
        }

        var notes: [InspectorContent.Note] = []
        if wasCancelled {
            notes.append(
                .init(
                    severity: .warning,
                    glyph: "◼",
                    title: "Scan cancelled.",
                    detail: """
                        Everything found before you stopped it is here and browsable. Every \
                        total is a lower bound.
                        """
                )
            )
        }
        if !result.errors.isEmpty {
            notes.append(
                .init(
                    severity: .error,
                    glyph: "⚠",
                    title: "\(formatter.count(Int64(result.errors.total))) could not be read.",
                    detail: """
                        Their sizes are never guessed, and every folder above them is marked \
                        Incomplete — so those totals are lower bounds, not figures.
                        """
                )
            )
        }
        if !result.exclusions.isEmpty {
            notes.append(
                .init(
                    severity: .info,
                    glyph: "◇",
                    title: "\(formatter.count(Int64(result.exclusions.total))) skipped on purpose.",
                    detail: """
                        Nothing went wrong: these were left uncounted by policy, so they do not \
                        make any total a lower bound.
                        """
                )
            )
        }

        // The paths, which are the whole point: a count says how wrong the
        // total might be, a path says whether it matters to you.
        let samples = result.errors.details.prefix(5).map { absolutePath(components: $0.path, in: context) }

        return InspectorContent(
            swatch: .directory,
            title: context.rootNode.name,
            subtitle: wasCancelled ? "Cancelled scan" : (result.errors.isEmpty ? "Completed scan" : "Completed with errors"),
            sizeText: formatter.bytes(context.rootNode.subtreeDiskBytes),
            sizeCaption: wasCancelled || !result.errors.isEmpty ? "counted so far" : "total on disk",
            exactBytesText: formatter.exactBytes(context.rootNode.subtreeDiskBytes),
            rows: rows,
            path: nil,
            notes: notes,
            sampleNames: samples,
            additionalSampleCount: max(0, result.errors.total - samples.count),
            showsActions: false,
            footnote: result.errors.isEmpty
                ? nil
                : "Select any folder marked Incomplete to see what is missing beneath it."
        )
    }

    private static func label(for category: ErrorCategory) -> String {
        switch category {
        case .unreadableDirectory: return "Folders not readable"
        case .unreadableEntry: return "Items not readable"
        case .disappeared: return "Vanished during the scan"
        }
    }

    private static func label(for reason: ExclusionReason) -> String {
        switch reason {
        case .remoteOnlyCloud: return "Cloud-only, not downloaded"
        case .crossedVolumeBoundary: return "On another volume"
        case .repeatedDirectory: return "Already counted elsewhere"
        }
    }

    // MARK: - Tooltip

    /// A quick reading of the rectangle: identity first, then its on-disk
    /// size and share. Leave a visual break between the name and measurement.
    func tooltip(for selection: WorkspaceSelection, in context: SelectionContext) -> String {
        switch selection {
        case .node(let node):
            let bytes = node.subtreeDiskBytes
            var lines = [node.name, ""]
            if node.readState == .unreadable {
                lines.append("Size unknown · unreadable")
            } else {
                lines.append("\(formatter.bytes(bytes)) on disk")
                lines.append("\(formatter.share(childBytes: bytes, parentBytes: context.totalBytes)) of scan")
                if node.readState == .incomplete {
                    lines.append("Incomplete · size is a lower bound")
                }
            }
            return lines.joined(separator: "\n")
        case .aggregate(let descriptor):
            let count = formatter.count(Int64(descriptor.itemCount))
            return [
                "\(count) small items · merged",
                "",
                "\(formatter.bytes(descriptor.bytes)) on disk",
                "\(formatter.share(childBytes: descriptor.bytes, parentBytes: context.totalBytes)) of scan",
            ].joined(separator: "\n")
        }
    }

    /// The accessibility label for one rendered rectangle: name, size and kind,
    /// or combined count and size for a merge box (spec §9.4).
    func accessibilityLabel(for selection: WorkspaceSelection) -> String {
        switch selection {
        case .node(let node):
            let size = node.readState == .unreadable ? "size unknown" : formatter.bytes(node.subtreeDiskBytes)
            return "\(node.name), \(size), \(kindLabel(node))"
        case .aggregate(let descriptor):
            return "\(formatter.count(Int64(descriptor.itemCount))) merged items, "
                + "combined \(formatter.bytes(descriptor.bytes)), aggregate"
        }
    }

    // MARK: - Shared vocabulary

    func kindLabel(_ node: ScanNode) -> String {
        switch node.kind {
        case .directory: return "Folder"
        case .package: return "Package"
        case .symbolicLink: return "Symbolic link"
        case .file, .other: return TreemapPalette.group(forFileNamed: node.name).displayName
        }
    }

    private func subtitle(_ node: ScanNode) -> String {
        var parts = [kindLabel(node)]
        if node.name.hasPrefix("."), node.name != ".", node.name != ".." { parts.append("Hidden") }
        return parts.joined(separator: " · ")
    }

    /// The headline figure is blocks on disk, and the caption says so — because
    /// "size" was the word for both measures and this only works if they can be
    /// told apart in a sentence (ticket 13, `CONTEXT.md`).
    private func sizeCaption(_ node: ScanNode) -> String {
        if node.readState == .unreadable { return "not guessed" }
        if node.subtreeDiskBytes == 0 {
            // The cloud-placeholder and sparse-file case, said plainly: it is
            // not that we failed to measure it, it is that it is not there.
            return node.subtreeContentBytes > 0 ? "nothing on disk" : "no attributed bytes"
        }
        return node.isDirectoryLike ? "total on disk" : "on disk"
    }

    /// The content length, formatted, when it differs from the on-disk figure
    /// by more than a display step — and `nil` when it does not.
    ///
    /// "More than a display step" is exactly "the two render differently at the
    /// three significant figures this app shows", which is the only definition
    /// that cannot put a row on screen saying two identical numbers.
    func divergentContentLength(_ node: ScanNode) -> String? {
        let onDisk = formatter.bytes(node.subtreeDiskBytes)
        let length = formatter.bytes(node.subtreeContentBytes)
        return onDisk == length ? nil : length
    }

    /// The ticket-01 per-item semantics, stated in words rather than encoded in
    /// a colour: symlink, hard link plus its owner, package, unreadable,
    /// incomplete.
    private func notes(for node: ScanNode, in context: SelectionContext) -> [InspectorContent.Note] {
        var notes: [InspectorContent.Note] = []

        if node.kind == .symbolicLink {
            notes.append(
                .init(
                    severity: .info,
                    glyph: "↗",
                    title: "Symbolic link — never followed.",
                    detail: "Contributes zero content bytes, so it has no rectangle."
                )
            )
        }

        if case .hardLinkElsewhere(let owner) = node.attribution {
            let ownerPath = owner.map { absolutePath(components: $0, in: context) }
            notes.append(
                .init(
                    severity: .info,
                    glyph: "⧉",
                    title: "Hard link — counted elsewhere.",
                    detail: ownerPath.map { "Attributed once, to the first in-scope path: \($0)" }
                        ?? "Attributed once, to the first in-scope path."
                )
            )
        }

        if case .directoryCountedElsewhere(let owner) = node.attribution {
            let ownerPath = owner.map { absolutePath(components: $0, in: context) }
            notes.append(
                .init(
                    severity: .info,
                    glyph: "⧉",
                    title: "Another path to a folder counted elsewhere.",
                    detail: ownerPath.map { "The same folder is here and at \($0). Its contents are counted once, there." }
                        ?? "The same folder is reachable at another path. Its contents are counted once, there."
                )
            )
        }

        // Content length with no blocks behind it at all. Rare, and worth a
        // sentence where a merely-compressed file is not: this is the sparse
        // disk image and the cloud placeholder — a name for bytes that are not
        // on this disk (ticket 13).
        if node.readState != .unreadable, node.subtreeDiskBytes == 0, node.subtreeContentBytes > 0 {
            notes.append(
                .init(
                    severity: .info,
                    glyph: "◌",
                    title: "\(formatter.bytes(node.subtreeContentBytes)) in length, nothing on disk.",
                    detail: """
                        Its contents are not stored here — a sparse file's unwritten range, or a \
                        cloud item that has not been downloaded. It has no rectangle because it \
                        is taking up no space.
                        """
                )
            )
        }

        if node.kind == .package {
            notes.append(
                .init(
                    severity: .info,
                    glyph: "▣",
                    title: "Package.",
                    detail: """
                        Measured by enumerating its descendants during the scan, so this total \
                        is exact. Expanding it in the tree subdivides its box.
                        """
                )
            )
        }

        switch node.readState {
        case .unreadable:
            notes.append(
                .init(
                    severity: .error,
                    glyph: "⚠",
                    title: "Unreadable.",
                    detail: "Its size is not guessed. Every ancestor is marked Incomplete."
                )
            )
        case .incomplete:
            notes.append(
                .init(
                    severity: .warning,
                    glyph: "⚠",
                    title: "Incomplete.",
                    detail: """
                        Something beneath it could not be fully read, so this total is a lower \
                        bound, not an exact figure.
                        """
                )
            )
        case .complete:
            break
        }

        return notes
    }

    private func absolutePath(components: [String], in context: SelectionContext) -> String {
        var url = context.rootURL
        for component in components.dropFirst() {
            url.appendPathComponent(component)
        }
        return url.path
    }
}
