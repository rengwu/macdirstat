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
        self.totalBytes = rootNode.subtreeBytes
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
        let bytes = node.subtreeBytes
        let isUnreadable = node.readState == .unreadable
        let isRoot = node === context.rootNode

        var rows: [InspectorContent.Row] = []
        if node.isDirectoryLike {
            let contents = SubtreeCounts.scannerCounts(of: node)
            rows.append(
                .init(
                    label: "Contains",
                    value: "\(formatter.count(contents.files)) files · \(formatter.count(contents.folders)) folders"
                )
            )
        }
        rows.append(.init(label: "Kind", value: kindLabel(node)))
        rows.append(.init(label: "% of scan", value: formatter.share(childBytes: bytes, parentBytes: context.totalBytes)))
        rows.append(
            .init(
                label: "% of parent",
                value: node.parent.map { formatter.share(childBytes: bytes, parentBytes: $0.subtreeBytes) } ?? "100%"
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
                        parentBytes: descriptor.directory.subtreeBytes
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

    // MARK: - Tooltip (spec §6.3)

    /// Name, IEC size **and** exact grouped bytes, full path, the ticket-01
    /// flags — the same facts as the inspector, one hover away.
    func tooltip(for selection: WorkspaceSelection, in context: SelectionContext) -> String {
        switch selection {
        case .node(let node):
            let bytes = node.subtreeBytes
            let size = node.readState == .unreadable
                ? "Unknown — size never guessed"
                : "\(formatter.bytes(bytes)) · \(formatter.exactBytes(bytes))"
            var lines = [
                node.name,
                size,
                "\(kindLabel(node)) · \(formatter.share(childBytes: bytes, parentBytes: context.totalBytes)) of scan",
            ]
            let flags = tooltipFlags(node)
            if !flags.isEmpty { lines.append(flags.joined(separator: " · ")) }
            lines.append(node.url(root: context.rootURL).path)
            return lines.joined(separator: "\n")
        case .aggregate(let descriptor):
            let count = formatter.count(Int64(descriptor.itemCount))
            return [
                "\(count) items below individual size",
                "combined \(formatter.bytes(descriptor.bytes)) · \(formatter.exactBytes(descriptor.bytes))",
                "Selectable · all still listed in the tree",
                "in \(descriptor.directory.url(root: context.rootURL).path)",
            ].joined(separator: "\n")
        }
    }

    /// The accessibility label for one rendered rectangle: name, size and kind,
    /// or combined count and size for a merge box (spec §9.4).
    func accessibilityLabel(for selection: WorkspaceSelection) -> String {
        switch selection {
        case .node(let node):
            let size = node.readState == .unreadable ? "size unknown" : formatter.bytes(node.subtreeBytes)
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

    private func sizeCaption(_ node: ScanNode) -> String {
        if node.readState == .unreadable { return "not guessed" }
        if node.subtreeBytes == 0 { return "no attributed bytes" }
        return node.isDirectoryLike ? "total" : "logical"
    }

    private func tooltipFlags(_ node: ScanNode) -> [String] {
        var flags: [String] = []
        if node.kind == .package { flags.append("Package") }
        if node.kind == .symbolicLink { flags.append("Symbolic link — never followed") }
        if case .hardLinkElsewhere = node.attribution { flags.append("Hard link — counted elsewhere") }
        switch node.readState {
        case .unreadable: flags.append("Unreadable — size not guessed")
        case .incomplete: flags.append("Incomplete — lower bound")
        case .complete: break
        }
        return flags
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

/// Subtree tallies the scanner keeps only half of.
///
/// `ScanNode.fileCount` is maintained live during the scan; a folder count is
/// not, so the inspector's "Contains" row walks for it. That walk is O(subtree)
/// and runs once per selection change on an in-memory frozen tree — never on
/// the scan's hot path.
enum SubtreeCounts {
    /// The **scanner's** numbers, not the tree's: a package's internals count
    /// here, because "Contains" is asking what is inside this item (ticket 01,
    /// decision 10). The status bar's tally deliberately answers a different
    /// question.
    static func scannerCounts(of node: ScanNode) -> (files: Int64, folders: Int64) {
        var folders: Int64 = 0
        var stack = node.children
        while let current = stack.popLast() {
            if current.isDirectoryLike { folders += 1 }
            stack.append(contentsOf: current.children)
        }
        return (node.fileCount, folders)
    }
}
