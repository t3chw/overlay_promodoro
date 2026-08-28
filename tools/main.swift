import SwiftUI
import AppKit

// Renders the timer face offscreen so the design can be inspected without
// screen-recording permission. Materials render flat here (they have no real
// backdrop to sample), but layout, shadow, colour and typography are true.

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

let store = UserDefaults(suiteName: "dev.local.pomodoro.preview")!
UserDefaults.standard.removePersistentDomain(forName: "dev.local.pomodoro.preview")

// The engines must be started BEFORE the wait below. Building them inside a
// ForEach body doesn't work: SwiftUI evaluates that lazily at render time, so
// every clock would start after the wait and every ring would render full.
final class DialSpec: Identifiable {
    let id: String
    let prefs: Prefs
    let engine: TimerEngine
    let size: Double
    let hover: Bool

    init(size: Double, hover: Bool, theme: String) {
        self.id = "\(size)-\(hover)"
        self.size = size
        self.hover = hover
        let p = Prefs(defaults: UserDefaults(suiteName: "preview.\(size).\(hover)")!)
        p.size = size
        p.themeID = theme
        p.focusMinutes = 1              // unused once a task is active
        self.prefs = p
        // Every dial carries an active task, so the size sweep also proves the
        // task name survives down to the smallest dial.
        let store2 = TaskStore(defaults: UserDefaults(suiteName: "preview.t.\(size).\(hover)")!)
        let t = store2.add(title: "Write the spec", minutes: 45)!
        store2.activate(t.id)
        self.engine = TimerEngine(prefs: p, stats: Stats(defaults: store), tasks: store2)
    }
}

let dialSizes: [Double] = [130, 150, 210, 300]
let specs: [DialSpec] = dialSizes.flatMap { s in
    [false, true].map { DialSpec(size: s, hover: $0, theme: "ember") }
}
specs.forEach { $0.engine.start() }

let sheet = VStack(spacing: 12) {
    ForEach([false, true], id: \.self) { hover in
        HStack(spacing: 8) {
            ForEach(specs.filter { $0.hover == hover }) { spec in
                VStack(spacing: 4) {
                    ZStack {
                        Color(hex: 0x2A2A2E)
                        PomodoroView(engine: spec.engine, prefs: spec.prefs, previewHover: hover)
                    }
                    .frame(width: 380, height: 380)
                    Text("\(Int(spec.size)) pt · \(hover ? "hover" : "idle")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
.padding(14)
.background(Color(hex: 0x141416))

// Give the running engines a moment so the ring is partly depleted.
RunLoop.main.run(until: Date().addingTimeInterval(18))   // 60s phase -> ~70% left

// ImageRenderer is main-actor isolated; top-level code already runs on the
// main thread, so assert that rather than hopping.
let result: (Data, CGSize)? = MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: sheet)
    renderer.scale = 2
    guard let img = renderer.nsImage,
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return nil }
    return (png, img.size)
}

guard let (png, size) = result else { print("render failed"); exit(1) }
let out = "build/preview.png"
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out) — \(Int(size.width))x\(Int(size.height))pt")

// Second sheet: the settings window.
// A separate suite: the dial shots above write their own sizes and durations
// into `store`, which would show up here as nonsense slider values.
let settingsSuite = "dev.local.pomodoro.preview.settings"
UserDefaults.standard.removePersistentDomain(forName: settingsSuite)
let sStore = UserDefaults(suiteName: settingsSuite)!
let sPrefs = Prefs(defaults: sStore)
let sStats = Stats(defaults: sStore)
for back in 0..<9 {
    let day = Calendar.current.date(byAdding: .day, value: -back, to: Date())!
    for _ in 0..<((back * 3) % 7) { sStats.record(minutes: 25, on: day) }
}
let sEngine = TimerEngine(prefs: sPrefs, stats: sStats)
sPrefs.themeID = "ember"

// Form and TabView are AppKit-backed, so ImageRenderer draws nothing. Host the
// four tab bodies in a real (offscreen) window and snapshot the layer tree
// instead — cacheDisplay works on our own views without any permission.
NSApp.setActivationPolicy(.accessory)

let sTasks = TaskStore(defaults: sStore)
_ = sTasks.add(title: "Ship the release notes", minutes: 25)
let sSpec = sTasks.add(title: "Write the spec", minutes: 45)!
sTasks.activate(sSpec.id)
sTasks.creditActive(minutes: 90)
let sHotKeys = HotKeyManager()

let tabs = HStack(alignment: .top, spacing: 0) {
    TimerTab(prefs: sPrefs).frame(width: 460)
    TasksTab(tasks: sTasks, prefs: sPrefs, engine: sEngine).frame(width: 460)
    AppearanceTab(prefs: sPrefs).frame(width: 460)
    BehaviorTab(prefs: sPrefs, hotKeys: sHotKeys).frame(width: 460)
    StatsTab(prefs: sPrefs, stats: sStats, engine: sEngine, tasks: sTasks).frame(width: 460)
}

let win = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: 2300, height: 540),
                   styleMask: [.titled], backing: .buffered, defer: false)
