import AppKit
import ScanCore
import TreemapLayout

/// The classic-flat treemap: a custom Core Graphics `NSView` over the
/// `TreemapLayout` draw list (spec §4.1, §6.3, §6.4).
///
/// **No cache, no animation, no hysteresis** (§6.4). The layout is recomputed
/// from `(tree, viewport)` whenever any of the three inputs it depends on
/// changes — the tree, the viewport, or which packages are drilled into — and
/// the result is held only for the frame it describes, because hit testing,
/// hover and the accessibility children all have to answer for *the rectangles
/// currently on screen*. Holding a layout for a size the view no longer has is
/// what hysteresis would be, and that never happens here: a resize invalidates
/// before it repaints. Repaints coalesce to the display refresh because
/// `needsDisplay` does, which is what keeps a divider drag smooth.
@MainActor
final class TreemapView: NSView {
    /// The one shared selection (spec §7.2). The view both writes it (a click)
    /// and reads it (a tree click strokes a rectangle here).
    var selectionModel: SelectionModel? {
        didSet { observeSelection() }
    }

    var announcer: AccessibilityAnnouncing?
    var contentBuilder = InspectorContentBuilder()
    let expansion = PackageExpansion()

    /// Where the scan is rooted — needed for tooltips and nothing else here.
    var context: SelectionContext? {
        didSet { needsDisplay = true }
    }

    /// Forces a palette instead of reading the effective appearance. Tests set
    /// it so a light/dark bitmap regression does not depend on the host's
    /// system setting.
    var appearanceOverride: TreemapAppearance?

    /// Set by tests that render into a bitmap off-window, where there is no
    /// backing scale to read.
    var backingScaleOverride: Double?

    private var root: ScanNode?
    private var layoutResult: TreemapLayoutResult<TreemapNodeRef>?
    private var layoutKey: LayoutKey?
    private var accessibilityChildElements: [TreemapAccessibilityElement] = []
    private var accessibilityKey: LayoutKey?
    private var hoveredBoxIndex: Int?
    private var trackingArea: NSTrackingArea?

    private struct LayoutKey: Equatable {
        let root: ObjectIdentifier?
        let width: Double
        let height: Double
        let expansionGeneration: Int
        let appearance: TreemapAppearance
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Treemap")
    }

    required init?(coder: NSCoder) { nil }

    /// Top-left origin, y downward — the same orientation `TreemapRect` uses,
    /// so no rectangle is ever flipped between the layout and the screen.
    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Input

    func setRoot(_ node: ScanNode?) {
        guard node !== root else { return }
        root = node
        invalidateLayout()
    }

    func setPackage(_ node: ScanNode, expanded: Bool) {
        let before = expansion.generation
        expansion.setExpanded(expanded, for: node)
        if expansion.generation != before { invalidateLayout() }
    }

    func resetPackageExpansion() {
        let before = expansion.generation
        expansion.reset()
        if expansion.generation != before { invalidateLayout() }
    }

