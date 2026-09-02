import SwiftUI
import AppKit
import IslandCore

/// Root of the notch UI. Anchored flush to the top of the screen so it fuses with the physical
/// notch, easing in/out with the reveal transition.
struct IslandRootView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isVisible {
                IslandPill(model: model)
                    .transition(.notchReveal)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Open/close timing is driven per-direction from the controller (withAnimation) so the
        // retract can be slower than the emerge.
    }
}

/// Open/close motion: the slim bar grows out of the notch — its left and right edges sweep
/// outward from the camera — then settles. On close it retracts back into the notch. Anchored at
/// the top-center (the notch), it scales mostly horizontally so it reads like an iPhone Live
/// Activity appearing/disappearing.
private struct NotchReveal: ViewModifier {
    let progress: Double
    func body(content: Content) -> some View {
        // Pure horizontal scale, anchored at the notch — NO opacity fade. Fading a black pill over
        // the bright wallpaper turns it translucent-gray mid-animation (the "weird gray"); scaling
        // solid black into/out of the notch stays pure black the whole way.
        // Floor at 0.001, never 0: a zero scale is a singular transform, and the session stack's
        // NSScrollView asserts converting through its inverse (convertSizeFromBacking → abort).
        content
            .scaleEffect(x: max(0.001, progress), y: 1, anchor: .top)
    }
}
/// Close motion: the slim bar retracts into the notch the way it emerged — its left and right
/// edges sweep inward toward the camera. Pure horizontal scale: no vertical motion (nothing
/// "moves up"), no opacity fade, solid black the whole way. Safe because the hide path always
/// de-expands to the slim bar BEFORE this plays, so x-only never squishes a tall pill.
private struct NotchRetract: ViewModifier {
    let progress: Double   // 1 = full size, 0 = collapsed into the notch
    func body(content: Content) -> some View {
        // Same 0.001 floor as the reveal: never a singular (zero-scale) transform.
        content.scaleEffect(x: max(0.001, progress), y: 1, anchor: .top)
    }
}
extension AnyTransition {
    /// Per-direction timing attached to the transition itself (reliable, unlike withAnimation on a
    /// shared ObservableObject): a lively horizontal emerge, and a smooth scale-into-the-notch retract.
    static var notchReveal: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: NotchReveal(progress: 0), identity: NotchReveal(progress: 1))
                .animation(Theme.appear),
            removal: .modifier(active: NotchRetract(progress: 0), identity: NotchRetract(progress: 1))
                .animation(Theme.disappear)
        )
    }
}

/// The notch-fused black island.
///
/// - **Closed (slim):** balanced, symmetric wings — the agent glyph on the left of the camera and
///   the live timer on the right, the same size and distance so it reads perfectly centered on the
///   notch. No words here.
/// - **Expanded:** it grows **taller** (downward), never wider, so it never covers the menu bar.
///   The status wording ("Editing", "Awaiting permission", …) and a detail line drop in *below*
///   the notch. Pure flat black, no shadow — one object with the hardware.
struct IslandPill: View {
    @ObservedObject var model: IslandModel
    @State private var hoverWork: DispatchWorkItem?
    /// Which edges of the session stack currently hide rows — drives the edge fog.
    @State private var stackEdges = StackEdges(top: false, bottom: false)

    // Symmetric wing metrics — both sides identical so the camera gap is centered.
    private let wing: CGFloat = Theme.wing  // room for a 2-digit:2-digit clock (e.g. 15:48) with even margins
    private let iconSize: CGFloat = 18
    private let dropHeight: CGFloat = Theme.dropHeight
    // The notch shape's concave top corners inset each outer edge by ~topRadius, so content centered
    // in the raw wing lands a few px outside the visible black. Nudge each wing's content toward the
    // notch to optically center it in the area actually available beside the camera.
    private let wingInset: CGFloat = 4