win.appearance = NSAppearance(named: .darkAqua)
win.contentView = NSHostingView(rootView: tabs)
win.orderFront(nil)
RunLoop.main.run(until: Date().addingTimeInterval(1.5))   // let SwiftUI settle

if let cv = win.contentView,
   let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
    cv.cacheDisplay(in: cv.bounds, to: rep)
    if let data = rep.representation(using: .png, properties: [:]) {
        try data.write(to: URL(fileURLWithPath: "build/settings.png"))
        print("wrote build/settings.png — \(rep.pixelsWide)x\(rep.pixelsHigh)px")
    } else { print("settings encode failed") }
} else { print("settings snapshot failed") }

// Prove the grip renders ABOVE the SwiftUI dial. This is the exact hierarchy
// buildPanel() constructs; the previous version parented the grip to the
// hosting view, which composited its content over it.
let gSide: CGFloat = 210
let gPrefs = Prefs(defaults: UserDefaults(suiteName: "preview.griptest")!)
gPrefs.size = Double(gSide)
let gEngine = TimerEngine(prefs: gPrefs, stats: Stats(defaults: store))
let gHost = NSHostingView(rootView: PomodoroView(engine: gEngine, prefs: gPrefs,
                                                 previewHover: true))
gHost.frame = NSRect(x: 0, y: 0, width: gSide, height: gSide)
let gGrip = ResizeGripView(frame: .zero)
gGrip.alphaValue = 1
let d: CGFloat = 24
gGrip.frame = NSRect(x: gSide * 0.82 - d / 2, y: gSide * 0.18 - d / 2, width: d, height: d)

let gContainer = NSView(frame: NSRect(x: 0, y: 0, width: gSide, height: gSide))
gContainer.addSubview(gHost)
gContainer.addSubview(gGrip, positioned: .above, relativeTo: gHost)

let gWin = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: gSide, height: gSide),
                    styleMask: [.borderless], backing: .buffered, defer: false)
gWin.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1)
gWin.appearance = NSAppearance(named: .darkAqua)
gWin.contentView = gContainer
gWin.orderFront(nil)
RunLoop.main.run(until: Date().addingTimeInterval(1.2))

if let cv = gWin.contentView,
   let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
    cv.cacheDisplay(in: cv.bounds, to: rep)
    if let data = rep.representation(using: .png, properties: [:]) {
        try data.write(to: URL(fileURLWithPath: "build/grip.png"))
        print("wrote build/grip.png — \(rep.pixelsWide)x\(rep.pixelsHigh)px")
    }
}


// MARK: - Task drawer + dial together
//
// Rendered through a real window rather than ImageRenderer: the drawer contains
// a TextField and Menus, which are AppKit-backed and render blank offscreen.

let tSuite = "dev.local.pomodoro.preview.tasks"
UserDefaults.standard.removePersistentDomain(forName: tSuite)
let tStore = UserDefaults(suiteName: tSuite)!

