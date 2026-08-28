import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var stats: Stats
    @ObservedObject var engine: TimerEngine

    var body: some View {
        TabView {
            TimerTab(prefs: prefs).tabItem { Label("Timer", systemImage: "timer") }
            AppearanceTab(prefs: prefs).tabItem { Label("Appearance", systemImage: "paintbrush") }
            BehaviorTab(prefs: prefs).tabItem { Label("Behavior", systemImage: "slider.horizontal.3") }
            StatsTab(prefs: prefs, stats: stats, engine: engine)
                .tabItem { Label("Stats", systemImage: "chart.bar") }
        }
        .frame(width: 460, height: 540)
    }
}

// MARK: - Shared row

private struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let readout: String

    var body: some View {
        HStack {
            Text(label).frame(width: 88, alignment: .leading)
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
            Text(readout)
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Timer

struct TimerTab: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    ForEach(DurationPreset.all, id: \.name) { p in
                        Button(p.name) { prefs.apply(p) }.buttonStyle(.bordered)
                    }
                }
            } header: { Text("Presets") }

            Section {
                SliderRow(label: "Focus", value: $prefs.focusMinutes, range: Prefs.focusRange,
                          step: 1, readout: "\(Int(prefs.focusMinutes)) min")
                SliderRow(label: "Short break", value: $prefs.shortMinutes, range: Prefs.shortRange,
                          step: 1, readout: "\(Int(prefs.shortMinutes)) min")
                SliderRow(label: "Long break", value: $prefs.longMinutes, range: Prefs.longRange,
                          step: 1, readout: "\(Int(prefs.longMinutes)) min")
                Stepper("Long break every \(prefs.sessionsBeforeLong) sessions",
                        value: $prefs.sessionsBeforeLong, in: 2...8)
            } header: { Text("Durations") } footer: {
                Text("While the timer is paused these apply to the current phase immediately; while it's running they take effect from the next phase.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

struct AppearanceTab: View {
    @ObservedObject var prefs: Prefs

    private let sizes: [(String, Double)] = [("S", 150), ("M", 210), ("L", 280), ("XL", 360)]

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                          spacing: 6) {
                    ForEach(Theme.all) { theme in
                        ThemeChip(theme: theme, selected: theme.id == prefs.themeID) {
                            prefs.themeID = theme.id
                        }
                    }
                }
                .padding(.vertical, 2)
            } header: { Text("Theme") }

            Section {
                SliderRow(label: "Size", value: $prefs.size, range: Prefs.sizeRange,
                          readout: "\(Int(prefs.size)) pt")
                HStack(spacing: 8) {
                    Spacer().frame(width: 88)
                    ForEach(sizes, id: \.0) { name, value in
                        Button(name) { prefs.size = value }
                            .buttonStyle(.bordered)
                            .frame(width: 42)
                    }
                    Spacer()
                }
            } header: { Text("Size") } footer: {
                Text("You can also drag the grip at the bottom-right of the timer.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                SliderRow(label: "Opacity", value: $prefs.opacity, range: 0.25...1.0,
                          readout: "\(Int(prefs.opacity * 100))%")
                Toggle("Fade when not hovering", isOn: $prefs.dimWhenIdle)
                if prefs.dimWhenIdle {
                    SliderRow(label: "Faded to", value: $prefs.idleOpacity, range: 0.05...1.0,
                              readout: "\(Int(prefs.idleOpacity * 100))%")
                }
            } header: { Text("Transparency") } footer: {
                Text("Fading lets the timer recede while you work; it returns to full opacity when the pointer moves over it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Behavior

struct BehaviorTab: View {
    @ObservedObject var prefs: Prefs
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Click through when not hovering", isOn: $prefs.clickThrough)
                Toggle("Keep above other windows", isOn: $prefs.alwaysOnTop)
                Toggle("Snap to screen edges", isOn: $prefs.snapToEdges)
            } header: { Text("Window") } footer: {
                Text("Click-through lets clicks pass to whatever is underneath, so the timer never blocks your work. Move the pointer over it and it becomes interactive again.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Auto-start the next phase", isOn: $prefs.autoAdvance)
                Toggle("Play a sound on transitions", isOn: $prefs.soundEnabled)
                if prefs.soundEnabled {
                    HStack {
                        Picker("Sound", selection: $prefs.soundName) {
                            ForEach(Prefs.soundChoices, id: \.self) { Text($0).tag($0) }
                        }
                        Button {
                            NSSound(named: NSSound.Name(prefs.soundName))?.play()
                        } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.borderless)
                        .help("Preview")
                    }
                }
            } header: { Text("Sessions") }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { prefs.launchAtLogin },
                    set: { loginError = prefs.setLaunchAtLogin($0) }
                ))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            } header: { Text("Startup") } footer: {
                Text("Unsigned local builds are often refused here. If it fails, add the app by hand in System Settings › General › Login Items.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Stats

struct StatsTab: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var stats: Stats
    @ObservedObject var engine: TimerEngine

    var body: some View {
        Form {
            Section {
                HStack(spacing: 20) {
                    metric("\(stats.todaySessions)", "sessions today")
                    metric(minutesLabel(stats.todayMinutes), "focused today")
                    metric("\(engine.completedFocus)", "this run")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } header: { Text("Today") }

            Section {
                let days = stats.lastDays(14)
                let peak = max(1, days.map(\.sessions).max() ?? 1)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(days, id: \.date) { day in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(day.sessions > 0
                                      ? prefs.theme.colors(for: .focus)[0]
                                      : Color.secondary.opacity(0.18))
                                .frame(height: max(3, 68 * CGFloat(day.sessions) / CGFloat(peak)))
                            Text(shortDay(day.date))
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                        .help("\(day.sessions) session\(day.sessions == 1 ? "" : "s")")
                    }
                }
                .frame(height: 92)
                .padding(.vertical, 4)
            } header: { Text("Last 14 days") }

            Section {
                Button("Reset All Statistics", role: .destructive) { stats.reset() }
            }
        }
        .formStyle(.grouped)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func minutesLabel(_ m: Double) -> String {
        m >= 60 ? String(format: "%.1fh", m / 60) : "\(Int(m))m"
    }

    private func shortDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEEE"
        return f.string(from: d)
    }
}

// MARK: - Theme chip

private struct ThemeChip: View {
    let theme: Theme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .stroke(LinearGradient(colors: theme.swatch,
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 6)
                        .frame(width: 32, height: 32)
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    }
                }
                Text(theme.name).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear))
        }
        .buttonStyle(.plain)
    }
}