    // `collapsing`/`opening` win over everything: while the island is being hidden OR emerging
    // it must present slim — it never retracts tall and never emerges tall.
    private var expanded: Bool {
        (model.hovering || model.isExpanded) && !model.collapsing && !model.opening
    }
    private var closedH: CGFloat { model.topInset }
    // The camera gap: the physical notch's width, or the synthetic notch's on displays
    // without one — the island renders identically either way.
    private var gap: CGFloat { model.notchWidth }
    private var closedWidth: CGFloat { wing + gap + wing }

    private func textWidth(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }
    private var labelW: CGFloat { textWidth(statusTitle, 13.5, .semibold) }

    // Width stays equal to the closed width on a notched Mac (so expanding never widens it). Only on
    // a non-notched display, where the gap is tiny, does it widen enough to fit the dropped-in label.
    // (The session stack lays out within the closed width, so it never asks for more.)
    private var pillWidth: CGFloat {
        expanded && !model.isMulti ? max(closedWidth, labelW + 40) : closedWidth
    }
    private var pillHeight: CGFloat { expanded ? closedH + model.dropHeight : closedH }

    var body: some View {
        let topR: CGFloat = 7
        let bottomR: CGFloat = expanded ? 20 : max(10, closedH * 0.40)
        let shape = NotchShape(topRadius: topR, bottomRadius: bottomR)

        ZStack(alignment: .top) {
            shape.fill(Theme.pill)
            VStack(spacing: 0) {
                notchRow
                    .frame(width: closedWidth, height: closedH)
                dropDown
                    .frame(height: model.dropHeight)
                    .opacity(expanded ? 1 : 0)
            }
        }
        .frame(width: pillWidth, height: pillHeight, alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        .onHover { isOver in
            hoverWork?.cancel()
            if isOver {
                // small intent delay so a passing pointer doesn't pop it open
                let work = DispatchWorkItem { model.hovering = true }
                hoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            } else {
                model.hovering = false
            }
        }
        .onTapGesture { model.onActivate?() }
        .contextMenu { menuItems }
        .animation(Theme.expand, value: expanded)
        .animation(Theme.expand, value: model.state)
        .animation(Theme.expand, value: model.showsTimer)
        .animation(Theme.expand, value: model.sessions.count)
    }

    // MARK: closed row (balanced, centered on the camera)

    private var notchRow: some View {
        HStack(spacing: 0) {
            // Left wing — the agent's mark, ALWAYS here, centered (never moves between states).
            // Animates while working and rests next to the status when attention is needed.
            AgentGlyph(provider: model.provider, working: model.state.isWorking, size: iconSize)
                .frame(width: iconSize, height: iconSize)
                .frame(width: wing, height: closedH)
                .offset(x: wingInset)                  // nudge toward the notch to optically center

            Color.clear.frame(width: gap, height: closedH)

            // Right wing — the status, centered to mirror the agent mark: timer while working,
            // a check when done, an amber dot for permission, a warning on error.
            rightStatus
                .frame(width: wing, height: closedH)
                .offset(x: -wingInset)                 // mirror nudge so the bar stays balanced
        }
    }

    @ViewBuilder private var rightStatus: some View {
        if model.isMulti && model.state.isWorking && model.readyCount > 0 {
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                Text("\(model.readyCount)")
                    .font(.system(size: 10.5, weight: .bold).monospacedDigit())
            }
            .foregroundStyle(Theme.green)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Theme.green.opacity(0.16)))
            .accessibilityLabel("\(model.readyCount) sessions ready")
            .help("\(model.readyCount) \(model.readyCount == 1 ? "session" : "sessions") ready")
        } else if model.isMulti && model.state.isWorking {
            // Several sessions, several clocks — one timer would just be whichever session
            // happens to lead, which reads as wrong. With none ready, show how many are live;
            // once a session finishes, this becomes the green ready-count badge above.
            Text("\(model.sessions.count)")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
                .padding(.horizontal, 6.5)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(.white.opacity(0.13)))
        } else if model.showsTimer {
            TimerText(startedAt: model.startedAt)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
        } else {
            switch model.state {
            case .permission:
                Circle().fill(Theme.amber).frame(width: 8, height: 8)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: iconSize * 0.62, weight: .bold))
                    .foregroundStyle(Theme.accent(model.provider))
            case .completed:
                // A resting, finished session: a calm green check (the just-finished .done flash
                // uses the orange accent; green tells apart "done and waiting" from "just done").
                Image(systemName: "checkmark")
                    .font(.system(size: iconSize * 0.58, weight: .bold))
                    .foregroundStyle(Theme.green.opacity(0.9))
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: iconSize * 0.6, weight: .semibold))
                    .foregroundStyle(Theme.amber)
            default:
                Color.clear
            }
        }
    }

    // MARK: drop-down (the taller part — words live here)

    /// One session: today's layout, untouched. Two or more: the session stack.
    @ViewBuilder private var dropDown: some View {
        if model.isMulti {
            sessionStack
        } else {
            singleDrop
        }
    }

    private var singleDrop: some View {
        VStack(spacing: 4) {
            if model.state.isWorking {
                // Live "AI shimmer" sweeping across the current activity word + dots.
                WorkingLabel(word: statusWord)
            } else {
                Text(statusTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Capsule()
                .fill(accentColor)
                .frame(width: 26, height: 2.5)
                .opacity(0.9)
            if !model.detail.isEmpty {
                Text(model.detail)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 5)
    }

    // MARK: session stack (2+ sessions — every session as a row, most urgent first)

    /// Ten rows tall; with more sessions the list scrolls (trackpad/wheel) and part of the
    /// eleventh row peeks out, fogged into the black — the scroll affordance. The fog lifts once
    /// you reach the bottom, and a matching fade appears at the top when rows sit above.
    ///
    /// At-edge detection reads the content's REAL frame in the scroll viewport (not computed
    /// heights, which can drift from layout by a pixel and leave the fog stuck on the last row):
    /// fog below only while the content's actual bottom edge lies past the viewport.
    @ViewBuilder private var sessionStack: some View {
        let scroll = ScrollView(.vertical) {
            VStack(spacing: Theme.sessionRowSpacing) {
                ForEach(model.sessions) { session in
                    SessionRow(session: session,
                               isDisplayed: session.id == model.displayedId,
                               select: { model.onSelectSession(session.id) })
                }
            }
            .padding(.horizontal, 6)   // slim insets: rows need every point of width
            .padding(.top, 7)
            .padding(.bottom, 9)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)

        // Which edges hide rows right now. GeometryReader preferences CANNOT provide this on
        // macOS — they never re-collect across the NSScrollView bridge (they report zero, once)
        // — so use the purpose-built scroll-geometry API where available.
        if #available(macOS 15.0, *) {
            scroll
                .onScrollGeometryChange(for: StackEdges.self) { geo in
                    StackEdges(top: geo.contentOffset.y > 2,
                               bottom: geo.contentOffset.y + geo.containerSize.height
                                       < geo.contentSize.height - 2)
                } action: { _, edges in
                    stackEdges = edges
                }
                .mask(stackFog)
        } else {
            // macOS 14 has no reliable scroll-offset source: keep the fog on whenever the list
            // overflows. It can't lift at the very bottom there — a fair trade for correctness
            // everywhere else.
            scroll
                .onAppear { stackEdges = StackEdges(top: false, bottom: stackOverflows) }
                .onChange(of: model.sessions.count) { _, _ in
                    stackEdges = StackEdges(top: false, bottom: stackOverflows)
                }
                .mask(stackFog)
        }
    }

    private var stackOverflows: Bool { model.sessions.count > Theme.sessionRowsVisible }

    private var stackFog: some View {
        let viewH = model.dropHeight
        let fogTop = stackEdges.top
        let fogBottom = stackEdges.bottom
        return (
            // Content dissolves into the pill at whichever edge hides more rows — a deep fog,
            // no other chrome. Over pure black this reads as fog, not a hard clip. The bottom
            // band is tall enough to swallow the whole peeking row.
            LinearGradient(stops: [
                .init(color: .black.opacity(fogTop ? 0 : 1), location: 0),
                .init(color: .black, location: fogTop ? 18 / viewH : 0),
                .init(color: .black, location: fogBottom ? 1 - 32 / viewH : 1),
                // An eased midpoint makes the fog thicken fast: the peeking row reads as a
                // silhouette dissolving into the pill, not as dimmed-but-legible text.
                .init(color: .black.opacity(fogBottom ? 0.28 : 1), location: fogBottom ? 1 - 12 / viewH : 1),
                .init(color: .black.opacity(fogBottom ? 0 : 1), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .animation(.easeOut(duration: 0.18), value: fogTop)
            .animation(.easeOut(duration: 0.18), value: fogBottom)
        )
    }

    @ViewBuilder private var menuItems: some View {
        if let pin = model.pinnedId, model.isMulti {
            Button("Unpin — follow the busiest session") { model.onSelectSession(pin) }
            Divider()
        }
        if NSScreen.screens.count > 1 {
            Menu("Display") {
                // Automatic owns the check whenever the preference isn't in effect — including a
                // saved display that's currently disconnected, so the menu never shows no choice.
                Button((NSScreen.preferredDisplayConnected ? "" : "✓ ") + "Automatic") { chooseDisplay(nil) }
                Divider()
                ForEach(NSScreen.screens, id: \.self) { screen in
                    if let id = screen.displayID {
                        Button((NSScreen.preferredDisplayID == id ? "✓ " : "") + screenLabel(screen)) {
                            chooseDisplay(id)
                        }
                    }
                }
            }
        }
        Divider()
        Button("Quit") { model.onQuit() }
    }

    /// A human-readable menu label for a display, marking the built-in (notched) and primary
    /// screens so identically-named externals stay distinguishable. (`screens.first` is the
    /// primary display — NSScreen.main is merely the one with keyboard focus, which changes
    /// with whatever app is frontmost.)
    private func screenLabel(_ screen: NSScreen) -> String {
        var name = screen.localizedName
        if screen.hasNotch { name += " (built-in)" }
        else if screen == NSScreen.screens.first { name += " (main)" }
        return name
    }

    private func chooseDisplay(_ id: CGDirectDisplayID?) {
        hoverWork?.cancel()
        model.hovering = false
        model.onChooseDisplay(id)
    }

    private var accentColor: Color {
        switch model.state {
        case .permission, .error: return Theme.amber
        default:                  return Theme.accent(model.provider)
        }
    }

    private var statusTitle: String {
        switch model.state {
        case .permission: return model.label.isEmpty ? "Awaiting input" : model.label
        case .done:       return "Done"
        case .completed:  return "Done"
        case .error:      return "Error"
        case .idle:       return "Idle"
        default:          return model.label.isEmpty ? "Working…" : model.label
        }
    }

    /// The working label with any trailing dots stripped (WorkingLabel adds its own animated ellipsis).
    private var statusWord: String {
        var w = statusTitle
        while let last = w.last, last == "…" || last == "." || last == " " { w.removeLast() }
        return w
    }
}

/// Which edges of the session stack currently hide rows beyond them.
private struct StackEdges: Equatable {
    var top: Bool
    var bottom: Bool
}

/// One session in the expanded stack: state dot · project · activity (+ file) · live timer.
/// Clicking a row focuses its terminal and pins the session to the island (clicking the pinned
/// one unpins). The row's tap gesture wins over the pill's expand/collapse toggle.
private struct SessionRow: View {
    let session: SessionInfo
    let isDisplayed: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text(projectDisplay)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .layoutPriority(1)
                // Activity + file name: the file name is the informative part and must stay whole.
                // When both can't fit, the generic label drops out entirely so only useful context
                // remains. A truly long file name truncates in the middle to preserve its extension.
                Group {
                    if session.detail.isEmpty {
                        activityText
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 4) {
                                activityText
                                detailText
                            }
                            detailText
                        }
                    }
                }
                .layoutPriority(0.9)
                Spacer(minLength: 4)
                trailing
                    .layoutPriority(1)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.sessionRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(isDisplayed ? 0.09 : hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(projectDisplay) terminal")
        .accessibilityLabel("Open \(projectDisplay) terminal, \(activityWord)")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: isDisplayed)
    }

    private var dotColor: Color {
        switch session.state {
        case .permission, .error: return Theme.amber
        case .completed:          return Theme.green
        default:                  return Theme.accent(session.provider)
        }
    }

    private var activityText: some View {
        Text(activityWord)
            .font(.system(size: 10.5))
            .foregroundStyle(session.state == .permission ? Theme.amber : .white.opacity(0.52))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var detailText: some View {
        Text("· " + session.detail)
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.52))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// A pathological project (folder) name must not starve the whole row — cap it hard;
    /// normal repo names pass through untouched.
    private var projectDisplay: String {
        let p = session.project.isEmpty ? "session" : session.project
        return p.count > 20 ? p.prefix(19) + "…" : p
    }

    private var activityWord: String {
        switch session.state {
        case .permission: return session.label.isEmpty ? "Awaiting input" : session.label
        case .done:       return "Done"
        case .completed:  return "Done"
        case .error:      return "Error"
        default:          return session.label.isEmpty ? "Working…" : session.label
        }
    }

    /// Timer while the turn runs (it keeps counting through a permission wait, like the real turn
    /// clock); a check or warning for the transient end states.
    @ViewBuilder private var trailing: some View {
        if session.startedAt > 0 {
            TimerText(startedAt: session.startedAt)
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(session.state == .permission ? 0.55 : 0.8))
        } else if session.state == .done {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.accent(session.provider))
        } else if session.state == .completed {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.green)
        } else if session.state == .error {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.amber)
        }
    }
}

