import AppKit
import SwiftUI
import Combine

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let prefs  = Prefs.shared
    private let stats  = Stats.shared
    private lazy var engine = TimerEngine(prefs: prefs, stats: stats)

    private var panel: NSPanel!
    private var host: NSHostingView<PomodoroView>!
    private var grip: ResizeGripView!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private let hotKeys = HotKeyManager()

    private var bag = Set<AnyCancellable>()
    private var titleTimer: Timer?
    private var mouseMonitors: [Any] = []

    private var lastShownSecond = -1
    private var pointerInside = false
    private var isSnapping = false
    private var isResizing = false
    /// Window top-left at grab time, plus where the cursor sat relative to the
    /// grip's centre — together these let the grip track the pointer exactly.
    private var resizeAnchor: (topLeft: NSPoint, grabOffset: NSPoint)?

    /// Grip centre as a fraction of the window's side, measured from top-left.
    /// Just outside the disc's 45° edge (the disc reaches 0.79 there).
    private let gripFraction: CGFloat = 0.82

    func applicationDidFinishLaunching(_ note: Notification) {
        // Accessory: no Dock icon, no app-switcher entry, never steals focus
        // from whatever you're actually working in.
        NSApp.setActivationPolicy(.accessory)

        engine.onPhaseChange = { [weak self] phase in self?.announce(phase) }

        buildPanel()
        buildStatusItem()
        installPointerTracking()
        observePrefs()
        startTitleTimer()
        applyHotKeys()
        applyPrefs()
    }

    func applicationWillTerminate(_ note: Notification) {
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        hotKeys.disable()
    }

    // MARK: Floating panel

    private func buildPanel() {
        let side = CGFloat(prefs.size)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Validated by the spike: above every ordinary window, present in every
        // Space, and drawn over other apps' full-screen spaces.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false            // the SwiftUI circle casts its own
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false

        let view = PomodoroView(
            engine: engine,
            prefs: prefs,
            onHoverChange: { [weak self] inside in self?.setPointerInside(inside) },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: side, height: side)
        host.autoresizingMask = [.width, .height]

        grip = ResizeGripView(frame: .zero)
        grip.alphaValue = 0
        grip.onBegin = { [weak self] in self?.beginResize() }
        grip.onDrag  = { [weak self] p in self?.resize(toward: p) }
        grip.onEnd   = { [weak self] in self?.endResize() }

        // The grip is a *sibling* of the hosting view, not a child of it:
        // NSHostingView composites its SwiftUI content over any subview added
        // to it, which left the grip invisible.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        container.addSubview(host)
        container.addSubview(grip, positioned: .above, relativeTo: host)
        panel.contentView = container
        layoutGrip()

        panel.setFrameOrigin(restoredOrigin())
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self, selector: #selector(panelMoved),
            name: NSWindow.didMoveNotification, object: panel)
    }

    /// Restore the last position, but only if it still lands on a screen —
    /// otherwise an unplugged monitor would strand the timer off-canvas.
    private func restoredOrigin() -> NSPoint {
        let side = CGFloat(prefs.size)
        if let saved = prefs.origin {
            let rect = NSRect(origin: saved, size: NSSize(width: side, height: side))
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { return saved }
        }
        return defaultOrigin()
    }

    private func defaultOrigin() -> NSPoint {
        guard let vf = NSScreen.main?.visibleFrame else { return NSPoint(x: 60, y: 60) }
        let side = CGFloat(prefs.size)
        return NSPoint(x: vf.maxX - side - 24, y: vf.maxY - side - 16)
    }

    @objc private func panelMoved() {
        guard !isSnapping, !isResizing else { return }
        if prefs.snapToEdges { snapToEdge() }
        prefs.origin = panel.frame.origin
    }

    /// Magnetic edges: within 18pt of a screen edge, sit flush against it.
    private func snapToEdge() {
        let f = panel.frame
        guard let vf = (NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main)?.visibleFrame
        else { return }

        let t: CGFloat = 18
        var o = f.origin
        if abs(f.minX - vf.minX) < t { o.x = vf.minX }
        if abs(f.maxX - vf.maxX) < t { o.x = vf.maxX - f.width }
        if abs(f.minY - vf.minY) < t { o.y = vf.minY }
        if abs(f.maxY - vf.maxY) < t { o.y = vf.maxY - f.height }

        guard o != f.origin else { return }
        isSnapping = true
        panel.setFrameOrigin(o)
        isSnapping = false
    }

    // MARK: Resizing

    private func beginResize() {
        isResizing = true
        let f = panel.frame
        let topLeft = NSPoint(x: f.minX, y: f.maxY)
        let gripCentre = ResizeMath.gripCentre(topLeft: topLeft, side: f.width,
                                              gripFraction: gripFraction)
        let m = NSEvent.mouseLocation
        resizeAnchor = (topLeft, NSPoint(x: m.x - gripCentre.x, y: m.y - gripCentre.y))
        grip.alphaValue = 1
    }

    /// Absolute mapping rather than a delta: the size is derived from where the
    /// cursor is relative to the (fixed) top-left corner, so the grip stays
    /// pinned under the pointer whether you drag out or back in.
    private func resize(toward mouse: NSPoint) {
        guard let a = resizeAnchor else { return }
        let target = ResizeMath.side(topLeft: a.topLeft, grabOffset: a.grabOffset,
                                     mouse: mouse, gripFraction: gripFraction)
        let clamped = min(max(target, Prefs.sizeRange.lowerBound), Prefs.sizeRange.upperBound)

        guard abs(clamped - prefs.size) > 0.5 else { return }
        prefs.size = clamped
        applySize()          // immediately, not via the objectWillChange hop
    }

    private func endResize() {
        isResizing = false
        resizeAnchor = nil
        prefs.origin = panel.frame.origin
        if prefs.snapToEdges { snapToEdge() }
        grip.alphaValue = pointerInside ? 1 : 0
    }

    private func layoutGrip() {
        let side = CGFloat(prefs.size)
        let d = max(21, 24 * (side / 210))
        // Content view coordinates are bottom-left origin.
        let cx = side * gripFraction
        let cy = side * (1 - gripFraction)
        grip.frame = NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
        grip.needsLayout = true
        panel.invalidateCursorRects(for: grip)
    }

    // MARK: Applying preferences

    private func observePrefs() {
        // objectWillChange fires *before* the value lands, so hop the main queue
        // before reading it back. DispatchQueue rather than RunLoop: RunLoop.main
        // stalls in .eventTracking mode, which would freeze live slider preview.
        prefs.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyPrefs() }
            .store(in: &bag)
    }

    private func applyHotKeys() {
        guard prefs.hotKeysEnabled else { hotKeys.disable(); return }
        hotKeys.enable([
            1: { [weak self] in self?.engine.toggle() },
            2: { [weak self] in self?.engine.skip() },
            3: { [weak self] in self?.engine.reset() },
        ])
    }

    private func applyPrefs() {
        if prefs.hotKeysEnabled != !hotKeys.registered.isEmpty { applyHotKeys() }
        applySize()
        applyAlpha()
        panel.level = prefs.alwaysOnTop ? .floating : .normal
        if !prefs.clickThrough { panel.ignoresMouseEvents = false }
        if !isResizing { panel.orderFrontRegardless() }
    }

    /// Resize about the top-left corner, so the timer grows down and to the
    /// right instead of drifting up the screen.
    private func applySize() {
        let side = CGFloat(prefs.size)
        let f = panel.frame
        guard abs(f.width - side) > 0.5 else { return }
        panel.setFrame(NSRect(x: f.minX, y: f.maxY - side, width: side, height: side),
                       display: true)
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: side, height: side)
        host.frame = NSRect(x: 0, y: 0, width: side, height: side)
        layoutGrip()
        if !isResizing { prefs.origin = panel.frame.origin }
    }

    private func applyAlpha() {
        let target = (prefs.dimWhenIdle && !pointerInside)
            ? prefs.opacity * prefs.idleOpacity
            : prefs.opacity
        guard abs(panel.alphaValue - target) > 0.001 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = target
        }
    }

    // MARK: Pointer tracking

    /// One pair of monitors drives click-through, idle fading and the grip's
    /// visibility. The global monitor sees the pointer while other apps are
    /// frontmost; the local one keeps firing once the pointer is over our own
    /// panel, which is the only way to notice it leaving again.
    private func installPointerTracking() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.evaluatePointer()
        }) { mouseMonitors.append(g) }

        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.evaluatePointer()
            return event
        }) { mouseMonitors.append(l) }
    }

    private func evaluatePointer() {
        guard !isResizing else { return }   // the grip owns the pointer mid-drag
        let inside = panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        setPointerInside(inside)
    }

    private func setPointerInside(_ inside: Bool) {
        if prefs.clickThrough {
            // Inert until you deliberately reach for it.
            panel.ignoresMouseEvents = !inside
        }
        guard inside != pointerInside else { return }
        pointerInside = inside
        applyAlpha()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            grip.animator().alphaValue = inside ? 1 : 0
        }
    }

    // MARK: Settings window

    private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            w.title = "Pomodoro Settings"
            w.contentView = NSHostingView(
                rootView: SettingsView(prefs: prefs, stats: stats, engine: engine,
                                       hotKeys: hotKeys))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        // .accessory apps need this or the window opens behind everything.
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Pomodoro")
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt on open so titles always match live state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "\(engine.phase.title) · \(engine.display)",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let done = NSMenuItem(title: "\(stats.todaySessions) completed today",
                              action: nil, keyEquivalent: "")
        done.isEnabled = false
        menu.addItem(done)
        menu.addItem(.separator())

        add(menu, engine.isRunning ? "Pause" : "Start", #selector(doToggle))
        add(menu, "Restart Phase", #selector(doReset))
        add(menu, "Skip to Next", #selector(doSkip))
        add(menu, "Reset All Sessions", #selector(doResetAll))
        menu.addItem(.separator())

        let sizes = NSMenu()
        for (name, value) in [("Small", 150.0), ("Medium", 210.0),
                              ("Large", 280.0), ("Extra Large", 360.0)] {
            let item = NSMenuItem(title: name, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(prefs.size - value) < 1 ? .on : .off
            sizes.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        add(menu, "Settings…", #selector(showSettings), key: ",")
        add(menu, "Reset Position", #selector(recenter))
        menu.addItem(.separator())
        add(menu, "Quit Pomodoro", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: Actions

    @objc private func doToggle()   { engine.toggle() }
    @objc private func doReset()    { engine.reset() }
    @objc private func doSkip()     { engine.skip() }
    @objc private func doResetAll() { engine.resetAll() }
    @objc private func showSettings() { openSettings() }
    @objc private func quit()       { NSApp.terminate(nil) }

    @objc private func pickSize(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        prefs.size = value
    }

    @objc private func recenter() {
        panel.setFrameOrigin(defaultOrigin())
        prefs.origin = panel.frame.origin
        panel.orderFrontRegardless()
    }

    // MARK: Menu bar title

    private func startTitleTimer() {
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshStatusTitle()
        }
        RunLoop.main.add(t, forMode: .common)
        titleTimer = t
        refreshStatusTitle()
    }

    private func refreshStatusTitle() {
        let second = Int(engine.remaining.rounded(.up))
        guard second != lastShownSecond else { return }
        lastShownSecond = second
        statusItem.button?.title = " " + engine.display
        let symbol = engine.isRunning ? engine.phase.symbol : "timer"
        statusItem.button?.image =
            NSImage(systemSymbolName: symbol, accessibilityDescription: engine.phase.title)
    }

    // MARK: Transitions

    private func announce(_ phase: Phase) {
        guard prefs.soundEnabled else { return }
        NSSound(named: NSSound.Name(prefs.soundName))?.play()
    }
}

// MARK: - Launch

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
