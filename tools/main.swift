import SwiftUI
import AppKit

// Renders the timer face offscreen so the design can be inspected without
// screen-recording permission. Materials render flat here (they have no real
// backdrop to sample), but layout, shadow, colour and typography are true.

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

let store = UserDefaults(suiteName: "dev.local.pomodoro.preview")!
UserDefaults.standard.removePersistentDomain(forName: "dev.local.pomodoro.preview")

func shot(size: Double, theme: String, bg: Color, hover: Bool, label: String) -> some View {
    let sPrefs = Prefs(defaults: UserDefaults(suiteName: "preview.\(size).\(hover)")!)
    sPrefs.size = size
    sPrefs.themeID = theme
    sPrefs.focusMinutes = 20                  // arc lands mid-sweep after the wait
    let engine = TimerEngine(prefs: sPrefs, stats: Stats(defaults: store))
    engine.start()
    return VStack(spacing: 4) {
        ZStack {
            bg
            PomodoroView(engine: engine, prefs: sPrefs, previewHover: hover)
        }
        .frame(width: 380, height: 380)
        Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

let sizes: [Double] = [130, 150, 210, 300]
let sheet = VStack(spacing: 12) {
    HStack(spacing: 8) {
        ForEach(sizes, id: \.self) { s in
            shot(size: s, theme: "ember", bg: Color(hex: 0x2A2A2E), hover: false,
                 label: "\(Int(s)) pt · idle")
        }
    }
    HStack(spacing: 8) {
        ForEach(sizes, id: \.self) { s in
            shot(size: s, theme: "ember", bg: Color(hex: 0x2A2A2E), hover: true,
                 label: "\(Int(s)) pt · hover")
        }
    }
}
.padding(14)
.background(Color(hex: 0x141416))

// Give the running engines a moment so the ring is partly depleted.
RunLoop.main.run(until: Date().addingTimeInterval(4.2))

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

let tabs = HStack(alignment: .top, spacing: 0) {
    TimerTab(prefs: sPrefs).frame(width: 460)
    AppearanceTab(prefs: sPrefs).frame(width: 460)
    BehaviorTab(prefs: sPrefs).frame(width: 460)
    StatsTab(prefs: sPrefs, stats: sStats, engine: sEngine).frame(width: 460)
}

let win = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: 1840, height: 540),
                   styleMask: [.titled], backing: .buffered, defer: false)
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
