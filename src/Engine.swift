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

    private let prefs: Prefs
    private let stats: Stats
    private var endDate: Date?
    private var ticker: Timer?
    private var bag = Set<AnyCancellable>()

    var onPhaseChange: ((Phase) -> Void)?

    init(prefs: Prefs = .shared, stats: Stats = .shared) {
        self.prefs = prefs
        self.stats = stats
        remaining = duration(for: .focus)

        // Editing a duration in Settings should retarget the current phase
        // straight away — but only while idle, so it can't yank time out from
        // under a running session.
        prefs.$focusMinutes.combineLatest(prefs.$shortMinutes, prefs.$longMinutes)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                guard let self, !self.isRunning else { return }
                self.remaining = self.duration(for: self.phase)
            }
            .store(in: &bag)
    }

    // MARK: Derived

    func duration(for phase: Phase) -> TimeInterval {
        let minutes: Double
        switch phase {
        case .focus:      minutes = prefs.focusMinutes
        case .shortBreak: minutes = prefs.shortMinutes
        case .longBreak:  minutes = prefs.longMinutes
        }
        return max(1, minutes * 60)
    }

    var sessionsBeforeLongBreak: Int { max(2, prefs.sessionsBeforeLong) }

    /// 1.0 at the start of a phase, 0.0 at the end — the ring shrinks with it.
    var progress: Double {
        let total = duration(for: phase)
        guard total > 0 else { return 0 }
        return max(0, min(1, remaining / total))
    }

    var display: String { Self.format(remaining) }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(max(0, t).rounded(.up))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Filled dots in the current set.
    var dotsFilled: Int { completedFocus % sessionsBeforeLongBreak }

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
        if remaining <= 0 { remaining = duration(for: phase) }
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
        remaining = duration(for: phase)
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
        remaining = duration(for: .focus)
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

    // MARK: Phase machine

    private func advance(credit: Bool) {
        stopTicker()
        endDate = nil

        if phase == .focus {
            if credit {
                completedFocus += 1
                stats.record(minutes: prefs.focusMinutes)
            }
            let earnedLong = credit && completedFocus % sessionsBeforeLongBreak == 0
            phase = earnedLong ? .longBreak : .shortBreak
        } else {
            phase = .focus
        }

        remaining = duration(for: phase)
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
