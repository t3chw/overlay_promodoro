import SwiftUI

// MARK: - Drawer

/// The list that slides out under the dial. Its job is to get you focused in
/// one click, so quick-add lives here rather than only in Settings — if jotting
/// a task meant opening a settings window, nobody would ever use the feature.
struct TaskDrawerView: View {
    @ObservedObject var tasks: TaskStore
    @ObservedObject var prefs: Prefs
    @ObservedObject var engine: TimerEngine

    var onStart: (UUID) -> Void = { _ in }

    @State private var draft = ""
    @State private var draftMinutes: Double = 25
    @FocusState private var composing: Bool

    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 38
    static let chromeHeight: CGFloat = 96      // quick-add + footer + dividers
    static let maxRows = 7

    /// Panel height for a given task count — main.swift sizes the window from
    /// this so the drawer never has dead space or a scrollbar it doesn't need.
    static func height(for count: Int) -> CGFloat {
        let rows = max(1, min(count, maxRows))
        return chromeHeight + CGFloat(rows) * rowHeight
    }

    private var accent: Color { prefs.theme.colors(for: .focus)[0] }

    var body: some View {
        VStack(spacing: 0) {
            composer
            Divider().overlay(Color.white.opacity(0.10))
            list
            Divider().overlay(Color.white.opacity(0.10))
            footer
        }
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Color.black.opacity(0.55))
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
        )
        .environment(\.colorScheme, .dark)
        .onAppear { draftMinutes = prefs.focusMinutes }
    }

    // MARK: Quick add

    private var composer: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.35))

            TextField("What are you working on?", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .focused($composing)
                .onSubmit(commit)

            DurationMenu(minutes: $draftMinutes, accent: accent)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func commit() {
        guard tasks.add(title: draft, minutes: draftMinutes) != nil else { return }
        draft = ""
        composing = true      // keep the field hot so you can list several fast
    }

    // MARK: List

    private var list: some View {
        Group {
            if tasks.items.isEmpty {
                VStack(spacing: 3) {
                    Text("No tasks yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("Type above and press ↩")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.32))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(tasks.ordered) { item in
                            TaskRow(item: item,
                                    isActive: item.id == tasks.activeID,
                                    isRunning: engine.isRunning,
                                    accent: accent,
                                    onStart: { onStart(item.id) },
                                    onToggle: { tasks.toggleDone(item.id) },
                                    onMinutes: { tasks.setMinutes(item.id, $0) },
                                    onDelete: { tasks.remove(item.id) })
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Text(tasks.pendingCount == 1 ? "1 task left" : "\(tasks.pendingCount) tasks left")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.45))

            Spacer()

            if tasks.hasCompleted {
                Button("Clear done") { tasks.clearCompleted() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}

// MARK: - Row

private struct TaskRow: View {
    let item: TodoItem
    let isActive: Bool
    let isRunning: Bool
    let accent: Color
    let onStart: () -> Void
    let onToggle: () -> Void
    let onMinutes: (Double) -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Left accent marks the task the timer is currently sized from.
            Rectangle()
                .fill(isActive ? accent : .clear)
                .frame(width: 2.5)

            Button(action: onToggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(item.done ? accent : Color.white.opacity(0.35))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.done ? "Mark not done" : "Mark done")

            Text(item.title)
                .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                .foregroundStyle(item.done ? .white.opacity(0.35) : .white.opacity(0.92))
                .strikethrough(item.done, color: .white.opacity(0.3))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if item.accumulated > 0 {
                Text(item.totalLabel)
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.35))
            }

            DurationMenu(minutes: Binding(get: { item.minutes }, set: onMinutes),
                         accent: accent)

            // Fixed slot, so revealing delete on hover never reflows the row.
            ZStack {
                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete task")
                } else if isActive {
                    Image(systemName: isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(accent)
                }
            }
            .frame(width: 14)
        }
        .padding(.trailing, 12)
        .frame(height: 38)
        .background(
            Rectangle().fill(isActive ? accent.opacity(0.12)
                             : (hovering ? Color.white.opacity(0.06) : .clear))
        )
        // The whole row starts the task; the controls above consume their own
        // clicks, so there's no ambiguity about what a click does.
        .contentShape(Rectangle())
        .onTapGesture { if !item.done { onStart() } }
        .onHover { hovering = $0 }
        .help(item.done ? "Completed" : "Focus on “\(item.title)” for \(TaskDuration.label(item.minutes))")
    }
}

// MARK: - Duration menu

private struct DurationMenu: View {
    @Binding var minutes: Double
    let accent: Color

    var body: some View {
        Menu {
            ForEach(TaskDuration.choices, id: \.self) { m in
                Button(TaskDuration.label(m)) { minutes = m }
            }
        } label: {
            Text(TaskDuration.label(minutes))
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Session length")
    }
}

// MARK: - Shared UI state

/// Small observable so the dial can reflect the drawer's open/closed state
/// without the app delegate rebuilding the hosting view's root on every toggle.
final class UIState: ObservableObject {
    @Published var drawerOpen = false
}