    private func invalidateLayout() {
        layoutResult = nil
        layoutKey = nil
        hoveredBoxIndex = nil
        toolTip = nil
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Full recompute on every size change (§6.4). Marking dirty is what
        // coalesces the recompute to the next display refresh during a drag.
        invalidateLayout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateLayout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Layout

    private var currentAppearance: TreemapAppearance {
        appearanceOverride ?? effectiveAppearance.treemapAppearance
    }

    private var backingScale: Double {
        backingScaleOverride ?? Double(window?.backingScaleFactor ?? 2)
    }

    /// The draw list for the rectangles currently on screen, recomputed the
    /// moment any input differs from the one it was computed for.
    @discardableResult
    func currentLayout() -> TreemapLayoutResult<TreemapNodeRef>? {
        guard let root else {
            layoutResult = nil
            layoutKey = nil
            return nil
        }
        let key = LayoutKey(
            root: ObjectIdentifier(root),
            width: Double(bounds.width),
            height: Double(bounds.height),
            expansionGeneration: expansion.generation,
            appearance: currentAppearance
        )
        if let layoutResult, layoutKey == key { return layoutResult }

        let result = TreemapLayout.layout(
            tree: TreemapNodeRef(node: root, expansion: expansion),
            viewport: TreemapSize(width: Double(bounds.width), height: Double(bounds.height))
        )
        layoutResult = result
        layoutKey = key
        accessibilityKey = nil
        refreshAggregateSelection(against: result)
        return result
    }

    /// The number of rectangles the layout put on screen — what §6.2 says
    /// relayout cost is bounded by.
    var renderedBoxCount: Int { currentLayout()?.boxes.count ?? 0 }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let appearance = currentAppearance
        TreemapChrome.voidBackground(appearance).setFill()
        bounds.fill()

        guard let result = currentLayout(), !result.boxes.isEmpty,
              let cgContext = NSGraphicsContext.current?.cgContext else { return }

        let scale = backingScale

        // 1 — fills. Zero insets: the leaves tile their directory's rectangle
        // exactly, so a directory has no fill of its own (§6.1, §6.3).
        for box in result.boxes where !box.isSubdivided {
            let rect = snappedRect(box.frame, scale: scale)
            guard rect.width > 0, rect.height > 0 else { continue }
            if box.isAggregate {
                drawHatch(
                    in: rect,
                    base: TreemapPalette.mergedBoxFillColor(appearance).nsColor,
                    stroke: TreemapPalette.mergedBoxHatchColor(appearance).nsColor,
                    context: cgContext
                )
            } else {
                let group = box.kindGroup ?? .other
                TreemapPalette.color(for: group, appearance: appearance).nsColor.setFill()
                rect.fill()
            }
        }

        // 2 — 0.5 pt hairlines between sibling leaves (§6.1).
        TreemapChrome.siblingHairline(appearance).setStroke()
        let hairline = CGFloat(TreemapMetrics.siblingHairlineWidthPoints)
        for box in result.boxes where !box.isSubdivided {
            let rect = snappedRect(box.frame, scale: scale)
            guard rect.width >= 1.2, rect.height >= 1.2 else { continue }
            let path = NSBezierPath(rect: rect.insetBy(dx: hairline / 2, dy: hairline / 2))
            path.lineWidth = hairline
            path.stroke()
        }

        // 3 — per-depth directory outlines, 1 pt, capped at 3 levels below the
        // root (ticket 01, decision 9).
        TreemapChrome.directoryOutline(appearance).setStroke()
        let outlineWidth = CGFloat(TreemapMetrics.directoryOutlineWidthPoints)
        for box in result.outlinedBoxes {
            let rect = snappedRect(box.frame, scale: scale)
            let path = NSBezierPath(rect: rect.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2))
            path.lineWidth = outlineWidth
            path.stroke()
        }

        // 4 — Incomplete: red diagonal hatch, over a fill that already says so
        // in the tree and inspector as text (§6.3, §9.4).
        for box in result.boxes where !box.isSubdivided && box.isIncomplete {
            let rect = snappedRect(box.frame, scale: scale)
            guard rect.width >= 3, rect.height >= 3 else { continue }
            drawHatch(in: rect, base: nil, stroke: TreemapChrome.incompleteHatch(appearance), context: cgContext)
        }

        // 5 — labels: 11 pt, only at ≥ 48×15 pt, truncated, with a halo (§6.3).
        for box in result.boxes where box.fitsLabel {
            drawLabel(for: box, in: snappedRect(box.frame, scale: scale))
        }

