import AppKit
import ScanCore
import TreemapLayout
import XCTest
@testable import MacDirStat

/// Fixed-size bitmap regressions over the classic-flat drawing.
///
/// These assert *properties* of the rendered bitmap — a filled corner pixel, a
/// stroke where a stroke belongs, a neutral aggregate — rather than comparing
/// against a stored image. Geometry assertions stay authoritative: font
/// rasterization, accent colour and subpixel rules differ across macOS
/// versions, and a golden PNG would fail on those without a single rectangle
/// being wrong.
@MainActor
final class TreemapRenderingTests: XCTestCase {
    private let viewport = NSRect(x: 0, y: 0, width: 400, height: 300)

    private func makeView(
        root: ScanNode,
        context: SelectionContext,
        appearance: TreemapAppearance
    ) -> (TreemapView, SelectionModel) {
        let view = TreemapView(frame: viewport)
        // Inline layout: a bitmap regression has to rasterize the real draw
        // list, not the stretched preview the view shows while a background
        // layout is still running (ticket 14).
        view.layoutExecution = .immediate
        view.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        view.appearanceOverride = appearance
        view.contentBuilder = InspectorContentBuilder(formatter: DisplayFormatter(locale: Locale(identifier: "en_US")))
        let model = SelectionModel()
        view.selectionModel = model
        view.context = context
        view.setRoot(root)
        return (view, model)
    }

    /// A rendered bitmap plus the scale it was rendered at, so a test can name
    /// a **point** and read the pixel that point landed on. The caching rep
    /// comes back at the host's backing scale — 2× on every Retina machine —
    /// and reading pixel (150, 150) of an 800×600 bitmap as though it were
    /// point (150, 150) samples an entirely different rectangle.
    private struct RenderedBitmap {
        let rep: NSBitmapImageRep
        let scale: CGFloat

