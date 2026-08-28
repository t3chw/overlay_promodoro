import AppKit
import SwiftUI
import Combine

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let prefs  = Prefs.shared
    private let tasks  = TaskStore.shared
    private let ui     = UIState()
    private let stats  = Stats.shared
    private lazy var engine = TimerEngine(prefs: prefs, stats: stats, tasks: tasks)

    private var panel: NSPanel!
    private var host: NSHostingView<PomodoroView>!
    private var grip: ResizeGripView!
    private var settingsWindow: NSWindow?
    private var drawer: KeyablePanel?
    private var drawerDismissMonitors: [Any] = []
    private var statusItem: NSStatusItem!
    private let hotKeys = HotKeyManager()
    private var hotKeysActive = false

    private var bag = Set<AnyCancellable>()
    private var titleTimer: Timer?
    private var mouseMonitors: [Any] = []

    private var lastShownSecond = -1
    private var lastShownTask: String?
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

        // Development aid: lets the drawer be inspected without a pointer.
        // Inert unless the variable is set.
        if ProcessInfo.processInfo.environment["POMODORO_DEBUG_DRAWER"] != nil {
            toggleDrawer()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                let report = """
                app active        : \(NSApp.isActive)
                drawer exists     : \(self.drawer != nil)
                drawer canBecomeKey: \(self.drawer?.canBecomeKey ?? false)
                drawer isKeyWindow: \(self.drawer?.isKeyWindow ?? false)
                first responder   : \(String(describing: self.drawer?.firstResponder))
                """
                try? report.write(
                    to: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("pomodoro-drawer.log"),
                    atomically: true, encoding: .utf8)
            }
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        drawerDismissMonitors.forEach { NSEvent.removeMonitor($0) }
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
            ui: ui,
            onToggleDrawer: { [weak self] in self?.toggleDrawer() },
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        ensureOnScreen()
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

    /// Displays can be unplugged or re-resolutioned while we're parked on them.
    @objc private func screensChanged() {
        ensureOnScreen()
        positionDrawer()
        panel.orderFrontRegardless()
    }

    /// Pull the dial fully back into a visible frame. `restoredOrigin` only
    /// checks that the saved rect *intersects* a screen, so a mostly-offscreen
    /// window passes it.
    private func ensureOnScreen() {
        let f = panel.frame
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(f) })
                ?? NSScreen.main else { return }
        let fitted = ScreenFit.clamped(f, into: screen.visibleFrame)
        guard fitted.origin != f.origin else { return }
        isSnapping = true
        panel.setFrameOrigin(fitted.origin)
        isSnapping = false
        prefs.origin = panel.frame.origin
    }

    @objc private func panelMoved() {
        guard !isSnapping, !isResizing else { return }
        if prefs.snapToEdges { snapToEdge() }
        prefs.origin = panel.frame.origin
        positionDrawer()
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

        tasks.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.syncDrawerHeight() }
            .store(in: &bag)
    }

    private func applyHotKeys() {
        hotKeysActive = prefs.hotKeysEnabled
        guard prefs.hotKeysEnabled else { hotKeys.disable(); return }
        hotKeys.enable([
            1: { [weak self] in self?.engine.toggle() },
            2: { [weak self] in self?.engine.skip() },
            3: { [weak self] in self?.engine.reset() },
            4: { [weak self] in self?.toggleDrawer() },
        ])
    }

    private func applyPrefs() {
        if prefs.hotKeysEnabled != hotKeysActive { applyHotKeys() }
        applySize()
        applyAlpha()
        panel.level = prefs.alwaysOnTop ? .floating : .normal
        drawer?.level = panel.level
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
        positionDrawer()
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

    // MARK: Task drawer

    private func toggleDrawer() { drawer == nil ? openDrawer() : closeDrawer() }

    private func openDrawer() {
        let h = TaskDrawerView.height(for: tasks.items.count)
        // Note the absence of .nonactivatingPanel, which the dial does use.
        // A non-activating panel never becomes key while another app is
        // frontmost, so every keystroke went to the editor behind it and the
        // quick-add field looked broken. An NSPanel can become key while
        // borderless, so typing works once the app is activated below.
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: TaskDrawerView.width, height: h),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        p.isFloatingPanel = true
        p.level = prefs.alwaysOnTop ? .floating : .normal
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.worksWhenModal = true
        p.animationBehavior = .none
        p.isReleasedWhenClosed = false
        // Deliberately not dimmed by the opacity setting: this is a surface you
        // read and type into, unlike the dial you glance at.
        p.alphaValue = 1

        p.contentView = NSHostingView(rootView: TaskDrawerView(
            tasks: tasks, prefs: prefs, engine: engine,
            onStart: { [weak self] id in
                self?.engine.focus(on: id)
                self?.closeDrawer()        // you picked a task; get out of the way
            }))

        drawer = p
        positionDrawer()
        p.orderFrontRegardless()
        // Opening the drawer is a deliberate act — you want to type. Activating
        // is the cost of a working text field; closing hands activation back.
        // NSApp.activate() rather than activate(ignoringOtherApps:), which is
        // deprecated from macOS 14 in favour of cooperative activation.
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
        ui.drawerOpen = true
        installDrawerDismissal()
    }

    private func closeDrawer() {
        drawerDismissMonitors.forEach { NSEvent.removeMonitor($0) }
        drawerDismissMonitors.removeAll()
        drawer?.orderOut(nil)
        drawer = nil
        ui.drawerOpen = false
        // Hand focus back to whatever you were working in — unless our own
        // Settings window is open, in which case deactivating would yank it away.
        if settingsWindow?.isVisible != true { NSApp.deactivate() }
    }

    /// Sits just under the disc, centred on it — and flips above when the dial
    /// is parked near the bottom of the screen.
    private func positionDrawer() {
        guard let drawer else { return }
        let dial = panel.frame
        let margin = dial.width * 0.09          // transparent shadow border
        let gap: CGFloat = 6
        let w = TaskDrawerView.width
        let h = drawer.frame.height

        let screen = (NSScreen.screens.first { $0.frame.intersects(dial) } ?? NSScreen.main)
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        drawer.setFrame(DrawerLayout.frame(dial: dial, screen: vf, width: w, height: h,
                                           margin: margin, gap: gap),
                        display: true)
    }

    /// The drawer is sized from the task count rather than SwiftUI's intrinsic
    /// height, so it never shows dead space or a scrollbar it doesn't need.
    private func syncDrawerHeight() {
        guard let drawer else { return }
        let h = TaskDrawerView.height(for: tasks.items.count)
        guard abs(drawer.frame.height - h) > 0.5 else { return }
        var f = drawer.frame
        f.origin.y += f.height - h              // keep the top edge put
        f.size.height = h
        drawer.setFrame(f, display: true)
        positionDrawer()
    }

    private func installDrawerDismissal() {
        if let g = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] _ in self?.closeIfClickedOutside() }
        ) { drawerDismissMonitors.append(g) }

        if let l = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown],
            handler: { [weak self] event in
                if event.type == .keyDown {
                    // Only claim escape when the drawer itself has focus, or it
                    // would hijack the key from the Settings window.
                    if event.keyCode == 53, self?.drawer?.isKeyWindow == true {
                        self?.closeDrawer()
                        return nil
                    }
                    return event
                }
                self?.closeIfClickedOutside()
                return event
            }
        ) { drawerDismissMonitors.append(l) }
    }

    private func closeIfClickedOutside() {
        guard let drawer else { return }
        let m = NSEvent.mouseLocation
        // The dial counts as "inside" so the chevron can toggle it shut itself.
        guard !drawer.frame.contains(m), !panel.frame.contains(m) else { return }
        closeDrawer()
    }

    // MARK: Settings window

    private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            w.title = "Pomodoro Settings"
            w.contentView = NSHostingView(
                rootView: SettingsView(prefs: prefs, stats: stats, engine: engine,
                                       hotKeys: hotKeys, tasks: tasks))
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

        let taskMenu = NSMenu()
        let pending = tasks.ordered.filter { !$0.done }.prefix(8)
        if pending.isEmpty {
            let empty = NSMenuItem(title: "No tasks yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            taskMenu.addItem(empty)
        } else {
            for item in pending {
                let mi = NSMenuItem(title: "\(item.title)  ·  \(TaskDuration.label(item.minutes))",
                                    action: #selector(startTask(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = item.id.uuidString
                mi.state = item.id == tasks.activeID ? .on : .off
                taskMenu.addItem(mi)
            }
        }
        taskMenu.addItem(.separator())
        let showList = NSMenuItem(title: "Show Task List", action: #selector(showDrawer),
                                  keyEquivalent: "")
        showList.target = self
        taskMenu.addItem(showList)
        let tasksItem = NSMenuItem(title: "Tasks", action: nil, keyEquivalent: "")
        tasksItem.submenu = taskMenu
        menu.addItem(tasksItem)

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

    @objc private func startTask(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw)
        else { return }
        engine.focus(on: id)
        closeDrawer()
    }

    @objc private func showDrawer() {
        if drawer == nil { toggleDrawer() }
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
        let task = engine.headlineIsTask ? engine.activeTaskTitle : nil
        // Guard on the task too, or switching tasks wouldn't repaint until the
        // next whole second ticked over.
        guard second != lastShownSecond || task != lastShownTask else { return }
        lastShownSecond = second
        lastShownTask = task

        if let task {
            // Menu bar space is contended; a few words is the most it can spare.
            let short = task.count > 14 ? String(task.prefix(13)) + "…" : task
            statusItem.button?.title = " \(short)   \(engine.display)"
        } else {
            statusItem.button?.title = " " + engine.display
        }
        statusItem.button?.toolTip = engine.activeTaskTitle
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