let tPrefs = Prefs(defaults: tStore)
tPrefs.size = 164
tPrefs.themeID = "ember"
let tTasks = TaskStore(defaults: tStore)
let tStats = Stats(defaults: tStore)

let done = tTasks.add(title: "Stand-up notes", minutes: 15, color: 0x9ACD3C)!
_ = tTasks.add(title: "Review the pull request", minutes: 25, color: 0xFF4E8B)
_ = tTasks.add(title: "Sketch the onboarding flow", minutes: 50, color: 0xFFA92E)
// Deliberately not the Ember theme colour, so the ring proves it follows the
// task rather than the theme.
let spec = tTasks.add(title: "Write the spec", minutes: 45, color: 0x6A7BFF)!
tTasks.toggleDone(done.id)
tTasks.activate(spec.id)
tTasks.creditActive(minutes: 90)

let tEngine = TimerEngine(prefs: tPrefs, stats: tStats, tasks: tTasks)
let tUI = UIState()
tUI.drawerOpen = true
tEngine.focus(on: spec.id)

let dialSide: CGFloat = 164
let drawerH = TaskDrawerView.height(for: tTasks.items.count)
let compW: CGFloat = 420
let compH = dialSide + 6 + drawerH + 32

let dialHost = NSHostingView(rootView:
    PomodoroView(engine: tEngine, prefs: tPrefs, ui: tUI, previewHover: true))
dialHost.frame = NSRect(x: (compW - dialSide) / 2, y: compH - dialSide - 16,
                        width: dialSide, height: dialSide)

let drawerHost = NSHostingView(rootView:
    TaskDrawerView(tasks: tTasks, prefs: tPrefs, engine: tEngine))
drawerHost.frame = NSRect(x: (compW - TaskDrawerView.width) / 2, y: 16,
                          width: TaskDrawerView.width, height: drawerH)

let compContainer = NSView(frame: NSRect(x: 0, y: 0, width: compW, height: compH))
compContainer.wantsLayer = true
compContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
compContainer.addSubview(dialHost)
compContainer.addSubview(drawerHost)

let compWin = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: compW, height: compH),
                       styleMask: [.borderless], backing: .buffered, defer: false)
compWin.appearance = NSAppearance(named: .darkAqua)
compWin.contentView = compContainer
compWin.orderFront(nil)
RunLoop.main.run(until: Date().addingTimeInterval(2.0))

if let cv = compWin.contentView,
   let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
    cv.cacheDisplay(in: cv.bounds, to: rep)
    if let data = rep.representation(using: .png, properties: [:]) {
        try data.write(to: URL(fileURLWithPath: "build/tasks.png"))
        print("wrote build/tasks.png — \(rep.pixelsWide)x\(rep.pixelsHigh)px")
    }
}
UserDefaults.standard.removePersistentDomain(forName: tSuite)


// MARK: - The real settings window
//
// The side-by-side sheet above shows tab *contents*; this renders the actual
// SettingsView so the TabView's own chrome is visible. That chrome is what
// silently collapsed into a "»" overflow when the window was too narrow.

let realSettings = NSWindow(
    contentRect: NSRect(x: -6000, y: 0, width: 700, height: 560),
    styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
realSettings.title = "Pomodoro Settings"
realSettings.appearance = NSAppearance(named: .darkAqua)
realSettings.contentView = NSHostingView(rootView:
    SettingsView(prefs: sPrefs, stats: sStats, engine: sEngine,
                 hotKeys: sHotKeys, tasks: sTasks))
realSettings.orderFront(nil)
RunLoop.main.run(until: Date().addingTimeInterval(2.0))

// The tab control lives in the window's title bar, not the content view, so
// snapshot the frame view (contentView.superview) to capture the whole window.
if let frameView = realSettings.contentView?.superview,
   let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
    frameView.cacheDisplay(in: frameView.bounds, to: rep)
    if let data = rep.representation(using: .png, properties: [:]) {
        try data.write(to: URL(fileURLWithPath: "build/settings-window.png"))
        print("wrote build/settings-window.png — \(rep.pixelsWide)x\(rep.pixelsHigh)px")
    }
}