        func color(_ x: Double, _ y: Double) throws -> NSColor {
            // Clamped to the last pixel: a rectangle whose centre rounds to the
            // far edge — a thin strip against the right-hand side — is still in
            // that rectangle, and reading nothing would say less than reading
            // the pixel next to it.
            let pixelX = min(rep.pixelsWide - 1, max(0, Int((CGFloat(x) + 0.5) * scale)))
            let pixelY = min(rep.pixelsHigh - 1, max(0, Int((CGFloat(y) + 0.5) * scale)))
            return try XCTUnwrap(rep.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.sRGB))
        }
    }

    private func render(_ view: TreemapView) throws -> RenderedBitmap {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        // Snap at the scale actually being rasterized, so a rectangle edge and
        // the pixel it is asserted on agree.
        view.backingScaleOverride = Double(scale)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        return RenderedBitmap(rep: rep, scale: scale)
    }

    private func assertSimilar(
        _ actual: NSColor,
        _ expected: NSColor,
        accuracy: CGFloat = 0.06,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let want = expected.usingColorSpace(.sRGB) ?? expected
        XCTAssertEqual(actual.redComponent, want.redComponent, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, want.greenComponent, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, want.blueComponent, accuracy: accuracy, message, file: file, line: line)
    }

    /// Two files whose bytes are 3:1, so the layout is a predictable split and
    /// every pixel of the viewport belongs to one of them.
    private func makeTwoFileFixture() async throws -> ScannedFixture {
        try await ScannedFixture.make(in: self) { root in
            try writeFile("movie.mp4", bytes: 750_000, in: root)
            try writeFile("photo.png", bytes: 250_000, in: root)
        }
    }

    func test_leavesTileTheWholeViewportWithZeroInsetsInBothAppearances() async throws {
        let fixture = try await makeTwoFileFixture()
        let context = SelectionContext(rootURL: fixture.root, rootNode: fixture.rootNode)

        for appearance in [TreemapAppearance.light, .dark] {
            let (view, _) = makeView(root: fixture.rootNode, context: context, appearance: appearance)
            let canvas = try render(view)
            let voidColor = TreemapChrome.voidBackground(appearance)

            // Zero insets: no directory background shows through anywhere,
            // including the four corners the layout has to reach exactly.
            for point in [(2.0, 2.0), (397.0, 2.0), (2.0, 297.0), (397.0, 297.0), (200.0, 150.0)] {
                let sample = try canvas.color(point.0, point.1)
                XCTAssertGreaterThan(
                    sample.difference(from: voidColor),
                    0.05,
                    "\(appearance) pixel \(point) shows the empty background — the leaves must tile 100% of the rect"
                )
            }
        }
    }

    func test_eachLeafCarriesItsKindHueFromTheSettledPalette() async throws {
        let fixture = try await makeTwoFileFixture()
        let context = SelectionContext(rootURL: fixture.root, rootNode: fixture.rootNode)

        for appearance in [TreemapAppearance.light, .dark] {
            let (view, _) = makeView(root: fixture.rootNode, context: context, appearance: appearance)
            let layout = try XCTUnwrap(view.currentLayout())
            let canvas = try render(view)

            for name in ["movie.mp4", "photo.png"] {
                let box = try XCTUnwrap(layout.boxes.first { $0.node?.node.name == name })
                let sample = try canvas.color(
                    box.frame.x + box.frame.width / 2,
                    box.frame.y + box.frame.height / 2
                )
                let group = TreemapPalette.group(forFileNamed: name)
                assertSimilar(
                    sample,
                    TreemapPalette.color(for: group, appearance: appearance).nsColor,
                    "\(name) in \(appearance) must be its kind hue"
                )
            }
        }
    }

    func test_siblingLeavesAreSeparatedByAHairlineNotAGap() async throws {
        let fixture = try await makeTwoFileFixture()
        let context = SelectionContext(rootURL: fixture.root, rootNode: fixture.rootNode)
        let (view, _) = makeView(root: fixture.rootNode, context: context, appearance: .light)
        let layout = try XCTUnwrap(view.currentLayout())
        let canvas = try render(view)

        let first = try XCTUnwrap(layout.boxes.first { $0.node?.node.name == "movie.mp4" })
        let second = try XCTUnwrap(layout.boxes.first { $0.node?.node.name == "photo.png" })
        // They abut: one's far edge is the other's near edge, to float drift.
        let sharedEdge = min(
            abs(first.frame.maxX - second.frame.minX),
            abs(first.frame.maxY - second.frame.minY)
        )
        XCTAssertLessThan(sharedEdge, 0.001, "sibling leaves must abut — no inset, no gutter")

        // The hairline darkens the shared edge without erasing the fills.
        let edgeSample: NSColor
        if abs(first.frame.maxX - second.frame.minX) < 0.001 {
            edgeSample = try canvas.color(first.frame.maxX - 0.25, first.frame.y + first.frame.height / 2)
        } else {
            edgeSample = try canvas.color(first.frame.x + first.frame.width / 2, first.frame.maxY - 0.25)
        }
        let interior = try canvas.color(
            first.frame.x + first.frame.width / 2,
            first.frame.y + first.frame.height / 2
        )
        XCTAssertGreaterThan(
            edgeSample.difference(from: interior),
            0.01,
            "a 0.5 pt hairline must be visible along the shared edge"
        )
    }

    func test_theMergeAggregateIsNeutralAndNotAnyKindHue() async throws {
        // The bucket has to be big enough to *sample*, which needs a long tail
        // rather than a small one: each entry must be under 2×2 pt on its own
        // (so it merges), while the 2,000 of them together take a few percent
        // of the viewport (so the box they land in is wider than a pixel).
        //
        // The dominant file is preallocated rather than written, and is a
        // quarter of a gigabyte rather than six megabytes: since ticket 13 a
        // 100-byte file occupies a whole block, so the tail is 2,000 blocks and
        // only something this large pushes each of them under 2 pt.
        let fixture = try await ScannedFixture.make(in: self) { root in
            try writeAllocatedFile("dominant.mp4", bytes: 256 * 1_024 * 1_024, in: root)
            for index in 1...2_000 {
                try writeFile("tiny-\(index).png", bytes: 100, in: root)
            }
        }
        let context = SelectionContext(rootURL: fixture.root, rootNode: fixture.rootNode)

        for appearance in [TreemapAppearance.light, .dark] {
            let (view, _) = makeView(root: fixture.rootNode, context: context, appearance: appearance)
            let layout = try XCTUnwrap(view.currentLayout())
            let aggregate = try XCTUnwrap(layout.boxes.first { $0.isAggregate })
            let canvas = try render(view)

            let sample = try canvas.color(
                aggregate.frame.x + aggregate.frame.width / 2,
                aggregate.frame.y + aggregate.frame.height / 2
            )
            // Neutral means the three channels agree — a kind hue never does.
            XCTAssertLessThan(
                max(
                    abs(sample.redComponent - sample.greenComponent),
                    abs(sample.greenComponent - sample.blueComponent)
                ),
                0.06,
                "the aggregate must read as neutral in \(appearance), not as a kind hue"
            )
            for group in TreemapKindGroup.allCases where group != .other {
                let hue = TreemapPalette.color(for: group, appearance: appearance).nsColor
                XCTAssertGreaterThan(
                    sample.difference(from: hue),
                    0.08,
                    "the aggregate must not be mistakable for \(group.displayName)"
                )
            }
        }
    }

    func test_selectionDrawsATwoPointAccentStrokeInsetOnePoint() async throws {
        let fixture = try await makeTwoFileFixture()
        let context = SelectionContext(rootURL: fixture.root, rootNode: fixture.rootNode)
        let node = try fixture.node(named: "movie.mp4")

        for appearance in [TreemapAppearance.light, .dark] {
            let (view, model) = makeView(root: fixture.rootNode, context: context, appearance: appearance)
            let layout = try XCTUnwrap(view.currentLayout())
            let box = try XCTUnwrap(layout.boxes.first { $0.node?.node === node })
            model.select(.node(node), source: .tree)
            let canvas = try render(view)

            var accent = NSColor.controlAccentColor
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? accent
            }

            // The stroke is 2 pt wide, inset 1 pt: the band from 1 to 3 points
            // inside the edge is accent, the pixel on the edge itself is not.
            let midY = box.frame.y + box.frame.height / 2
            let strokeSample = try canvas.color(box.frame.x + 2, midY)
            assertSimilar(strokeSample, accent, "the selection stroke must be the system accent colour")

            let outsideStroke = try canvas.color(box.frame.x + 0.25, midY)
            XCTAssertGreaterThan(
                outsideStroke.difference(from: accent),
                0.05,
                "the stroke is inset 1 pt, so the edge pixel itself is not accent"
            )

            let interior = try canvas.color(box.frame.x + box.frame.width / 2, midY)
            XCTAssertGreaterThan(
                interior.difference(from: accent),
                0.05,
                "the selection is a stroke, never a fill — the kind hue stays readable"
            )
        }
    }

    func test_hoverDrawsAOnePointStrokeAndATooltipCarryingTheItemsFacts() async throws {
        let fixture = try await makeTwoFileFixture()
        let context = SelectionContext(rootURL: fixture.root, rootNode: fixture.rootNode)
        let (view, _) = makeView(root: fixture.rootNode, context: context, appearance: .light)
        let layout = try XCTUnwrap(view.currentLayout())
        let box = try XCTUnwrap(layout.boxes.first { $0.node?.node.name == "movie.mp4" })

        let before = try render(view)
        view.updateHover(
            at: NSPoint(x: box.frame.x + box.frame.width / 2, y: box.frame.y + box.frame.height / 2)
        )
        let after = try render(view)

        let edgeX = box.frame.x + 0.25
        let midY = box.frame.y + box.frame.height / 2
        XCTAssertGreaterThan(
            (try after.color(edgeX, midY)).difference(from: try before.color(edgeX, midY)),
            0.05,
            "hovering must stroke the rectangle's own edge with 1 pt"
        )

        let tooltip = try XCTUnwrap(view.toolTip)
        XCTAssertTrue(tooltip.contains("movie.mp4"))
        let occupied = try onDiskBytes(of: fixture.root.appendingPathComponent("movie.mp4"))
        XCTAssertTrue(tooltip.contains(groupedBytesText(occupied)),
                      "the tooltip carries the exact grouped bytes too: \(tooltip)")
        XCTAssertTrue(tooltip.contains(fixture.root.appendingPathComponent("movie.mp4").path))
    }

    func test_directoryRegionsAreOutlinedAndCarryNoFillOfTheirOwn() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            let folder = try makeDirectory("assets", in: root)
            try writeFile("one.png", bytes: 300_000, in: folder)
            try writeFile("two.png", bytes: 300_000, in: folder)
            try writeFile("outside.mp4", bytes: 400_000, in: root)
        }
        let context = SelectionContext(rootURL: fixture.root, rootNode: fixture.rootNode)
        let (view, _) = makeView(root: fixture.rootNode, context: context, appearance: .light)
        let layout = try XCTUnwrap(view.currentLayout())

        let folder = try fixture.node(named: "assets")
        let region = try XCTUnwrap(layout.boxes.first { $0.node?.node === folder })
        XCTAssertTrue(region.isSubdivided, "a directory's area is composed of its children")
        XCTAssertNil(region.kindGroup, "a directory carries no fill of its own")
        XCTAssertTrue(
            layout.outlinedBoxes.contains { $0.node?.node === folder },
            "a directory region below the root gets the 1 pt outline"
        )
        XCTAssertTrue(
            layout.outlinedBoxes.allSatisfy { $0.depth <= TreemapMetrics.directoryOutlineMaximumDepth },
            "outlines are capped at three levels below the root"
        )
    }

    func test_everyResizeRecomputesFromScratchWithNoStaleGeometry() async throws {
        let fixture = try await makeTwoFileFixture()
        let context = SelectionContext(rootURL: fixture.root, rootNode: fixture.rootNode)
        let (view, _) = makeView(root: fixture.rootNode, context: context, appearance: .light)

        for size in [NSSize(width: 400, height: 300), NSSize(width: 137, height: 613), NSSize(width: 60, height: 40)] {
            view.setFrameSize(size)
            let layout = try XCTUnwrap(view.currentLayout())
            let root = try XCTUnwrap(layout.boxes.first)
            XCTAssertEqual(root.frame.width, Double(size.width), accuracy: 0.0001)
            XCTAssertEqual(root.frame.height, Double(size.height), accuracy: 0.0001)
            XCTAssertEqual(
                layout.statistics.coveredArea,
                Double(size.width * size.height),
                accuracy: 0.5,
                "the visible boxes must still cover 100% of the new viewport"
            )
        }
    }
}

