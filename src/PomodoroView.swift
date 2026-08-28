import SwiftUI

// MARK: - Root

struct PomodoroView: View {
    @ObservedObject var engine: TimerEngine
    @ObservedObject var prefs: Prefs
    @ObservedObject var ui: UIState = UIState()

    var onToggleDrawer: () -> Void = {}
    var onHoverChange: (Bool) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}

    /// Preview-only: lets the offscreen renderer show the hover layout, which
    /// is otherwise unreachable without a real pointer.
    var previewHover = false

    @State private var rawHover = false
    private var hovering: Bool { rawHover || previewHover }
    @State private var pulse: CGFloat = 1

    // MARK: Geometry
    //
    // The window is deliberately larger than the disc. That transparent ring of
    // margin is what the drop shadow lives in — without it the shadow gets
    // clipped by the window bounds and reads as a grey box.

    private var side: CGFloat { CGFloat(prefs.size) }
    private var disc: CGFloat { side * 0.82 }
    private var discR: CGFloat { disc / 2 }
    /// Scale factor against the reference disc, so the numbers below stay legible.
    private var u: CGFloat { disc / 172 }
    private var lineWidth: CGFloat { max(3.5, 11 * u) }
    private var ring: CGFloat { disc - lineWidth - 19 * u }

    /// Per-axis offset that puts the gear and close buttons on the 45° points
    /// of the disc's edge — out in the bezel with the resize grip and the drawer
    /// tab, rather than inside the ring.
    ///
    /// They used to tuck inside the stroke, which was fine for a short "FOCUS"
    /// label but collides head-on with a task name, since the name wants the
    /// full width of the dial. Moving them to the rim gives the headline the
    /// whole top of the disc and groups every edge control together.
    private var cornerInset: CGFloat { discR * 0.7071 }

    /// Below this there is no room for the time *and* the controls, so hovering
    /// swaps one for the other rather than hiding the controls entirely.
    private var compact: Bool { side < 150 }
    /// The phase label is decoration: the ring colour already tells you which
    /// mode you're in, so it yields when space is tight. A task name is content
    /// and always shows — it was gated at 172pt, which silently hid it on any
    /// dial smaller than that.
    private var showLabel: Bool { engine.headlineIsTask || side >= 168 }
    private var showDots: Bool { side >= 150 }

    private var colors: [Color] { prefs.theme.colors(for: engine.phase) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !engine.isRunning)) { ctx in
            let left     = engine.liveRemaining(at: ctx.date)
            let total    = engine.duration(for: engine.phase)
            let progress = total > 0 ? max(0, min(1, left / total)) : 0
            face(progress: progress, left: left)
        }
        .frame(width: side, height: side)
        .scaleEffect(pulse)
        // The material must not sample the desktop's light/dark appearance —
        // pinned dark keeps the disc black over any wallpaper or editor theme.
        .environment(\.colorScheme, .dark)
        .onChange(of: engine.pulse) { _, _ in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) { pulse = 1.07 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.62)) { pulse = 1 }
            }
        }
        .onHover { h in
            withAnimation(.easeOut(duration: 0.16)) { rawHover = h }
            onHoverChange(h)
        }
    }

    // MARK: Face

    @ViewBuilder
    private func face(progress: Double, left: TimeInterval) -> some View {
        ZStack {
            dial(progress: progress)
            readout(left: left)
            cornerButtons
            drawerTab
        }
        .help(engine.activeTaskTitle ?? engine.phase.title)
        .animation(.easeInOut(duration: 0.35), value: engine.phase)
        .animation(.easeInOut(duration: 0.2), value: prefs.themeID)
    }

    private func dial(progress: Double) -> some View {
        ZStack {
            plate
            track
            arc(progress: progress)
        }
        .frame(width: disc, height: disc)
        // Two shadows: a wide soft one for lift, a tight dark one for the edge.
        .shadow(color: .black.opacity(0.52), radius: 9 * u, y: 4 * u)
        .shadow(color: .black.opacity(0.35), radius: 2.5 * u, y: 1)
    }

    private var plate: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(Color.black.opacity(0.55))
            // A faint sheen from the upper-left so it reads as glass, not paint.
            Circle().fill(
                RadialGradient(colors: [.white.opacity(0.07), .clear],
                               center: UnitPoint(x: 0.32, y: 0.18),
                               startRadius: 0, endRadius: disc * 0.8)
            )
            Circle().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.04)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.8
            )
        }
    }

    private var track: some View {
        Circle()
            .stroke(Color.white.opacity(0.09), lineWidth: lineWidth)
            .frame(width: ring, height: ring)
    }

    private func arc(progress: Double) -> some View {
        let gradient = AngularGradient(
            gradient: Gradient(colors: colors + [colors[0]]),
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
        return ZStack {
            // Glow pass underneath the real stroke; it's the glow that fades
            // when paused, not the colour — dimming the colour looked muddy.
            Circle()
                .trim(from: 1 - progress, to: 1)
                .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .blur(radius: 6 * u)
                .opacity(engine.isRunning ? 0.55 : 0.12)
            Circle()
                .trim(from: 1 - progress, to: 1)
                .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .opacity(engine.isRunning ? 1 : 0.9)
        }
        .rotationEffect(.degrees(-90))
        .frame(width: ring, height: ring)
    }

    // MARK: Readout

    private func readout(left: TimeInterval) -> some View {
        ZStack {
            VStack(spacing: 2 * u) {
                if showLabel {
                    // A task name is content, so it gets sentence case, more
                    // weight and more contrast. A phase name is a label, so it
                    // keeps the small tracked-caps treatment.
                    Text(engine.headline)
                        // Floored, or it scales into illegibility on a small dial.
                        .font(.system(size: engine.headlineIsTask
                                        ? max(10, 10.5 * u)
                                        : max(8, 9 * u),
                                      weight: .semibold, design: .rounded))
                        .tracking(engine.headlineIsTask ? 0 : 2.2 * u)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: ring * 0.80)
                        .foregroundStyle(.white.opacity(engine.headlineIsTask ? 0.80 : 0.55))
                }

                Text(TimerEngine.format(left))
                    .font(.system(size: 37 * u, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    // Hard-capped to the ring's inner width and allowed to shrink,
                    // so the digits can never collide with the stroke — not at
                    // small sizes, and not when the clock rolls past an hour.
                    .minimumScaleFactor(0.4)
                    .frame(width: ring * 0.76)
                    .foregroundStyle(.white)

                if showDots {
                    ZStack {
                        dots.opacity(hovering ? 0 : 1)
                        controls.opacity(hovering ? 1 : 0)
                    }
                    .frame(height: 24 * u)
                }
            }
            // Compact: the controls take the readout's place instead of sitting
            // below it, so play/pause is reachable at every size.
            .opacity(compact && hovering ? 0 : 1)

            if compact {
                controls.opacity(hovering ? 1 : 0)
            }
        }
    }

    private var dots: some View {
        HStack(spacing: 5 * u) {
            ForEach(0..<engine.sessionsBeforeLongBreak, id: \.self) { i in
                Circle()
                    .fill(i < engine.dotsFilled ? colors[0] : Color.white.opacity(0.20))
                    .frame(width: 5 * u, height: 5 * u)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: max(6, 9 * u)) {
            IconButton(symbol: "arrow.counterclockwise", size: 10 * u,
                       unit: u, help: "Restart this phase") { engine.reset() }
            IconButton(symbol: engine.isRunning ? "pause.fill" : "play.fill",
                       size: 13 * u, unit: u, prominent: true, tint: colors[0],
                       help: engine.isRunning ? "Pause" : "Start") { engine.toggle() }
            IconButton(symbol: "forward.end.fill", size: 10 * u,
                       unit: u, help: "Skip to next phase") { engine.skip() }
        }
    }

    /// Gear and close sit on the 45° diagonals inside the ring, at every size.
    /// When compact the time swaps out for the controls, which frees the space
    /// these need — so neither Settings nor Quit is ever unreachable.
    private var cornerButtons: some View {
        let inset = cornerInset
        return ZStack {
            IconButton(symbol: "gearshape.fill", size: 9 * u, unit: u,
                       help: "Settings") { onOpenSettings() }
                .offset(x: -inset, y: -inset)
            IconButton(symbol: "xmark", size: 9 * u, unit: u, danger: true,
                       help: "Quit Pomodoro") { NSApp.terminate(nil) }
                .offset(x: inset, y: -inset)
        }
        .opacity(hovering ? 1 : 0)
    }

    /// A pull-tab hanging off the bottom edge of the disc. Kept faintly visible
    /// rather than hover-only: an invisible affordance is an unused feature, and
    /// this is the entry point to the whole task list.
    private var drawerTab: some View {
        Button(action: onToggleDrawer) {
            ZStack {
                Capsule().fill(Color.black.opacity(0.72))
                Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.6)
                Image(systemName: "chevron.down")
                    .font(.system(size: max(7, 8 * u), weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .rotationEffect(.degrees(ui.drawerOpen ? 180 : 0))
            }
            .frame(width: max(30, 34 * u), height: max(15, 17 * u))
        }
        .buttonStyle(.plain)
        .offset(y: discR + max(3, 4 * u))
        .opacity(hovering || ui.drawerOpen ? 1 : 0.45)
        .help(ui.drawerOpen ? "Hide tasks" : "Show tasks (⌃⌥⌘T)")
        .accessibilityLabel("Toggle task list")
    }
}

// MARK: - Button

private struct IconButton: View {
    let symbol: String
    var size: CGFloat = 11
    var unit: CGFloat = 1
    var prominent: Bool = false
    var tint: Color = .white
    var danger: Bool = false
    var help: String = ""
    let action: () -> Void

    @State private var over = false

    /// Floored so the hit target stays clickable at the smallest window sizes.
    private var diameter: CGFloat {
        prominent ? max(22, 27 * unit) : max(17, 21 * unit)
    }
    private var glyph: CGFloat { max(prominent ? 10 : 7.5, size) }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(prominent
                          ? AnyShapeStyle(tint.opacity(over ? 1.0 : 0.88))
                          : AnyShapeStyle(Color.white.opacity(over ? 0.28 : 0.15)))
                Image(systemName: symbol)
                    .font(.system(size: glyph, weight: .bold))
                    .foregroundStyle(prominent ? Color.black.opacity(0.85)
                                     : (danger && over ? Color(hex: 0xFF5F57) : .white.opacity(0.92)))
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(over ? 1.12 : 1)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { over = h } }
    }
}