        // 6 — hover: a 1 pt high-contrast stroke (§6.3).
        if let hoveredBoxIndex, hoveredBoxIndex < result.boxes.count {
            let rect = snappedRect(result.boxes[hoveredBoxIndex].frame, scale: scale)
            let width = CGFloat(TreemapMetrics.hoverStrokeWidthPoints)
            TreemapChrome.hoverStroke(appearance).setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: width / 2, dy: width / 2))
            path.lineWidth = width
            path.stroke()
        }

        // 7 — selection: a 2 pt accent stroke inset 1 pt. A directory is
        // subdivided, so this outlines its whole region (§6.3, §7.2).
        if let index = selectedBoxIndex(in: result) {
            let rect = snappedRect(result.boxes[index].frame, scale: scale)
            let inset = CGFloat(TreemapMetrics.selectionStrokeInsetPoints)
            let width = CGFloat(TreemapMetrics.selectionStrokeWidthPoints)
            let strokeRect = rect.insetBy(dx: inset + width / 2, dy: inset + width / 2)
            guard strokeRect.width > 0, strokeRect.height > 0 else { return }
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: strokeRect)
            path.lineWidth = width
            path.stroke()
        }
    }

    private func snappedRect(_ frame: TreemapRect, scale: Double) -> NSRect {
        let snapped = frame.snapped(toBackingScale: scale)
        return NSRect(x: snapped.x, y: snapped.y, width: snapped.width, height: snapped.height)
    }

    /// Diagonal hatch at 45°, drawn by clipping and stroking rather than by a
    /// tiled pattern: the lines land on the same points at any backing scale,
    /// which is what a bitmap regression needs.
    private func drawHatch(in rect: NSRect, base: NSColor?, stroke: NSColor, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        if let base {
            base.setFill()
            rect.fill()
        }
        stroke.setStroke()
        let path = NSBezierPath()
        path.lineWidth = TreemapChrome.hatchLineWidthPoints
        var x = rect.minX - rect.height
        while x <= rect.maxX {
            path.move(to: NSPoint(x: x, y: rect.maxY))
            path.line(to: NSPoint(x: x + rect.height, y: rect.minY))
            x += TreemapChrome.hatchSpacingPoints
        }
        path.stroke()
    }

    private func drawLabel(for box: TreemapBox<TreemapNodeRef>, in rect: NSRect) {
        let text: String
        if let aggregate = box.aggregate {
            text = "\(contentBuilder.formatter.count(Int64(aggregate.itemCount))) items · "
                + contentBuilder.formatter.bytes(aggregate.bytes)
        } else if let node = box.node {
            text = node.node.name
        } else {
            return
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: CGFloat(TreemapMetrics.labelFontSizePoints), weight: .semibold),
            .foregroundColor: TreemapChrome.labelForeground,
            // A negative stroke width fills *and* strokes, which is the halo
            // §6.3 asks for in one pass.
            .strokeColor: TreemapChrome.labelHalo,
            .strokeWidth: -3.0,
            .paragraphStyle: paragraph,
        ]
        let textRect = NSRect(x: rect.minX + 4, y: rect.minY + 3, width: rect.width - 8, height: 14)
        (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin], attributes: attributes)
    }

    // MARK: - Hit testing (spec §6.4)

    /// The deepest rendered box containing `point`, in view coordinates.
    func boxIndex(at point: NSPoint) -> Int? {
        guard let result = currentLayout() else { return nil }
        let probe = TreemapPoint(x: Double(point.x), y: Double(point.y))
        var best: Int?
        for (index, box) in result.boxes.enumerated() where !box.isSubdivided {
            guard box.frame.contains(probe) else { continue }
            if let best, result.boxes[best].depth > box.depth { continue }
            best = index
        }
        return best
    }

    func selection(atBoxIndex index: Int) -> WorkspaceSelection? {
        guard let result = currentLayout(), index < result.boxes.count else { return nil }
        return selection(for: result.boxes[index], in: result)
    }

    private func selection(
        for box: TreemapBox<TreemapNodeRef>,
        in result: TreemapLayoutResult<TreemapNodeRef>
    ) -> WorkspaceSelection? {
        if let node = box.node { return .node(node.node) }
        guard let aggregate = box.aggregate,
              let parentIndex = box.parentIndex,
              let parent = result.boxes[parentIndex].node else { return nil }
        return .aggregate(
            AggregateDescriptor(
                directory: parent.node,
                itemCount: aggregate.itemCount,
                bytes: aggregate.bytes,
                mergedRootNames: aggregate.mergedRoots.map { $0.treemapName }
            )
        )
    }

    private func selectedBoxIndex(in result: TreemapLayoutResult<TreemapNodeRef>) -> Int? {
        guard let selection = selectionModel?.selection else { return nil }
        switch selection {
        case .node(let node):
            // A zero-byte node has no rectangle, so this finds nothing and
            // nothing is stroked — §7.2's "no false rectangle".
            return result.boxes.firstIndex { $0.node?.node === node }
        case .aggregate(let descriptor):
            return result.boxes.firstIndex { box in
                guard box.isAggregate, let parentIndex = box.parentIndex else { return false }
                return result.boxes[parentIndex].node?.node === descriptor.directory
            }
        }
    }

    /// After a relayout the bucket may hold different children, so the selected
    /// descriptor's numbers are re-read from the new layout — and if that
    /// directory no longer folds anything, the selection is cleared rather than
    /// left describing a box that is not there.
    private func refreshAggregateSelection(against result: TreemapLayoutResult<TreemapNodeRef>) {
        guard let model = selectionModel, let current = model.selection?.aggregate else { return }
        guard let index = result.boxes.firstIndex(where: { box in
            guard box.isAggregate, let parentIndex = box.parentIndex else { return false }
            return result.boxes[parentIndex].node?.node === current.directory
        }) else {
            model.clear()
            return
        }
        if let refreshed = selection(for: result.boxes[index], in: result) {
            model.select(refreshed, source: .programmatic)
        }
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredBoxIndex != nil else { return }
        hoveredBoxIndex = nil
        toolTip = nil
        needsDisplay = true
    }

    func updateHover(at point: NSPoint) {
        let index = boxIndex(at: point)
        guard index != hoveredBoxIndex else { return }
        hoveredBoxIndex = index
        toolTip = index.flatMap { hoveredIndex -> String? in
            guard let context, let selection = selection(atBoxIndex: hoveredIndex) else { return nil }
            return contentBuilder.tooltip(for: selection, in: context)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = boxIndex(at: point), let selection = selection(atBoxIndex: index) else { return }
        window?.makeFirstResponder(self)
        selectionModel?.select(selection, source: .treemap)
    }

    /// Right-click selects first, so the menu always acts on what it points at,
    /// and offers Open and Reveal and only ever those two (ticket 01,
    /// decision 3). An aggregate is not a file, so it gets no menu at all.
    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu(at: convert(event.locationInWindow, from: nil))
    }

    func contextMenu(at point: NSPoint) -> NSMenu? {
        guard let index = boxIndex(at: point),
              let selection = selection(atBoxIndex: index),
              case .node = selection else { return nil }
        selectionModel?.select(selection, source: .treemap)
        return FileActionMenu.make()
    }

    // MARK: - Selection observation

    private func observeSelection() {
        selectionModel?.addObserver { [weak self] change in
            guard let self else { return }
            // The elements carry selected state, so they are stale the moment
            // the selection moves even though the geometry has not changed.
            self.invalidateAccessibilityElements()
            self.needsDisplay = true
            self.announceSelectionChange(change)
        }
    }

    /// §9.4's `NSAccessibilityAnnouncementNotification` on a shared-selection
    /// change. Posted once, from the pane that owns the accessibility surface
    /// of the rectangles, regardless of which pane wrote the selection.
    private func announceSelectionChange(_ change: SelectionChange) {
        guard let announcer, let selection = change.selection else { return }
        announcer.announce("Selected \(contentBuilder.accessibilityLabel(for: selection))")
    }

    // MARK: - Accessibility (spec §9.4)

    override func accessibilityChildren() -> [Any]? {
        rebuildAccessibilityElementsIfNeeded()
        return accessibilityChildElements
    }

    /// One element per rendered rectangle — directory regions and aggregates
    /// included — in the draw list's deterministic order.
    func accessibilityRectangleElements() -> [TreemapAccessibilityElement] {
        rebuildAccessibilityElementsIfNeeded()
        return accessibilityChildElements
    }

    private func invalidateAccessibilityElements() {
        accessibilityKey = nil
    }

    private func rebuildAccessibilityElementsIfNeeded() {
        guard let result = currentLayout() else {
            accessibilityChildElements = []
            accessibilityKey = nil
            return
        }
        if accessibilityKey == layoutKey, !accessibilityChildElements.isEmpty { return }

        let selected = selectionModel?.selection
        accessibilityChildElements = result.boxes.compactMap { box in
            guard let selection = selection(for: box, in: result) else { return nil }
            let element = TreemapAccessibilityElement(selection: selection) { [weak self] chosen in
                self?.selectionModel?.select(chosen, source: .treemap)
            }
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(contentBuilder.accessibilityLabel(for: selection))
            element.setAccessibilityFrameInParentSpace(
                NSRect(x: box.frame.x, y: box.frame.y, width: box.frame.width, height: box.frame.height)
            )
            element.setAccessibilitySelected(selected.map { $0 == selection } ?? false)
            return element
        }
        accessibilityKey = layoutKey
    }
}

