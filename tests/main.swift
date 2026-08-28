import Foundation

// Runs against a throwaway defaults domain so the user's real settings are
// never touched. Phase durations floor at 1s in the engine, so a full
// four-session cycle takes ~8 seconds of wall clock.

let suite = "dev.local.pomodoro.tests"
UserDefaults.standard.removePersistentDomain(forName: suite)
let store = UserDefaults(suiteName: suite)!

let prefs = Prefs(defaults: store)
let stats = Stats(defaults: store)
let engine = TimerEngine(prefs: prefs, stats: stats)

prefs.autoAdvance = true
prefs.soundEnabled = false

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label) \(detail)")
    if !ok { failures += 1 }
}
func oneSecondPhases() {
    prefs.focusMinutes = 1.0 / 60
    prefs.shortMinutes = 1.0 / 60
    prefs.longMinutes  = 1.0 / 60
    // Duration edits reach the engine on the next main-queue turn.
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
}

print("defaults + formatting")
check("defaults to 25 minutes", prefs.focusMinutes == 25, "got \(prefs.focusMinutes)")
check("display formats mm:ss", engine.display == "25:00", "got \(engine.display)")
check("formats past an hour", TimerEngine.format(3725) == "1:02:05",
      "got \(TimerEngine.format(3725))")
check("progress starts full", engine.progress == 1.0, "got \(engine.progress)")
check("starts in focus", engine.phase == .focus)
check("idle before start", !engine.isRunning)

print("live duration edits")
prefs.focusMinutes = 30
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
check("idle edit retargets phase", engine.display == "30:00", "got \(engine.display)")

print("pause holds the clock")
engine.start()
RunLoop.main.run(until: Date().addingTimeInterval(0.6))
engine.pause()
let held = engine.remaining
check("countdown advanced", held < 1800 && held > 1799.0, "remaining=\(held)")
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
check("frozen while paused", engine.remaining == held, "drifted to \(engine.remaining)")
engine.reset()
check("reset restores the phase", engine.remaining == 1800, "got \(engine.remaining)")

print("theme lookup")
check("known theme resolves", Theme.by(id: "ocean").name == "Ocean")
check("unknown theme falls back", Theme.by(id: "nope").id == "ember")
check("every theme covers every phase",
      Theme.all.allSatisfy { t in
          [Phase.focus, .shortBreak, .longBreak].allSatisfy { t.colors(for: $0).count == 2 }
      })

print("full cycle -> long break on the 4th focus")
oneSecondPhases()
engine.resetAll()
var sequence: [String] = []
var focusAtLongBreak = -1
engine.onPhaseChange = { phase in
    sequence.append(phase.rawValue)
    // Snapshot the credit count the instant the long break begins; letting the
    // clock run on would keep counting further sessions.
    if phase == .longBreak && focusAtLongBreak < 0 {
        focusAtLongBreak = engine.completedFocus
        engine.pause()
    }
}
engine.start()
RunLoop.main.run(until: Date().addingTimeInterval(9))

let expected = ["shortBreak", "focus", "shortBreak", "focus", "shortBreak", "focus", "longBreak"]
check("phase order", Array(sequence.prefix(expected.count)) == expected,
      "\n        expected \(expected)\n        got      \(Array(sequence.prefix(expected.count)))")
check("4 sessions credited at long break", focusAtLongBreak == 4, "got \(focusAtLongBreak)")
check("stats recorded 4 sessions", stats.todaySessions == 4, "got \(stats.todaySessions)")

print("skip earns no credit")
engine.onPhaseChange = nil
engine.resetAll()
let before = stats.todaySessions
engine.skip()
check("skip moves off focus", engine.phase == .shortBreak)
check("skip does not credit the run", engine.completedFocus == 0, "got \(engine.completedFocus)")
check("skip does not touch stats", stats.todaySessions == before, "got \(stats.todaySessions)")

print("toggle defaults and persistence")
// Verified here rather than by eye: AppKit switches don't always draw their
// on-state into a cached bitmap, so the settings snapshot can't be trusted.
let fresh = Prefs(defaults: UserDefaults(suiteName: "dev.local.pomodoro.tests.fresh")!)
UserDefaults.standard.removePersistentDomain(forName: "dev.local.pomodoro.tests.fresh")
let clean = Prefs(defaults: UserDefaults(suiteName: "dev.local.pomodoro.tests.fresh")!)
check("always-on-top defaults on", clean.alwaysOnTop)
check("snap-to-edges defaults on", clean.snapToEdges)
check("auto-advance defaults on", clean.autoAdvance)
check("sound defaults on", clean.soundEnabled)
check("click-through defaults off", !clean.clickThrough)
check("dim-when-idle defaults off", !clean.dimWhenIdle)
_ = fresh

