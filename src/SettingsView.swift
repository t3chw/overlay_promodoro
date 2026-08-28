import SwiftUI

/// Sections of the settings window.
enum SettingsSection: String, CaseIterable, Identifiable {
    case timer, tasks, appearance, behavior, stats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timer:      return "Timer"
        case .tasks:      return "Tasks"
        case .appearance: return "Appearance"
        case .behavior:   return "Behavior"
        case .stats:      return "Stats"
        }
    }

    var symbol: String {
        switch self {
        case .timer:      return "timer"
        case .tasks:      return "checklist"
        case .appearance: return "paintbrush"
        case .behavior:   return "slider.horizontal.3"
        case .stats:      return "chart.bar"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var stats: Stats
    @ObservedObject var engine: TimerEngine
    @ObservedObject var hotKeys: HotKeyManager
    @ObservedObject var tasks: TaskStore

    @State private var section: SettingsSection = .timer

    /// A plain sidebar rather than a TabView.
    ///
    /// TabView draws its tabs into the *window title bar*, and when they don't
    /// fit it silently collapses the app's entire navigation behind an
    /// unlabelled "»" chevron. That is a width-dependent trap: it comes back
    /// the moment a section is added or a label gets longer. A sidebar is
    /// always visible, always labelled, and cannot overflow.
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 700, height: 560)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { item in
                SidebarRow(item: item, selected: item == section) { section = item }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 178)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .timer:      TimerTab(prefs: prefs)
        case .tasks:      TasksTab(tasks: tasks, prefs: prefs, engine: engine)
        case .appearance: AppearanceTab(prefs: prefs)
        case .behavior:   BehaviorTab(prefs: prefs, hotKeys: hotKeys)
        case .stats:      StatsTab(prefs: prefs, stats: stats, engine: engine, tasks: tasks)
        }
    }
}

private struct SidebarRow: View {
    let item: SettingsSection
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12))
                    .frame(width: 18)
                Text(item.title).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor
                          : (hovering ? Color.primary.opacity(0.07) : .clear))
            )
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(item.title)
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
    @ObservedObject var hotKeys: HotKeyManager
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
                Toggle("Global keyboard shortcuts", isOn: $prefs.hotKeysEnabled)
                if prefs.hotKeysEnabled {
                    ForEach(HotKeyManager.specs, id: \.id) { spec in
                        HStack {
                            Text(spec.name)
                            Spacer()
                            if !hotKeys.registered.contains(spec.id) {
                                Text("in use by another app")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Text(spec.display)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("Shortcuts") } footer: {
                Text("These work from any app and need no Accessibility permission.")
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
    @ObservedObject var tasks: TaskStore

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

            if !tasks.topByTime(5).isEmpty {
                Section {
                    ForEach(tasks.topByTime(5)) { item in
                        HStack {
                            Text(item.title).lineLimit(1)
                            Spacer()
                            Text("\(item.sessions)×")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(item.totalLabel)
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Where the time went") }
            }

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


// MARK: - Tasks

struct TasksTab: View {
    @ObservedObject var tasks: TaskStore
    @ObservedObject var prefs: Prefs
    @ObservedObject var engine: TimerEngine

    @State private var draft = ""
    @State private var draftMinutes: Double = 25

    /// A task's length may not be one of the presets (it can be seeded from a
    /// custom focus duration), and a Picker with no matching tag renders blank.
    private func choices(including m: Double) -> [Double] {
        TaskDuration.choices.contains(m)
            ? TaskDuration.choices
            : (TaskDuration.choices + [m]).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("New task", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Picker("", selection: $draftMinutes) {
                    ForEach(choices(including: draftMinutes), id: \.self) {
                        Text(TaskDuration.label($0)).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 78)
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)

            Divider()

            if tasks.items.isEmpty {
                VStack(spacing: 4) {
                    Text("No tasks yet").foregroundStyle(.secondary)
                    Text("Add one above, or use the ⌄ tab under the timer.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(tasks.items) { item in row(item) }
                        .onMove { tasks.move(from: $0, to: $1) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Divider()

            HStack {
                Text("\(tasks.pendingCount) of \(tasks.items.count) left")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if tasks.hasCompleted {
                    Button("Clear Completed") { tasks.clearCompleted() }
                }
            }
            .padding(12)
        }
        // Painted explicitly. The other tabs get a background free from
        // .formStyle(.grouped); a bare VStack does not, and an unpainted
        // container falls through to whatever is behind it.
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { draftMinutes = prefs.focusMinutes }
    }

    private func add() {
        tasks.add(title: draft, minutes: draftMinutes)
        draft = ""
    }

    @ViewBuilder
    private func row(_ item: TodoItem) -> some View {
        HStack(spacing: 8) {
            Button { tasks.toggleDone(item.id) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.done ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            TextField("", text: Binding(get: { item.title },
                                        set: { tasks.setTitle(item.id, $0) }))
                .textFieldStyle(.plain)
                .strikethrough(item.done, color: .secondary)
                .foregroundStyle(item.done ? .secondary : .primary)

            if item.sessions > 0 {
                Text("\(item.sessions)×").font(.caption).foregroundStyle(.secondary)
                Text(item.totalLabel)
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }

            Picker("", selection: Binding(get: { item.minutes },
                                          set: { tasks.setMinutes(item.id, $0) })) {
                ForEach(choices(including: item.minutes), id: \.self) {
                    Text(TaskDuration.label($0)).tag($0)
                }
            }
            .labelsHidden()
            .frame(width: 78)

            Button { tasks.remove(item.id) } label: {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
        .contextMenu {
            Button("Focus on This Now") { engine.focus(on: item.id) }
            Button(item.done ? "Mark Not Done" : "Mark Done") { tasks.toggleDone(item.id) }
            Divider()
            Button("Delete", role: .destructive) { tasks.remove(item.id) }
        }
    }
}
