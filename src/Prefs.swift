import SwiftUI
import ServiceManagement

// MARK: - Themes

struct Theme: Identifiable, Hashable {
    let id: String
    let name: String
    private let focusHex: [UInt32]
    private let shortHex: [UInt32]
    private let longHex:  [UInt32]

    init(_ id: String, _ name: String, focus: [UInt32], short: [UInt32], long: [UInt32]) {
        self.id = id; self.name = name
        self.focusHex = focus; self.shortHex = short; self.longHex = long
    }

    func colors(for phase: Phase) -> [Color] {
        let hex: [UInt32]
        switch phase {
        case .focus:      hex = focusHex
        case .shortBreak: hex = shortHex
        case .longBreak:  hex = longHex
        }
        return hex.map { Color(hex: $0) }
    }

    /// Swatch shown in the picker — focus colour is the one you stare at most.
    var swatch: [Color] { focusHex.map { Color(hex: $0) } }

    static let all: [Theme] = [
        Theme("ember",  "Ember",
              focus: [0xFF6B5B, 0xFFA45B], short: [0x3DD9C0, 0x5BE49B], long: [0x6FA8FF, 0xA07BFF]),
        Theme("ocean",  "Ocean",
              focus: [0x2E9BFF, 0x39D0E8], short: [0x37E0B8, 0x7BF0A8], long: [0x7B87FF, 0xB57BFF]),
        Theme("forest", "Forest",
              focus: [0x9ACD3C, 0xDCCB4B], short: [0x2FC08A, 0x74D98A], long: [0x3FA9A0, 0x63C9B8]),
        Theme("sunset", "Sunset",
              focus: [0xFF4E8B, 0xFF9A5B], short: [0xFFB35B, 0xFFE07A], long: [0xB05BFF, 0xFF6BC1]),
        Theme("neon",   "Neon",
              focus: [0xFF2D95, 0xFF7A2D], short: [0x00F0B5, 0x5BFF8F], long: [0x00D4FF, 0x7B5BFF]),
        Theme("mono",   "Mono",
              focus: [0xFFFFFF, 0xC4C4C4], short: [0x9BE8D2, 0x6FC7B4], long: [0x9FB6D8, 0x7C93B8]),
    ]

    static func by(id: String) -> Theme { all.first { $0.id == id } ?? all[0] }
}

// MARK: - Duration presets (settings shortcuts)

struct DurationPreset {
    let name: String
    let focus: Double
    let short: Double
    let long: Double

    static let all: [DurationPreset] = [
        DurationPreset(name: "Classic",   focus: 25, short: 5,  long: 15),
        DurationPreset(name: "Deep work", focus: 50, short: 10, long: 20),
        DurationPreset(name: "Sprint",    focus: 15, short: 3,  long: 10),
        DurationPreset(name: "Demo",      focus: 1,  short: 1,  long: 1),
    ]
}

// MARK: - Preferences

