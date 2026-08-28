import AppKit

// MARK: - Resize grip

/// Deliberately AppKit rather than a SwiftUI gesture. The SwiftUI version was
/// rebuilt every frame as the window resized underneath it, which cancelled the
/// drag; an NSView keeps mouse tracking for the whole gesture. Handling
/// mouseDown here also stops `isMovableByWindowBackground` from moving the
/// window when you meant to resize it.
final class ResizeGripView: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onEnd: (() -> Void)?

    private let icon = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.40).cgColor
        layer?.borderWidth = 0.6
        icon.imageScaling = .scaleProportionallyUpOrDown
        toolTip = "Drag to resize"
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.95)
        addSubview(icon)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
        let cfg = NSImage.SymbolConfiguration(pointSize: max(7, bounds.width * 0.42),
                                              weight: .bold)
        icon.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right",
                             accessibilityDescription: "Resize")?
            .withSymbolConfiguration(cfg)
        icon.frame = bounds.insetBy(dx: bounds.width * 0.26, dy: bounds.height * 0.26)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) { onBegin?() }
    override func mouseDragged(with event: NSEvent) { onDrag?(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { onEnd?() }
}
