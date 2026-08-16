import Foundation

/// A point in the treemap's unrounded point space.
///
/// The package owns its geometry types rather than borrowing CoreGraphics',
/// because it must not link a drawing framework (spec §4.2, §10). The view
/// layer converts to `CGPoint`/`CGRect` at the boundary.
public struct TreemapPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A size in unrounded points — the viewport the layout is computed against.
public struct TreemapSize: Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }

    /// Whether a layout can be computed at all: a zero or negative dimension
    /// has no interior to tile.
    public var isDrawable: Bool { width > 0 && height > 0 }
}

/// A rectangle in unrounded points, origin top-left, y growing downward — the
/// same orientation the treemap view draws in.
///
/// **Unrounded on purpose** (spec §6.1): the layout never snaps, so identical
/// trees produce identical rectangles regardless of the display they will land
/// on. Pixel-grid snapping happens at draw time only, through
/// ``snapped(toBackingScale:)``.
public struct TreemapRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: TreemapPoint, size: TreemapSize) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public static let zero = TreemapRect(x: 0, y: 0, width: 0, height: 0)

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var area: Double { width * height }
    public var size: TreemapSize { TreemapSize(width: width, height: height) }
    public var origin: TreemapPoint { TreemapPoint(x: x, y: y) }

    /// The shorter of the two dimensions — what the merge rule measures a
    /// candidate rectangle by (spec §6.2).
    public var shortestSide: Double { Swift.min(width, height) }

    /// Half-open containment: `[minX, maxX) × [minY, maxY)`.
    ///
    /// Half-open is what makes hit testing unambiguous on a shared edge — two
    /// abutting rectangles never both claim the same point, so the deepest-node
    /// rule in §6.4 stays deterministic without a tie-break.
    public func contains(_ point: TreemapPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    /// Whether this rectangle lies inside `other`, allowing `tolerance` points
    /// of floating-point slack on each edge.
    public func isContained(in other: TreemapRect, tolerance: Double = 0) -> Bool {
        minX >= other.minX - tolerance
            && minY >= other.minY - tolerance
            && maxX <= other.maxX + tolerance
            && maxY <= other.maxY + tolerance
    }

    /// Whether this rectangle shares interior area with `other`, ignoring
    /// overlaps thinner than `tolerance` (float drift on a shared edge).
    public func overlaps(_ other: TreemapRect, tolerance: Double = 0) -> Bool {
        let horizontal = Swift.min(maxX, other.maxX) - Swift.max(minX, other.minX)
        let vertical = Swift.min(maxY, other.maxY) - Swift.max(minY, other.minY)
        return horizontal > tolerance && vertical > tolerance
    }

    /// The pixel-grid-aligned rectangle for a display of `scale` backing
    /// pixels per point — **draw time only** (spec §6.1).
    ///
    /// Both edges are snapped independently and the extent is taken as the
    /// difference, never the snapped extent: that is what keeps abutting
    /// siblings flush, because a shared edge rounds to the same pixel from
    /// both sides. Snapping the width instead would accumulate seams.
    public func snapped(toBackingScale scale: Double) -> TreemapRect {
        guard scale > 0, scale.isFinite else { return self }
        let left = (x * scale).rounded() / scale
        let top = (y * scale).rounded() / scale
        let right = (maxX * scale).rounded() / scale
        let bottom = (maxY * scale).rounded() / scale
        return TreemapRect(
            x: left,
            y: top,
            width: Swift.max(0, right - left),
            height: Swift.max(0, bottom - top)
        )
    }
}
