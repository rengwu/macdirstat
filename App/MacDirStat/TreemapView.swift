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
/// what hysteresis would be, and that never happens here: hit testing, hover
/// and accessibility all refuse a result whose viewport is not the view's.
/// Repaints coalesce to the display refresh because `needsDisplay` does, which
/// is what keeps a divider drag smooth.
///
/// **The recompute does not happen here.** It is asked of a
/// ``TreemapLayoutCoordinator``, which runs it off the main thread and calls
/// back when it lands (ticket 14): laying out inside `draw(_:)` froze the
/// window for seconds during a scan of a real volume. Between asking and
/// landing there is a gap, and the view has to draw *something* — see
/// ``drawPreview(of:in:)``.
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

    /// Where the layout runs. Production is `.background` — the whole point of
    /// ticket 14. Tests that assert on geometry set `.immediate`, so the draw
    /// list exists in the same turn they asked for it; the geometry is
    /// identical either way, which `LayoutCoordinatorTests` proves directly.
    var layoutExecution: TreemapLayoutExecution = .background {
        didSet {
            guard layoutExecution != oldValue else { return }
            makeCoordinator()
            requestLayout()
            needsDisplay = true
        }
    }

    private var root: ScanNode?
    private var coordinator = TreemapLayoutCoordinator<TreemapNodeRef>(execution: .background)
    /// Bumped whenever the *content* changes — a new tree, a package drilled
    /// into. The viewport is the request's other half and is read from
    /// `bounds`, so a resize needs no bump.
    private var contentRevision = 0
    private var accessibilityChildElements: [TreemapAccessibilityElement] = []
    private var accessibilityRequest: TreemapLayoutCoordinator<TreemapNodeRef>.Request?
    private var hoveredBoxIndex: Int?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Treemap")
        makeCoordinator()
    }

    private func makeCoordinator() {
        coordinator = TreemapLayoutCoordinator<TreemapNodeRef>(
            execution: layoutExecution,
            // Cap the picture, not the tree: without this the box count is the
            // window's area over 4 pt², so maximizing on a 4K display buys tens
            // of thousands of rectangles nobody can read and every relayout and
            // repaint pays for them (``TreemapLayoutBudget``).
            budget: .standard
        )
        coordinator.onResult = { [weak self] in self?.layoutDidArrive() }
        accessibilityRequest = nil
    }

    /// Waits for the background layout to settle. Tests only — nothing on a
    /// drawing path may wait for a layout.
    func settleLayout() async {
        await coordinator.settle()
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
        contentRevision += 1
        hoveredBoxIndex = nil
        toolTip = nil
        if root == nil { coordinator.invalidate() }
        requestLayout()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Full recompute on every size change (§6.4). Marking dirty is what
        // coalesces the recompute to the next display refresh during a drag;
        // the coordinator coalesces the layouts themselves, so a drag asks for
        // dozens of sizes and computes one at a time, ending on the last.
        hoveredBoxIndex = nil
        toolTip = nil
        requestLayout()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Colours only: the appearance never moved a rectangle, so this is a
        // repaint and not a relayout.
        needsDisplay = true
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

    private var currentViewport: TreemapSize {
        TreemapSize(width: Double(bounds.width), height: Double(bounds.height))
    }

    /// Asks for the draw list the view's current inputs call for. Idempotent
    /// and cheap: the coordinator drops a request it is already holding or
    /// already running.
    private func requestLayout() {
        guard let root, currentViewport.isDrawable else { return }
        coordinator.request(
            tree: TreemapNodeRef(node: root, expansion: expansion.snapshot()),
            viewport: currentViewport,
            revision: contentRevision
        )
    }

    /// The draw list **for the rectangles currently on screen**, or `nil` while
    /// none has arrived for this viewport.
    ///
    /// A result computed for another size is deliberately not offered here:
    /// hit testing, hover and the accessibility children have to answer for
    /// what is really on screen, and a stretched preview is not that. Drawing
    /// is the one caller that may use the older result, and it says so.
    @discardableResult
    func currentLayout() -> TreemapLayoutResult<TreemapNodeRef>? {
        requestLayout()
        guard let result = coordinator.result, result.viewport == currentViewport else { return nil }
        return result
    }

    private func layoutDidArrive() {
        accessibilityRequest = nil
        if let result = coordinator.result, result.viewport == currentViewport {
            refreshAggregateSelection(against: result)
        }
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let appearance = currentAppearance
        TreemapChrome.voidBackground(appearance).setFill()
        dirtyRect.fill()

        requestLayout()
        guard let held = coordinator.result, !held.boxes.isEmpty,
              let cgContext = NSGraphicsContext.current?.cgContext else { return }

        // The one place a layout for another size is allowed on screen: it is
        // stretched, unlabelled and visibly provisional, and it is replaced the
        // moment the real one lands. The alternative during a divider drag is a
        // grey window, because the layout no longer happens on this thread.
        guard held.viewport == currentViewport else {
            return drawPreview(of: held, appearance: appearance, context: cgContext)
        }
        let result = held

        let scale = backingScale
        // Snapped once, here, and read by index from every pass below. The
        // passes used to each snap the same rectangle again, which is six
        // roundings per box, and a maximized 4K window has a great many boxes.
        let snapped = result.boxes.map { snappedRect($0.frame, scale: scale) }

        // **Everything below is limited to `dirtyRect`.** Moving the pointer
        // invalidates two rectangles rather than the view, so a hover costs two
        // small repaints instead of one pass over every box on screen — which
        // is what made a large window feel slow well before the box count did.
        var fillsByGroup: [TreemapKindGroup: [NSRect]] = [:]
        var aggregateIndices: [Int] = []
        var incompleteIndices: [Int] = []
        var labelledIndices: [Int] = []
        let hairlinePath = CGMutablePath()
        let hairline = CGFloat(TreemapMetrics.siblingHairlineWidthPoints)

        for (index, box) in result.boxes.enumerated() where !box.isSubdivided {
            let rect = snapped[index]
            guard rect.width > 0, rect.height > 0, rect.intersects(dirtyRect) else { continue }
            if box.isAggregate {
                aggregateIndices.append(index)
            } else {
                fillsByGroup[box.kindGroup ?? .other, default: []].append(rect)
            }
            if rect.width >= 1.2, rect.height >= 1.2 {
                hairlinePath.addRect(rect.insetBy(dx: hairline / 2, dy: hairline / 2))
            }
            if box.isIncomplete, rect.width >= 3, rect.height >= 3 {
                incompleteIndices.append(index)
            }
            if box.fitsLabel {
                labelledIndices.append(index)
            }
        }

        // 1 — fills. Zero insets: the leaves tile their directory's rectangle
        // exactly, so a directory has no fill of its own (§6.1, §6.3). One
        // batched call per kind group rather than one per box; the rectangles
        // are snapped to the pixel grid and never overlap, so which group is
        // painted first cannot change a pixel.
        for (group, rects) in fillsByGroup {
            cgContext.setFillColor(TreemapPalette.color(for: group, appearance: appearance).nsColor.cgColor)
            cgContext.addRects(rects)
            cgContext.fillPath()
        }
        for index in aggregateIndices {
            drawHatch(
                in: snapped[index],
                base: TreemapPalette.mergedBoxFillColor(appearance).nsColor,
                stroke: TreemapPalette.mergedBoxHatchColor(appearance).nsColor,
                context: cgContext
            )
        }

        // 2 — 0.5 pt hairlines between sibling leaves (§6.1), as one path: the
        // colour and width are the same for every box, so this is one stroke
        // rather than a `NSBezierPath` allocated and stroked per rectangle.
        if !hairlinePath.isEmpty {
            cgContext.saveGState()
            cgContext.setStrokeColor(TreemapChrome.siblingHairline(appearance).cgColor)
            cgContext.setLineWidth(hairline)
            cgContext.addPath(hairlinePath)
            cgContext.strokePath()
            cgContext.restoreGState()
        }

        // 3 — per-depth directory outlines, 1 pt, capped at 3 levels below the
        // root (ticket 01, decision 9). Same one-path treatment.
        let outlinePath = CGMutablePath()
        let outlineWidth = CGFloat(TreemapMetrics.directoryOutlineWidthPoints)
        for (index, box) in result.boxes.enumerated()
        where box.isSubdivided
            && box.depth > 0
            && box.depth <= TreemapMetrics.directoryOutlineMaximumDepth
            && box.frame.shortestSide >= TreemapMetrics.directoryOutlineMinimumSidePoints {
            let rect = snapped[index]
            guard rect.intersects(dirtyRect) else { continue }
            outlinePath.addRect(rect.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2))
        }
        if !outlinePath.isEmpty {
            cgContext.saveGState()
            cgContext.setStrokeColor(TreemapChrome.directoryOutline(appearance).cgColor)
            cgContext.setLineWidth(outlineWidth)
            cgContext.addPath(outlinePath)
            cgContext.strokePath()
            cgContext.restoreGState()
        }

        // 4 — Incomplete: red diagonal hatch, over a fill that already says so
        // in the tree and inspector as text (§6.3, §9.4).
        for index in incompleteIndices {
            drawHatch(
                in: snapped[index],
                base: nil,
                stroke: TreemapChrome.incompleteHatch(appearance),
                context: cgContext
            )
        }

        // 5 — labels: 11 pt, only at ≥ 48×15 pt, truncated, with a halo (§6.3).
        for index in labelledIndices {
            drawLabel(for: result.boxes[index], in: snapped[index])
        }

        // 6 — hover: a 1 pt high-contrast stroke (§6.3).
        if let hoveredBoxIndex, hoveredBoxIndex < result.boxes.count {
            let rect = snapped[hoveredBoxIndex]
            let width = CGFloat(TreemapMetrics.hoverStrokeWidthPoints)
            TreemapChrome.hoverStroke(appearance).setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: width / 2, dy: width / 2))
            path.lineWidth = width
            path.stroke()
        }

        // 7 — selection: a 2 pt accent stroke inset 1 pt. A directory is
        // subdivided, so this outlines its whole region (§6.3, §7.2).
        if let index = selectedBoxIndex(in: result) {
            let rect = snapped[index]
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

    /// The last real draw list, stretched to the view's current size, while the
    /// layout for that size is still being computed.
    ///
    /// Fills and directory outlines only: no labels (they would stretch), no
    /// hairlines, no hover, no selection stroke — every one of those makes a
    /// promise about a rectangle's exact edges, and these edges are an
    /// approximation. It is never hit-tested, never handed to accessibility,
    /// and never snapped to the pixel grid, all of which would dress an
    /// estimate up as the truth. §6.4's "no cache" is about not *reusing*
    /// geometry to avoid recomputing it; the recompute is already running.
    private func drawPreview(
        of result: TreemapLayoutResult<TreemapNodeRef>,
        appearance: TreemapAppearance,
        context: CGContext
    ) {
        guard result.viewport.isDrawable else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(
            x: bounds.width / CGFloat(result.viewport.width),
            y: bounds.height / CGFloat(result.viewport.height)
        )

        // Batched exactly as the real draw is, and for the same reason with
        // more force: this is the frame a live resize actually shows, once per
        // size the window passes through.
        var fillsByGroup: [TreemapKindGroup: [NSRect]] = [:]
        var mergedFills: [NSRect] = []
        for box in result.boxes where !box.isSubdivided {
            let rect = NSRect(
                x: box.frame.x, y: box.frame.y,
                width: box.frame.width, height: box.frame.height
            )
            guard rect.width > 0, rect.height > 0 else { continue }
            if box.isAggregate {
                mergedFills.append(rect)
            } else {
                fillsByGroup[box.kindGroup ?? .other, default: []].append(rect)
            }
        }
        for (group, rects) in fillsByGroup {
            context.setFillColor(TreemapPalette.color(for: group, appearance: appearance).nsColor.cgColor)
            context.addRects(rects)
            context.fillPath()
        }
        if !mergedFills.isEmpty {
            context.setFillColor(TreemapPalette.mergedBoxFillColor(appearance).nsColor.cgColor)
            context.addRects(mergedFills)
            context.fillPath()
        }

        let outlinePath = CGMutablePath()
        for box in result.boxes
        where box.isSubdivided
            && box.depth > 0
            && box.depth <= TreemapMetrics.directoryOutlineMaximumDepth
            && box.frame.shortestSide >= TreemapMetrics.directoryOutlineMinimumSidePoints {
            outlinePath.addRect(NSRect(
                x: box.frame.x, y: box.frame.y,
                width: box.frame.width, height: box.frame.height
            ))
        }
        if !outlinePath.isEmpty {
            context.setStrokeColor(TreemapChrome.directoryOutline(appearance).cgColor)
            context.setLineWidth(CGFloat(TreemapMetrics.directoryOutlineWidthPoints))
            context.addPath(outlinePath)
            context.strokePath()
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
        guard let previous = hoveredBoxIndex else { return }
        hoveredBoxIndex = nil
        toolTip = nil
        invalidate(boxIndex: previous)
    }

    func updateHover(at point: NSPoint) {
        let index = boxIndex(at: point)
        guard index != hoveredBoxIndex else { return }
        let previous = hoveredBoxIndex
        hoveredBoxIndex = index
        toolTip = index.flatMap { hoveredIndex -> String? in
            guard let context, let selection = selection(atBoxIndex: hoveredIndex) else { return nil }
            return contentBuilder.tooltip(for: selection, in: context)
        }
        // Two rectangles changed, so two rectangles are repainted. Marking the
        // whole view dirty here meant every pointer move redrew every box on
        // screen — affordable at 1440×900, and the largest single cost of a
        // maximized window at 4K.
        invalidate(boxIndex: previous)
        invalidate(boxIndex: index)
    }

    /// Marks one box's rectangle for repaint, and nothing else.
    ///
    /// Reads the held layout directly rather than through ``currentLayout()``:
    /// this is on the mouse path and has no business asking for a relayout.
    private func invalidate(boxIndex: Int?) {
        guard let boxIndex,
              let result = coordinator.result,
              result.viewport == currentViewport,
              boxIndex < result.boxes.count else { return }
        let rect = snappedRect(result.boxes[boxIndex].frame, scale: backingScale)
        // Slop for the strokes that sit on the rectangle's own edge — the
        // hover stroke, the selection stroke, and the hairline a neighbour
        // draws on the shared edge.
        setNeedsDisplay(rect.insetBy(dx: -2, dy: -2))
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

    /// One element per rectangle a user could point at — the labelled ones —
    /// in the draw list's deterministic order, plus the selected rectangle
    /// whatever its size.
    func accessibilityRectangleElements() -> [TreemapAccessibilityElement] {
        rebuildAccessibilityElementsIfNeeded()
        return accessibilityChildElements
    }

    private func invalidateAccessibilityElements() {
        accessibilityRequest = nil
    }

    private func rebuildAccessibilityElementsIfNeeded() {
        guard let result = currentLayout() else {
            accessibilityChildElements = []
            accessibilityRequest = nil
            return
        }
        if accessibilityRequest == coordinator.resultRequest, !accessibilityChildElements.isEmpty { return }

        let selected = selectionModel?.selection
        // Only the rectangles that carry a label are published.
        //
        // Publishing one element per rendered rectangle cost 7–8 seconds of
        // main thread on a whole-volume map, all of it inside the accessibility
        // client's own question — the same freeze ticket 14 removed, reached
        // from outside the process. `fitsLabel` is the rule already on screen
        // and already in the mouse: a subdivided directory region is never
        // labelled and never hit-tested, and a rectangle under 48×15 pt is
        // neither readable nor reliably clickable. Labelled leaves do not
        // overlap, so their count is bounded by the viewport's area over
        // 48×15 pt — a few thousand at any window size, whatever the tree
        // holds. Nothing becomes unreachable: the tree pane carries every node,
        // hierarchy included, which is the pane built for navigating it.
        let selectedIndex = selectedBoxIndex(in: result)
        accessibilityChildElements = result.boxes.enumerated().compactMap { index, box in
            // The selected rectangle is always published, however small, so a
            // selection made in the tree is never a thing the map cannot name.
            guard box.fitsLabel || index == selectedIndex else { return nil }
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
        accessibilityRequest = coordinator.resultRequest
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
