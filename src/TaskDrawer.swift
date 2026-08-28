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
    @State private var draftColor: UInt32? = nil
    @FocusState private var composing: Bool

    static let width: CGFloat = 344
    static let rowHeight: CGFloat = 38
    static let chromeHeight: CGFloat = 98      // quick-add + footer + dividers
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
        .onAppear {
            draftMinutes = prefs.focusMinutes
            // The panel needs a beat to become key before focus will take.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { composing = true }
        }
    }

    // MARK: Quick add

    private var canAdd: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composer: some View {
        HStack(spacing: 7) {
            // A filled, bordered well — an unstyled TextField on a dark panel
            // reads as a caption, not as somewhere you can type.
            TextField("What are you working on?", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .focused($composing)
                .onSubmit(commit)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(composing ? 0.35 : 0.15),
                                      lineWidth: 0.8)
                )

            // Shows the colour the task will actually get, not the theme's:
            // new tasks are auto-assigned the next palette colour, so falling
            // back to the theme swatch here would have been a lie.
            ColorDot(hex: draftColor ?? TaskPalette.next(after: tasks.items.first?.colorHex),
                     fallback: accent) { draftColor = $0 }
            DurationMenu(minutes: $draftMinutes, accent: accent)

            // Was a decorative icon, which looked clickable and wasn't.
            Button(action: commit) {
                ZStack {
                    Circle().fill(canAdd ? accent : Color.white.opacity(0.10))
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(canAdd ? Color.black.opacity(0.85)
                                                : Color.white.opacity(0.3))
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .help("Add task")
            .accessibilityLabel("Add task")
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    private func commit() {
        guard canAdd,
              tasks.add(title: draft, minutes: draftMinutes, color: draftColor) != nil
        else { return }
        draft = ""
        draftColor = nil      // back to auto-rotation for the next one
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
                    Text("Type above, then ↩ or +")
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
                                    accent: accent,
                                    onStart: { onStart(item.id) },
                                    onToggle: { tasks.toggleDone(item.id) },
                                    onMinutes: { tasks.setMinutes(item.id, $0) },
                                    onColor: { tasks.setColor(item.id, $0) },
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
    let accent: Color
    let onStart: () -> Void
    let onToggle: () -> Void
    let onMinutes: (Double) -> Void
    let onColor: (UInt32?) -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var tint: Color { item.colorHex.map { Color(hex: $0) } ?? accent }

    var body: some View {
        // Every control is a sibling with its own hit area. The row used to be
        // one big tap gesture with the buttons layered on top, so a click on
        // delete was swallowed by the row and started the task instead.
        HStack(spacing: 7) {
            Rectangle()
                .fill(isActive ? tint : .clear)
                .frame(width: 2.5)

            Button(action: onToggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(item.done ? tint : Color.white.opacity(0.35))
                    .frame(width: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.done ? "Mark not done" : "Mark done")

            Button(action: { if !item.done { onStart() } }) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(item.done ? .white.opacity(0.35) : .white.opacity(0.92))
                        .strikethrough(item.done, color: .white.opacity(0.3))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    if item.accumulated > 0 {
                        Text(item.totalLabel)
                            .font(.system(size: 9.5))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Focus on \(item.title)")

            ColorDot(hex: item.colorHex, fallback: accent, onPick: onColor)

            DurationMenu(minutes: Binding(get: { item.minutes }, set: onMinutes),
                         accent: tint)

            DeleteButton(visible: hovering, action: onDelete)
        }
        .padding(.trailing, 10)
        .frame(height: 38)
        .background(
            Rectangle().fill(isActive ? tint.opacity(0.14)
                             : (hovering ? Color.white.opacity(0.06) : .clear))
        )
        .onHover { hovering = $0 }
        .help(item.done ? "Completed"
              : "Focus on \u{201C}\(item.title)\u{201D} for \(TaskDuration.label(item.minutes))")
    }
}

// MARK: - Delete

private struct DeleteButton: View {
    let visible: Bool
    let action: () -> Void

    @State private var over = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(hex: 0xFF453A).opacity(over ? 0.95 : 0.20))
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(over ? Color.white : Color(hex: 0xFF6B60))
            }
            .frame(width: 21, height: 21)
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .onHover { over = $0 }
        .help("Delete task")
        .accessibilityLabel("Delete task")
    }
}

// MARK: - Colour

/// A plain Button plus a popover, deliberately not a Menu.
///
/// A Menu's label is drawn by AppKit and its background does not reliably
/// render — a bare coloured circle as a menu label can end up invisible, which
/// for a control whose entire job is showing a colour is fatal. A Button always
/// draws, and the popover gives direct selection rather than cycling.
private struct ColorDot: View {
    let hex: UInt32?
    let fallback: Color
    let onPick: (UInt32?) -> Void

    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Circle()
                .fill(hex.map { Color(hex: $0) } ?? fallback)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 0.8))
                .frame(width: 18, height: 18)      // a reachable hit target
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Task colour")
        .accessibilityLabel("Task colour")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(spacing: 9) {
                HStack(spacing: 7) {
                    ForEach(TaskPalette.all, id: \.hex) { swatch in
                        Button {
                            onPick(swatch.hex)
                            showing = false
                        } label: {
                            Circle()
                                .fill(Color(hex: swatch.hex))
                                .frame(width: 19, height: 19)
                                .overlay(
                                    Circle().strokeBorder(
                                        Color.primary.opacity(hex == swatch.hex ? 0.9 : 0.18),
                                        lineWidth: hex == swatch.hex ? 2 : 0.8)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(swatch.name)
                    }
                }
                Button("Use theme colour") {
                    onPick(nil)
                    showing = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(12)
        }
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
                .background(Capsule().fill(Color.white.opacity(0.16)))
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
