import AppKit
import ScanCore
import TreemapLayout
import XCTest
@testable import MacDirStat

/// The treemap view's half of ticket 14: the layout is asked for, not computed
/// here.
///
/// The engine's bound and the coordinator's coalescing are proven in
/// `TreemapLayout`'s own suite, where they can be measured without a window.
/// What only the app can answer is whether the view actually *uses* that path —
/// and what it puts on screen in the gap between asking and being answered,
/// which is a state the old synchronous view never had.
@MainActor
final class TreemapThreadingTests: XCTestCase {
    private func fixture() async throws -> ScannedFixture {
        try await ScannedFixture.make(in: self) { root in
            try writeFile("large.mp4", bytes: 800_000, in: root)
            let folder = try makeDirectory("docs", in: root)
            try writeFile("paper.pdf", bytes: 200_000, in: folder)
            for index in 1...40 {
                try writeFile("tiny-\(index).bin", bytes: 32, in: root)
            }
        }
    }

    private func makeView(root: ScanNode) -> TreemapView {
        let view = TreemapView(frame: NSRect(x: 0, y: 0, width: 520, height: 390))
        view.contentBuilder = InspectorContentBuilder(formatter: DisplayFormatter(locale: Locale(identifier: "en_US")))
        view.selectionModel = SelectionModel()
        view.backingScaleOverride = 2
        view.setRoot(root)
        return view
    }

    /// The claim in one assertion: setting a tree does not lay it out. If the
    /// view still computed inside its own call stack, this would be non-nil.
    func test_settingATreeDoesNotLayItOutOnTheCallingThread() async throws {
        let fixture = try await fixture()
        let view = makeView(root: fixture.rootNode)

        XCTAssertNil(view.currentLayout(), "the layout ran on the thread that asked for it")

        await view.settleLayout()
        let settled = try XCTUnwrap(view.currentLayout())
        XCTAssertGreaterThan(settled.boxes.count, 1)
        XCTAssertEqual(settled.viewport, TreemapSize(width: 520, height: 390))
    }

    /// Background and inline must produce the same picture — otherwise every
    /// geometry assertion in this target, which runs inline, would be about a
    /// different app than the one that ships.
    func test_theBackgroundLayoutIsTheSameGeometryTheInlineOneProduces() async throws {
        let fixture = try await fixture()

        let background = makeView(root: fixture.rootNode)
        await background.settleLayout()

        let inline = TreemapView(frame: NSRect(x: 0, y: 0, width: 520, height: 390))
        inline.layoutExecution = .immediate
        inline.setRoot(fixture.rootNode)

        let a = try XCTUnwrap(background.currentLayout())
        let b = try XCTUnwrap(inline.currentLayout())
        XCTAssertEqual(a.boxes.map(\.frame), b.boxes.map(\.frame))
        XCTAssertEqual(a.statistics, b.statistics)
    }

    /// Hit testing, hover and accessibility must never answer for a rectangle
    /// that is not on screen. Between a resize and the layout for that size
    /// landing, the honest answer is "nothing".
    func test_aStaleViewportIsNotOfferedToHitTestingOrAccessibility() async throws {
        let fixture = try await fixture()
        let view = makeView(root: fixture.rootNode)
        await view.settleLayout()
        XCTAssertNotNil(view.boxIndex(at: NSPoint(x: 100, y: 100)))

        view.setFrameSize(NSSize(width: 900, height: 600))

        XCTAssertNil(view.currentLayout(), "geometry for the old size must not answer for the new one")
        XCTAssertNil(view.boxIndex(at: NSPoint(x: 100, y: 100)))
        XCTAssertTrue(view.accessibilityRectangleElements().isEmpty)

        await view.settleLayout()
        XCTAssertEqual(view.currentLayout()?.viewport, TreemapSize(width: 900, height: 600))
        XCTAssertNotNil(view.boxIndex(at: NSPoint(x: 100, y: 100)))
        XCTAssertFalse(view.accessibilityRectangleElements().isEmpty)
    }

    /// What the user sees in that same gap. A resize must not blank the map —
    /// during a divider drag the layout is always one step behind, so "draw
    /// nothing until it lands" would be a flicker on every frame.
    func test_aResizeShowsAStretchedPreviewRatherThanAnEmptyMap() async throws {
        let fixture = try await fixture()
        let view = makeView(root: fixture.rootNode)
        view.appearanceOverride = .light
        await view.settleLayout()

        view.setFrameSize(NSSize(width: 900, height: 600))
        XCTAssertNil(view.currentLayout(), "the premise: no layout for this size yet")

        let painted = try render(view)
        let background = TreemapChrome.voidBackground(.light).usingColorSpace(.sRGB)
        var coloured = 0
        for point in [NSPoint(x: 60, y: 60), NSPoint(x: 450, y: 300), NSPoint(x: 800, y: 520)] {
            let pixel = try colour(of: painted, at: point, in: view)
            if abs(pixel.redComponent - (background?.redComponent ?? 0)) > 0.02
                || abs(pixel.greenComponent - (background?.greenComponent ?? 0)) > 0.02 {
                coloured += 1
            }
        }
        XCTAssertEqual(coloured, 3, "the whole map went blank while waiting for a layout")
    }

    /// The preview is a picture and nothing more: it never becomes the answer
    /// to a question about where a rectangle is.
    func test_thePreviewIsNeverAdoptedAsGeometry() async throws {
        let fixture = try await fixture()
        let view = makeView(root: fixture.rootNode)
        await view.settleLayout()
        let original = try XCTUnwrap(view.currentLayout())

        view.setFrameSize(NSSize(width: 900, height: 600))
        _ = try render(view)

        await view.settleLayout()
        let relaid = try XCTUnwrap(view.currentLayout())
        XCTAssertEqual(relaid.viewport, TreemapSize(width: 900, height: 600))
        XCTAssertNotEqual(
            relaid.boxes.map(\.frame), original.boxes.map(\.frame),
            "the stretched preview was kept instead of the real relayout"
        )
        // Area truthfulness survives the round trip (§6.1).
        XCTAssertEqual(
            relaid.statistics.coveredArea, 900 * 600,
            accuracy: 900 * 600 * 1e-6
        )
    }

    // MARK: - Rendering helpers

    private func render(_ view: TreemapView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.backingScaleOverride = Double(CGFloat(rep.pixelsWide) / view.bounds.width)
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func colour(of rep: NSBitmapImageRep, at point: NSPoint, in view: TreemapView) throws -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let x = min(rep.pixelsWide - 1, max(0, Int(point.x * scale)))
        let y = min(rep.pixelsHigh - 1, max(0, Int(point.y * scale)))
        return try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }
}