/// The active-status word with a soft left-to-right "AI shimmer" (a bright band sweeps across the dim
/// text) plus an animated ellipsis. Driven from absolute time so the motion is smooth and continuous.
struct WorkingLabel: View {
    let word: String

    var body: some View {
        // 30 updates/s is visually indistinguishable for a slow 2.6s shimmer sweep and gentle
        // dots, and far cheaper than the display-refresh-rate (up to 120Hz) default.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Text(word)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
                .overlay(alignment: .trailing) {
                    // animated ellipsis just past the word, so the label width never jiggles
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle().frame(width: 2.6, height: 2.6).opacity(dotOpacity(t, i))
                        }
                    }
                    .offset(x: 13, y: 1)
                }
                .padding(.trailing, 15)   // reserve room for the dots
                .foregroundStyle(shimmer(t))
        }
    }

    private func dotOpacity(_ t: Double, _ i: Int) -> Double {
        let cycle = (t * 2.2).truncatingRemainder(dividingBy: 3.0)   // 0..3, one dot lights at a time
        return 0.2 + 0.8 * max(0, 1 - abs(cycle - Double(i)))
    }

    /// A dim gradient with a soft bright band whose center sweeps left→right and loops. Gentle:
    /// slow sweep and low contrast so it reads as a subtle shimmer, not a strobe.
    private func shimmer(_ t: Double) -> LinearGradient {
        let period = 2.6
        let p = (t.truncatingRemainder(dividingBy: period)) / period   // 0..1
        let c = p * 1.4 - 0.2                                            // band center: -0.2 … 1.2
        func loc(_ v: Double) -> Double { min(1, max(0, v)) }
        let dim = Color.white.opacity(0.62)
        let bright = Color.white.opacity(0.9)
        return LinearGradient(
            stops: [
                .init(color: dim,    location: 0),
                .init(color: dim,    location: loc(c - 0.3)),
                .init(color: bright, location: loc(c)),
                .init(color: dim,    location: loc(c + 0.3)),
                .init(color: dim,    location: 1),
            ],
            startPoint: .leading, endPoint: .trailing)
    }
}

/// Live elapsed clock, ticking each second. Never wraps (single line, monospaced).
struct TimerText: View {
    let startedAt: Double
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(elapsedString(Int(context.date.timeIntervalSince1970 - startedAt)))
        }
    }
}