/// One rendered rectangle, as an accessibility element: labelled, focusable,
/// carrying its selected state, and able to select itself (spec §9.4).
///
/// It offers exactly one action — pressing it selects it. There is deliberately
/// no other action, so the accessibility tree carries no mutation affordance
/// either (§7.1).
final class TreemapAccessibilityElement: NSAccessibilityElement {
    private var selection: WorkspaceSelection?
    private var onPress: ((WorkspaceSelection) -> Void)?
    private var focused = false

    convenience init(selection: WorkspaceSelection, onPress: @escaping (WorkspaceSelection) -> Void) {
        self.init()
        self.selection = selection
        self.onPress = onPress
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    override func isAccessibilityFocused() -> Bool { focused }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        focused = accessibilityFocused
    }

    override func accessibilityPerformPress() -> Bool {
        guard let selection, let onPress else { return false }
        onPress(selection)
        return true
    }
}

/// The read-only file-action menu, in one place so the tree's context menu, the
/// treemap's context menu and the main menu cannot drift apart — and so "only
/// ever those two items" is one assertion (ticket 01, decision 3; §7.1).
enum FileActionMenu {
    static let openTitle = "Open"
    static let revealTitle = "Reveal in Finder"

    static func make() -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: openTitle, action: #selector(FileActionResponding.openSelectedItem(_:)), keyEquivalent: "")
        let reveal = NSMenuItem(
            title: revealTitle,
            action: #selector(FileActionResponding.revealSelectedItem(_:)),
            keyEquivalent: ""
        )
        menu.addItem(open)
        menu.addItem(reveal)
        return menu
    }
}

/// The two actions, as a responder-chain contract. Nothing else is declared,
/// so nothing else can be sent from a menu.
@MainActor
@objc
protocol FileActionResponding: AnyObject {
    @objc func openSelectedItem(_ sender: Any?)
    @objc func revealSelectedItem(_ sender: Any?)
}