let roundTripSuite = "dev.local.pomodoro.tests.rt"
UserDefaults.standard.removePersistentDomain(forName: roundTripSuite)
let rtStore = UserDefaults(suiteName: roundTripSuite)!
let writer = Prefs(defaults: rtStore)
writer.alwaysOnTop = false
writer.clickThrough = true
writer.themeID = "neon"
writer.opacity = 0.7
let reader = Prefs(defaults: rtStore)
check("bool persists", reader.alwaysOnTop == false && reader.clickThrough == true)
check("theme persists", reader.themeID == "neon", "got \(reader.themeID)")
check("opacity persists", abs(reader.opacity - 0.7) < 0.001, "got \(reader.opacity)")
UserDefaults.standard.removePersistentDomain(forName: roundTripSuite)

print("out-of-range durations clamp on load")
let badSuite = "dev.local.pomodoro.tests.bad"
UserDefaults.standard.removePersistentDomain(forName: badSuite)
let badStore = UserDefaults(suiteName: badSuite)!
badStore.set(0.2, forKey: "focusMinutes")
badStore.set(9999.0, forKey: "longMinutes")
let repaired = Prefs(defaults: badStore)
check("tiny focus clamps up", repaired.focusMinutes == Prefs.focusRange.lowerBound,
      "got \(repaired.focusMinutes)")
check("huge long break clamps down", repaired.longMinutes == Prefs.longRange.upperBound,
      "got \(repaired.longMinutes)")
UserDefaults.standard.removePersistentDomain(forName: badSuite)

print("size clamping")
prefs.size = 9999
check("size clamps on write path", Prefs.sizeRange.contains(Prefs(defaults: store).size),
      "got \(Prefs(defaults: store).size)")

print("resize grip tracks the pointer")
let k: CGFloat = 0.82
let tl = CGPoint(x: 100, y: 900)          // screen coords, y up
let startSide: CGFloat = 210
let centre = ResizeMath.gripCentre(topLeft: tl, side: startSide, gripFraction: k)

// Grabbed dead centre of the grip, pointer unmoved: size must not jump.
let unmoved = ResizeMath.side(topLeft: tl, grabOffset: .zero, mouse: centre, gripFraction: k)
check("no jump on grab", abs(unmoved - startSide) < 0.01, "got \(unmoved)")

// Drag out along the diagonal, then confirm the grip lands back under the
// pointer at the new size — that is what "the handle follows the cursor" means.
let out = CGPoint(x: centre.x + 41, y: centre.y - 41)
let grown = ResizeMath.side(topLeft: tl, grabOffset: .zero, mouse: out, gripFraction: k)
check("drag out grows", grown > startSide, "got \(grown)")
let landed = ResizeMath.gripCentre(topLeft: tl, side: grown, gripFraction: k)
check("grip stays under pointer when growing",
      abs(landed.x - out.x) < 0.01 && abs(landed.y - out.y) < 0.01,
      "grip \(landed) vs pointer \(out)")

// The bug being guarded against: dragging back in must shrink, not stall.
let back = CGPoint(x: centre.x - 41, y: centre.y + 41)
let shrunk = ResizeMath.side(topLeft: tl, grabOffset: .zero, mouse: back, gripFraction: k)
check("drag in shrinks", shrunk < startSide, "got \(shrunk)")
let landedIn = ResizeMath.gripCentre(topLeft: tl, side: shrunk, gripFraction: k)
check("grip stays under pointer when shrinking",
      abs(landedIn.x - back.x) < 0.01 && abs(landedIn.y - back.y) < 0.01,
      "grip \(landedIn) vs pointer \(back)")

// Grabbing off-centre must not teleport the window on the first drag event.
let off = CGPoint(x: 7, y: -5)
let offGrab = ResizeMath.side(topLeft: tl, grabOffset: off,
                              mouse: CGPoint(x: centre.x + off.x, y: centre.y + off.y),
                              gripFraction: k)
check("off-centre grab does not teleport", abs(offGrab - startSide) < 0.01, "got \(offGrab)")

UserDefaults.standard.removePersistentDomain(forName: suite)
print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
