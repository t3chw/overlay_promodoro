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

enum DrawerLayout {
    /// Where the task drawer sits relative to the dial.
    ///
    /// Normally centred just under the disc. The dial window carries a
    /// transparent shadow margin, so `margin` is subtracted to hang the drawer
    /// off the *visible* edge rather than the invisible window bound. If there
    /// isn't room below — dial parked at the bottom of the screen — it flips
    /// above instead, then clamps into the visible frame either way.
    ///
    /// Screen coordinates, y increasing upward.
    static func frame(dial: CGRect,
                      screen: CGRect,
                      width: CGFloat,
                      height: CGFloat,
                      margin: CGFloat,
                      gap: CGFloat) -> CGRect {
        var x = dial.midX - width / 2
        var y = dial.minY + margin - gap - height

        if y < screen.minY + 8 {
            y = dial.maxY - margin + gap          // flip above the dial
        }

        x = min(max(x, screen.minX + 8), max(screen.minX + 8, screen.maxX - width - 8))
        y = min(max(y, screen.minY + 8), max(screen.minY + 8, screen.maxY - height - 8))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
