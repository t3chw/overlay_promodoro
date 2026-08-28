import CoreGraphics

enum ResizeMath {
    /// The window side implied by the pointer's position during a grip drag.
    ///
    /// Absolute rather than incremental: the size is derived from where the
    /// pointer sits relative to the window's (fixed) top-left corner, so the
    /// grip stays pinned under the pointer whether you drag outward or back in.
    /// A delta-based mapping made the grip slide away from the cursor, because
    /// the grip only travels `gripFraction` of every point the size grows.
    ///
    /// Screen coordinates, y increasing upward; `topLeft.y` is the window's maxY.
    static func side(topLeft: CGPoint,
                     grabOffset: CGPoint,
                     mouse: CGPoint,
                     gripFraction: CGFloat) -> CGFloat {
        let mx = mouse.x - grabOffset.x
        let my = mouse.y - grabOffset.y
        let fromX = (mx - topLeft.x) / gripFraction
        let fromY = (topLeft.y - my) / gripFraction
        return (fromX + fromY) / 2
    }

    /// Where the grip's centre belongs, in screen coordinates.
    static func gripCentre(topLeft: CGPoint, side: CGFloat,
                           gripFraction: CGFloat) -> CGPoint {
        CGPoint(x: topLeft.x + side * gripFraction,
                y: topLeft.y - side * gripFraction)
    }
}