/// Every user-facing setting, persisted on write. The panel and the timer both
/// observe this, so a change in Settings takes effect immediately.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d: UserDefaults

    // Durations are stored in minutes; the engine converts to seconds.
    @Published var focusMinutes: Double   { didSet { d.set(focusMinutes, forKey: K.focus) } }
    @Published var shortMinutes: Double   { didSet { d.set(shortMinutes, forKey: K.short) } }
    @Published var longMinutes: Double    { didSet { d.set(longMinutes,  forKey: K.long) } }
    @Published var sessionsBeforeLong: Int { didSet { d.set(sessionsBeforeLong, forKey: K.sessions) } }

    @Published var themeID: String        { didSet { d.set(themeID, forKey: K.theme) } }
    @Published var size: Double           { didSet { d.set(size, forKey: K.size) } }
    @Published var opacity: Double        { didSet { d.set(opacity, forKey: K.opacity) } }
    @Published var dimWhenIdle: Bool      { didSet { d.set(dimWhenIdle, forKey: K.dim) } }
    @Published var idleOpacity: Double    { didSet { d.set(idleOpacity, forKey: K.idleOpacity) } }

    @Published var clickThrough: Bool     { didSet { d.set(clickThrough, forKey: K.clickThrough) } }
    @Published var alwaysOnTop: Bool      { didSet { d.set(alwaysOnTop, forKey: K.onTop) } }
    @Published var snapToEdges: Bool      { didSet { d.set(snapToEdges, forKey: K.snap) } }

    @Published var autoAdvance: Bool      { didSet { d.set(autoAdvance, forKey: K.auto) } }
    @Published var soundEnabled: Bool     { didSet { d.set(soundEnabled, forKey: K.sound) } }
    @Published var soundName: String      { didSet { d.set(soundName, forKey: K.soundName) } }

    /// Not persisted by us — SMAppService owns the truth; we mirror it.
    @Published var launchAtLogin: Bool = false

    var theme: Theme { Theme.by(id: themeID) }

    static let sizeRange:  ClosedRange<Double> = 130...420
    static let focusRange: ClosedRange<Double> = 1...90
    static let shortRange: ClosedRange<Double> = 1...30
    static let longRange:  ClosedRange<Double> = 1...60

    private static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double {
        min(max(v, r.lowerBound), r.upperBound)
    }
    static let soundChoices = ["Glass", "Ping", "Tink", "Pop", "Hero", "Submarine", "Blow", "Purr"]

    private enum K {
        static let focus = "focusMinutes", short = "shortMinutes", long = "longMinutes"
        static let sessions = "sessionsBeforeLong", theme = "themeID", size = "size"
        static let opacity = "opacity", dim = "dimWhenIdle", idleOpacity = "idleOpacity"
        static let clickThrough = "clickThrough", onTop = "alwaysOnTop", snap = "snapToEdges"
        static let auto = "autoAdvance", sound = "soundEnabled", soundName = "soundName"
        static let origin = "origin"
    }

    init(defaults: UserDefaults = .standard) {
        self.d = defaults
        let store = defaults
        func dbl(_ k: String, _ fallback: Double) -> Double { store.object(forKey: k) as? Double ?? fallback }
        func bool(_ k: String, _ fallback: Bool) -> Bool { store.object(forKey: k) as? Bool ?? fallback }

        // Clamp on load: a value outside the slider's range (an older build, a
        // hand-edited plist) would otherwise render as a nonsense duration.
        focusMinutes = Prefs.clamp(dbl(K.focus, 25), Prefs.focusRange)
        shortMinutes = Prefs.clamp(dbl(K.short, 5),  Prefs.shortRange)
        longMinutes  = Prefs.clamp(dbl(K.long, 15),  Prefs.longRange)
        sessionsBeforeLong = store.object(forKey: K.sessions) as? Int ?? 4
        themeID = store.string(forKey: K.theme) ?? "ember"
        size = Prefs.clamp(dbl(K.size, 260), Prefs.sizeRange)
        opacity = dbl(K.opacity, 1.0)
        dimWhenIdle = bool(K.dim, false)
        idleOpacity = dbl(K.idleOpacity, 0.55)
        clickThrough = bool(K.clickThrough, false)
        alwaysOnTop = bool(K.onTop, true)
        snapToEdges = bool(K.snap, true)
        autoAdvance = bool(K.auto, true)
        soundEnabled = bool(K.sound, true)
        soundName = store.string(forKey: K.soundName) ?? "Glass"
        launchAtLogin = Bundle.main.bundleIdentifier != nil
            && SMAppService.mainApp.status == .enabled
    }

    // Panel position lives here too, but isn't @Published — nothing observes it.
    var origin: CGPoint? {
        get {
            guard let s = d.string(forKey: K.origin) else { return nil }
            return NSPointFromString(s)
        }
        set {
            guard let p = newValue else { return }
            d.set(NSStringFromPoint(p), forKey: K.origin)
        }
    }

    func apply(_ p: DurationPreset) {
        focusMinutes = p.focus
        shortMinutes = p.short
        longMinutes  = p.long
    }

    /// Returns an error message if the login item couldn't be registered —
    /// unsigned local builds are often rejected here.
    @discardableResult
    func setLaunchAtLogin(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            return nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            return error.localizedDescription
        }
    }
}

// MARK: - Stats

/// Completed focus sessions per day, kept for the last fortnight.
final class Stats: ObservableObject {
    static let shared = Stats()
    private let d: UserDefaults
    private let key = "dailyLog"

    /// day key -> [session count, focus minutes]
    @Published private(set) var log: [String: [Double]]

    init(defaults: UserDefaults = .standard) {
        self.d = defaults
        log = defaults.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        prune()
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(for date: Date) -> String { fmt.string(from: date) }

    func record(minutes: Double, on date: Date = Date()) {
        let k = Stats.key(for: date)
        var entry = log[k] ?? [0, 0]
        entry[0] += 1
        entry[1] += minutes
        log[k] = entry
        d.set(log, forKey: key)
    }

    func sessions(on date: Date) -> Int { Int(log[Stats.key(for: date)]?.first ?? 0) }
    func minutes(on date: Date) -> Double { log[Stats.key(for: date)]?.last ?? 0 }

    var todaySessions: Int { sessions(on: Date()) }
    var todayMinutes: Double { minutes(on: Date()) }

    /// Oldest first, ending today.
    func lastDays(_ n: Int) -> [(date: Date, sessions: Int)] {
        (0..<n).reversed().compactMap { back in
            guard let day = Calendar.current.date(byAdding: .day, value: -back, to: Date())
            else { return nil }
            return (day, sessions(on: day))
        }
    }

    func reset() {
        log = [:]
        d.removeObject(forKey: key)
    }

    private func prune() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -21, to: Date()) else { return }
        let cutoffKey = Stats.key(for: cutoff)
        let trimmed = log.filter { $0.key >= cutoffKey }
        if trimmed.count != log.count {
            log = trimmed
            d.set(log, forKey: key)
        }
    }
}

// MARK: - Helpers

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