@MainActor
final class TreemapAccessibilityTests: XCTestCase {
    private func makeFixture() async throws -> ScannedFixture {
        try await ScannedFixture.make(in: self) { root in
            let folder = try makeDirectory("assets", in: root)
            try writeFile("one.png", bytes: 300_000, in: folder)
            try writeFile("two.png", bytes: 300_000, in: folder)
            try writeFile("outside.mp4", bytes: 400_000, in: root)
        }
    }

    func test_thereIsOneElementPerLabelledRectangleInDrawOrder() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let view = workspace.treemapViewController.treemapView

        let layout = try XCTUnwrap(view.currentLayout())
        let elements = view.accessibilityRectangleElements()
        let published = layout.boxes.filter(\.fitsLabel)

        XCTAssertEqual(
            elements.count,
            published.count,
            "one child per rectangle a user can point at and read"
        )
        XCTAssertLessThan(
            published.count,
            layout.boxes.count,
            """
            the subdivided directory regions must not be published: they carry no label, \
            no click can select one, and publishing every rectangle cost a screen-reader \
            user 7–8 s of main thread on a whole-volume map
            """
        )
        let builder = InspectorContentBuilder(formatter: DisplayFormatter(locale: Locale(identifier: "en_US")))
        for (element, box) in zip(elements, published) {
            if let node = box.node {
                XCTAssertEqual(element.accessibilityLabel(), builder.accessibilityLabel(for: .node(node.node)))
            } else {
                XCTAssertTrue(try XCTUnwrap(element.accessibilityLabel()).contains("merged items"))
            }
            XCTAssertEqual(
                element.accessibilityFrameInParentSpace().size.width,
                CGFloat(box.frame.width),
                accuracy: 0.001,
                "each element must be the size of the rectangle it stands for"
            )
        }
    }

    /// The one exception to the label rule, and the reason it is safe: a
    /// rectangle too small to label is not published — until it is selected,
    /// which is how a selection made in the tree stays nameable in the map.
    func test_aRectangleTooSmallToLabelIsPublishedOnlyWhileItIsSelected() async throws {
        // A spread of sizes rather than one chosen pair: which rectangle lands
        // between the merge threshold and the label threshold is the layout's
        // business, so the test finds one instead of predicting it.
        let fixture = try await ScannedFixture.make(in: self) { root in
            var bytes = 4_000_000
            for index in 0..<9 {
                try writeFile(String(format: "%02d.bin", index), bytes: bytes, in: root)
                bytes /= 2
            }
        }
        let (workspace, _, _) = fixture.makeWorkspace()
        let view = workspace.treemapViewController.treemapView

        let layout = try XCTUnwrap(view.currentLayout())
        let box = try XCTUnwrap(
            layout.boxes.first { $0.node != nil && !$0.fitsLabel },
            "the fixture must produce a rectangle of its own that is too small to label"
        )
        let small = try XCTUnwrap(box.node?.node)

        func elementForSmall() -> TreemapAccessibilityElement? {
            view.accessibilityRectangleElements().first {
                $0.accessibilityLabel()?.hasPrefix(small.name) == true
            }
        }

        XCTAssertNil(elementForSmall(), "an unlabelled rectangle is not published")

        workspace.selectionModel.select(.node(small), source: .tree)

        XCTAssertNotNil(elementForSmall(), "the selected rectangle is published however small")
        XCTAssertEqual(elementForSmall()?.isAccessibilitySelected(), true)
    }

    func test_anElementIsFocusableAndSelectsWhenPressed() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let view = workspace.treemapViewController.treemapView
        let node = try fixture.node(named: "outside.mp4")

        let element = try XCTUnwrap(
            view.accessibilityRectangleElements().first {
                $0.accessibilityLabel()?.hasPrefix("outside.mp4") == true
            }
        )

        XCTAssertFalse(element.isAccessibilityFocused())
        element.setAccessibilityFocused(true)
        XCTAssertTrue(element.isAccessibilityFocused(), "the rectangles must accept keyboard focus")

        XCTAssertTrue(element.accessibilityPerformPress())
        XCTAssertTrue(workspace.selectionModel.selection?.node === node)
    }

    func test_selectedStateFollowsTheSharedSelection() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let view = workspace.treemapViewController.treemapView
        let node = try fixture.node(named: "outside.mp4")

        workspace.selectionModel.select(.node(node), source: .tree)

        let selected = view.accessibilityRectangleElements().filter { $0.isAccessibilitySelected() }
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.accessibilityLabel()?.hasPrefix("outside.mp4"), true)
    }

    func test_aSharedSelectionChangeIsAnnouncedOnce() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, announcer) = fixture.makeWorkspace()
        let node = try fixture.node(named: "outside.mp4")

        workspace.selectionModel.select(.node(node), source: .tree)

        XCTAssertEqual(announcer.messages.count, 1)
        XCTAssertTrue(try XCTUnwrap(announcer.messages.first).contains("outside.mp4"))
    }

    func test_theTreemapItselfIsAFocusableAccessibilityGroup() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let view = workspace.treemapViewController.treemapView

        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .group)
        XCTAssertTrue(view.acceptsFirstResponder, "keyboard navigation lives in the tree, but the map is focusable")
        XCTAssertEqual((view.accessibilityChildren() as? [TreemapAccessibilityElement])?.isEmpty, false)
    }
}

private extension NSColor {
    /// Largest per-channel difference, in sRGB — enough to say "these two
    /// pixels are not the same colour" without asserting an exact value.
    func difference(from other: NSColor) -> CGFloat {
        guard let lhs = usingColorSpace(.sRGB), let rhs = other.usingColorSpace(.sRGB) else { return 1 }
        return max(
            abs(lhs.redComponent - rhs.redComponent),
            max(
                abs(lhs.greenComponent - rhs.greenComponent),
                abs(lhs.blueComponent - rhs.blueComponent)
            )
        )
    }
}
