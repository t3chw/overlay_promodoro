import Foundation

// Runs against a throwaway defaults domain so the user's real settings are
// never touched. Phase durations floor at 1s in the engine, so a full
// four-session cycle takes ~8 seconds of wall clock.

let suite = "dev.local.pomodoro.tests"
UserDefaults.standard.removePersistentDomain(forName: suite)
let store = UserDefaults(suiteName: suite)!

let prefs = Prefs(defaults: store)
let stats = Stats(defaults: store)
let tasks = TaskStore(defaults: store)
let engine = TimerEngine(prefs: prefs, stats: stats, tasks: tasks)

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

print("task list basics")
engine.resetAll()
check("empty title rejected", tasks.add(title: "   ", minutes: 25) == nil)
let specTask = tasks.add(title: "  Write the spec  ", minutes: 45)!
check("title trimmed", specTask.title == "Write the spec")
let prTask = tasks.add(title: "Review the PR", minutes: 25)!
check("newest first", tasks.items.first?.id == prTask.id)
check("two tasks", tasks.items.count == 2)

tasks.toggleDone(prTask.id)
check("completed sort to the bottom", tasks.ordered.last?.id == prTask.id)
check("pending count excludes done", tasks.pendingCount == 1)
tasks.toggleDone(prTask.id)

print("active task drives the focus length")
check("no active task uses the global duration",
      engine.duration(for: .focus) == prefs.focusMinutes * 60,
      "got \(engine.duration(for: .focus))")
tasks.activate(specTask.id)
check("active task overrides it", engine.duration(for: .focus) == 45 * 60,
      "got \(engine.duration(for: .focus))")
