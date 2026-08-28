import SwiftUI
import Combine

// MARK: - Phases

enum Phase: String, Codable {
    case focus, shortBreak, longBreak

    var title: String {
        switch self {
        case .focus:      return "FOCUS"
        case .shortBreak: return "BREAK"
        case .longBreak:  return "LONG BREAK"
        }
    }

    var symbol: String {
        switch self {
        case .focus:      return "brain.head.profile"
        case .shortBreak: return "cup.and.saucer.fill"
        case .longBreak:  return "figure.walk"
        }
    }
}

// MARK: - Engine

/// Time is derived from an absolute `endDate` rather than accumulated per tick,
/// so the countdown can't drift and survives the Mac sleeping mid-session.
final class TimerEngine: ObservableObject {

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var isRunning = false
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var completedFocus = 0
    /// Bumped on every phase change so the view can play a pulse.
    @Published private(set) var pulse = 0

    /// The length this phase was started with — the authority for progress and
    /// for crediting. Reading `duration(for:)` live would make the ring jump if
    /// a duration were edited mid-session, and would credit a task with time it
    /// never actually ran.
    @Published private(set) var phaseDuration: TimeInterval = 0

    private let prefs: Prefs
    private let stats: Stats
    private let tasks: TaskStore
    private var endDate: Date?
    private var ticker: Timer?
    private var bag = Set<AnyCancellable>()

    var onPhaseChange: ((Phase) -> Void)?

    init(prefs: Prefs = .shared, stats: Stats = .shared, tasks: TaskStore = .shared) {
        self.prefs = prefs
        self.stats = stats
        self.tasks = tasks
        phaseDuration = duration(for: .focus)
        remaining = phaseDuration

        // Settings and task edits should retarget the current phase — but only
        // when they actually change its length, and only while idle. Blindly
        // resetting on every edit would throw away a paused countdown just
        // because an unrelated task got renamed.
        Publishers.Merge(
            prefs.objectWillChange.map { _ in () },
            tasks.objectWillChange.map { _ in () }
        )
        .receive(on: DispatchQueue.main)     // @Published fires in willSet
        .sink { [weak self] in self?.retargetIfDurationChanged() }
        .store(in: &bag)
    }

    // MARK: Derived

    /// The configured length of a phase. A focus phase takes its length from
    /// the active task when there is one.
    func duration(for phase: Phase) -> TimeInterval {
        let minutes: Double
        switch phase {
        case .focus:      minutes = tasks.active?.minutes ?? prefs.focusMinutes
        case .shortBreak: minutes = prefs.shortMinutes
        case .longBreak:  minutes = prefs.longMinutes
        }
        return max(1, minutes * 60)
    }

    var sessionsBeforeLongBreak: Int { max(2, prefs.sessionsBeforeLong) }

    /// 1.0 at the start of a phase, 0.0 at the end — the ring shrinks with it.
    var progress: Double {
        guard phaseDuration > 0 else { return 0 }
        return max(0, min(1, remaining / phaseDuration))
    }

    var display: String { Self.format(remaining) }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(max(0, t).rounded(.up))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    var dotsFilled: Int { completedFocus % sessionsBeforeLongBreak }

    /// What the dial should print above the clock: the task you're on during a
    /// focus phase, otherwise the phase name.
    var headline: String {
        if phase == .focus, let task = tasks.active { return task.title }
        return phase.title
    }

    var headlineIsTask: Bool { phase == .focus && tasks.active != nil }

    /// Full title for tooltips, whatever phase we're in — the dial truncates.
    var activeTaskTitle: String? { tasks.active?.title }

    /// Colour of the task being worked on, if any. Only meaningful during a
    /// focus phase: breaks keep the theme's own break colours, so the ring still
    /// says "you are resting" no matter what colour the task is.
    var activeTaskColorHex: UInt32? { phase == .focus ? tasks.active?.colorHex : nil }

    /// Sub-tick-accurate remaining time. The 10 Hz ticker keeps `remaining`
    /// roughly fresh, but the ring redraws at 60 fps and would visibly
    /// stair-step off it, so the view asks for an exact value per frame.
    func liveRemaining(at now: Date) -> TimeInterval {
        guard isRunning, let end = endDate else { return remaining }
        return max(0, end.timeIntervalSince(now))
    }

    // MARK: Controls

    func toggle() { isRunning ? pause() : start() }

    func start() {
        guard !isRunning else { return }
        if remaining <= 0 { remaining = phaseDuration }
        endDate = Date().addingTimeInterval(remaining)
        isRunning = true
        startTicker()
    }

    func pause() {
        guard isRunning else { return }
        remaining = max(0, endDate?.timeIntervalSinceNow ?? remaining)
        isRunning = false
        endDate = nil
        stopTicker()
    }

    /// Restart the current phase from the top.
    func reset() {
        stopTicker()
        isRunning = false
        endDate = nil
        remaining = phaseDuration
    }

    /// Jump to the next phase without completing this one — no credit given.
    func skip() { advance(credit: false) }

    /// Full reset: back to focus #1.
    func resetAll() {
        stopTicker()
        isRunning = false
        endDate = nil
        completedFocus = 0
        phase = .focus
        phaseDuration = duration(for: .focus)
        remaining = phaseDuration
    }

    /// Make a task active and begin focusing on it immediately, whatever phase
    /// we were in — picking a task *is* the instruction to start working.
    func focus(on id: UUID) {
        stopTicker()
        tasks.activate(id)
        phase = .focus
        phaseDuration = duration(for: .focus)
        remaining = phaseDuration
        isRunning = false
        start()
    }

    /// Drop the active task without disturbing the countdown.
    func clearActiveTask() {
        tasks.activate(nil)
    }

    // MARK: Ticking

    private func startTicker() {
        stopTicker()
        // 10 Hz is plenty: the ring is animated by TimelineView, this only
        // needs to keep `remaining` fresh and catch the zero crossing.
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // .common so it survives drags
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard isRunning, let end = endDate else { return }
        let left = end.timeIntervalSinceNow
        if left <= 0 {
            remaining = 0
            advance(credit: true)
        } else {
            remaining = left
        }
    }

    // MARK: Retargeting

    private func retargetIfDurationChanged() {
        guard !isRunning else { return }
        let d = duration(for: phase)
        guard abs(d - phaseDuration) > 0.001 else { return }
        phaseDuration = d
        remaining = d
    }

    // MARK: Phase machine

    private func advance(credit: Bool) {
        stopTicker()
        endDate = nil

        if phase == .focus {
            if credit {
                completedFocus += 1
                // Credit the length this phase actually ran, not whatever the
                // settings happen to say now.
                let minutes = phaseDuration / 60
                stats.record(minutes: minutes)
                tasks.creditActive(minutes: minutes)
            }
            let earnedLong = credit && completedFocus % sessionsBeforeLongBreak == 0
            phase = earnedLong ? .longBreak : .shortBreak
        } else {
            phase = .focus
        }

        phaseDuration = duration(for: phase)
        remaining = phaseDuration
        pulse &+= 1
        onPhaseChange?(phase)

        if prefs.autoAdvance && credit {
            isRunning = true
            endDate = Date().addingTimeInterval(remaining)
            startTicker()
        } else {
            isRunning = false
        }
    }
}