check("breaks are unaffected", engine.duration(for: .shortBreak) == prefs.shortMinutes * 60)
check("headline is the task", engine.headline == "Write the spec")
check("headline flagged as a task", engine.headlineIsTask)
tasks.activate(nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
check("headline falls back to the phase", engine.headline == "FOCUS")

print("focus(on:) starts the task immediately")
engine.resetAll()
engine.focus(on: specTask.id)
check("switched to focus", engine.phase == .focus)
check("running", engine.isRunning)
check("sized from the task", engine.phaseDuration == 45 * 60,
      "got \(engine.phaseDuration)")
check("active id set", tasks.activeID == specTask.id)
engine.pause()

print("a paused countdown survives unrelated edits")
// The bug this guards: retargeting on every observable change would throw away
// a paused countdown just because some other task got added or renamed.
engine.resetAll()
tasks.activate(nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
engine.start()
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
engine.pause()
let paused = engine.remaining
_ = tasks.add(title: "Something else entirely", minutes: 90)
tasks.setTitle(specTask.id, "Write the spec, revised")
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
check("paused countdown untouched by unrelated edits", engine.remaining == paused,
      "was \(paused), now \(engine.remaining)")

print("but a real duration change still retargets")
tasks.activate(specTask.id)
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
check("activating a task retargets while idle", engine.remaining == 45 * 60,
      "got \(engine.remaining)")
tasks.setMinutes(specTask.id, 30)
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
check("editing the active task's length retargets", engine.remaining == 30 * 60,
      "got \(engine.remaining)")

print("completing a session credits the task")
prefs.autoAdvance = false
tasks.setMinutes(specTask.id, 0.05)          // 3 seconds
tasks.activate(specTask.id)
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
let statsBefore = stats.todaySessions
engine.reset()
engine.start()
RunLoop.main.run(until: Date().addingTimeInterval(4))
let credited = tasks.items.first { $0.id == specTask.id }!
check("session counted on the task", credited.sessions == 1, "got \(credited.sessions)")
check("minutes accumulated from the phase length",
      abs(credited.accumulated - 0.05) < 0.001, "got \(credited.accumulated)")
check("daily stats also credited", stats.todaySessions == statsBefore + 1)
check("moved to a break", engine.phase == .shortBreak)
prefs.autoAdvance = true

print("active task lifecycle")
tasks.activate(specTask.id)
tasks.toggleDone(specTask.id)
check("completing the active task clears it", tasks.activeID == nil)
tasks.toggleDone(specTask.id)
tasks.activate(specTask.id)
tasks.remove(specTask.id)
check("deleting the active task clears it", tasks.activeID == nil)
check("removed from the list", !tasks.items.contains { $0.id == specTask.id })

print("tasks persist")
let taskSuite = "dev.local.pomodoro.tests.tasks"
UserDefaults.standard.removePersistentDomain(forName: taskSuite)
let taskStore = UserDefaults(suiteName: taskSuite)!
let writer2 = TaskStore(defaults: taskStore)
let saved = writer2.add(title: "Persisted", minutes: 40)!
writer2.activate(saved.id)
writer2.creditActive(minutes: 40)
let reader2 = TaskStore(defaults: taskStore)
check("items persist", reader2.items.first?.title == "Persisted")
check("duration persists", reader2.items.first?.minutes == 40)
check("credit persists", reader2.items.first?.accumulated == 40)
check("active id persists", reader2.activeID == saved.id)
writer2.remove(saved.id)
let reader3 = TaskStore(defaults: taskStore)
check("a stale active id is dropped on load", reader3.activeID == nil)
UserDefaults.standard.removePersistentDomain(forName: taskSuite)

print("drawer placement")
let screen = CGRect(x: 0, y: 0, width: 1470, height: 900)
let dw: CGFloat = 320, dh: CGFloat = 250, mg: CGFloat = 23, gp: CGFloat = 6

let midDial = CGRect(x: 600, y: 500, width: 260, height: 260)
let below = DrawerLayout.frame(dial: midDial, screen: screen, width: dw, height: dh,
                               margin: mg, gap: gp)
check("centred on the dial", abs(below.midX - midDial.midX) < 0.01,
      "\(below.midX) vs \(midDial.midX)")
check("hangs below the visible disc", below.maxY == midDial.minY + mg - gp,
      "got \(below.maxY)")

// Parked at the bottom there is no room underneath, so it must flip.
let lowDial = CGRect(x: 600, y: 4, width: 260, height: 260)
let flipped = DrawerLayout.frame(dial: lowDial, screen: screen, width: dw, height: dh,
                                 margin: mg, gap: gp)
check("flips above when there is no room below", flipped.minY > lowDial.minY,
      "drawer y \(flipped.minY) vs dial y \(lowDial.minY)")
check("stays on screen when flipped",
      flipped.maxY <= screen.maxY - 8 + 0.01 && flipped.minY >= screen.minY - 0.01,
      "got \(flipped)")

// Dial hard against the right edge: the wider drawer must not hang off.
let edgeDial = CGRect(x: 1370, y: 500, width: 100, height: 100)
let clamped = DrawerLayout.frame(dial: edgeDial, screen: screen, width: dw, height: dh,
                                 margin: mg, gap: gp)
check("clamped inside the right edge", clamped.maxX <= screen.maxX - 8 + 0.01,
      "got \(clamped.maxX)")
let leftDial = CGRect(x: 0, y: 500, width: 100, height: 100)
let clampedL = DrawerLayout.frame(dial: leftDial, screen: screen, width: dw, height: dh,
                                  margin: mg, gap: gp)
check("clamped inside the left edge", clampedL.minX >= screen.minX + 8 - 0.01,
      "got \(clampedL.minX)")

print("drawer height tracks the task count")
check("empty list still has a usable height", TaskDrawerView.height(for: 0) > 100)
check("grows with rows",
      TaskDrawerView.height(for: 3) > TaskDrawerView.height(for: 1))
check("caps so it cannot run off screen",
      TaskDrawerView.height(for: 50) == TaskDrawerView.height(for: TaskDrawerView.maxRows))

print("windows are pulled back on screen")
let visible = CGRect(x: 0, y: 0, width: 1470, height: 900)
let inside = CGRect(x: 400, y: 300, width: 200, height: 200)
check("an on-screen window is left alone",
      ScreenFit.clamped(inside, into: visible) == inside)
// A window hanging off the right edge intersects the screen, so the saved-origin
// check passes it — this is the stricter pass that actually rescues it.
let hangingRight = CGRect(x: 1400, y: 300, width: 200, height: 200)
check("pulled in from the right",
      ScreenFit.clamped(hangingRight, into: visible).maxX == visible.maxX,
      "got \(ScreenFit.clamped(hangingRight, into: visible))")
let hangingLow = CGRect(x: 400, y: -150, width: 200, height: 200)
check("pulled up from below",
      ScreenFit.clamped(hangingLow, into: visible).minY == visible.minY,
      "got \(ScreenFit.clamped(hangingLow, into: visible))")
let stranded = CGRect(x: 4000, y: 4000, width: 200, height: 200)
let rescued = ScreenFit.clamped(stranded, into: visible)
check("a fully stranded window comes back",
      visible.contains(rescued), "got \(rescued)")
// Never move a window that is larger than the screen off its own top-left.
let huge = CGRect(x: -50, y: -50, width: 2000, height: 2000)
let hugeFit = ScreenFit.clamped(huge, into: visible)
check("an oversized window pins to the origin rather than flipping",
      hugeFit.origin.x == visible.minX && hugeFit.origin.y == visible.minY,
      "got \(hugeFit)")

UserDefaults.standard.removePersistentDomain(forName: suite)
print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
