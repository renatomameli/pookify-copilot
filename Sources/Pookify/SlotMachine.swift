import SwiftUI
import IslandCore

/// Slot-machine presentation of one session: three gold-framed reels
/// (project · activity · timer/fruit) behind a blinking "winning line" for the session the
/// closed bar currently represents.
///
/// The row is exactly `Theme.sessionRowHeight` tall, like the classic row, because the AppKit
/// click router maps clicks to sessions from that fixed geometry.
struct SlotSessionRow: View {
    let session: SessionInfo
    let isWinningLine: Bool
    /// The pointer is over this row (tracked by the AppKit router).
    let isHovered: Bool
    /// Changes whenever the machine spins; each reel then drops in and stops in sequence.
    let spinToken: Int

    private let gutter: CGFloat = 8
    private let resultWidth: CGFloat = 42
    private let activityWidth: CGFloat = 112

    private var hovering: Bool { isHovered }

    var body: some View {
        HStack(spacing: 3) {
            WinMarker(symbol: "arrowtriangle.right.fill", visible: isWinningLine || hovering)
                .frame(width: gutter)
            ReelCell(outline: nil, lit: hovering, spinToken: spinToken, stopDelay: 0) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 5, height: 5)
                        .shadow(color: dotColor, radius: 2)
                    Text(projectDisplay)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(.sRGB, red: 1, green: 0.95, blue: 0.85, opacity: 1))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 6)
            }
            ReelCell(outline: activityOutline, lit: hovering, spinToken: spinToken, stopDelay: 0.12) {
                ActivityReel(word: activityWord, tone: tone, flashRate: flashRate)
            }
            .frame(width: activityWidth)
            ReelCell(outline: nil, lit: hovering, spinToken: spinToken, stopDelay: 0.24) {
                result
            }
            .frame(width: resultWidth)
            WinMarker(symbol: "arrowtriangle.left.fill", visible: isWinningLine || hovering)
                .frame(width: gutter)
        }
        .frame(height: Theme.sessionRowHeight)
        .brightness(hovering ? 0.12 : 0)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.gold.opacity(isWinningLine ? 0.16 : hovering ? 0.12 : 0))
                .shadow(color: Theme.flame.opacity(hovering ? 0.7 : 0), radius: 6)
        )
        .scaleEffect(hovering ? 1.03 : 1)
        .contentShape(Rectangle())
        .help(helpText)
        .accessibilityLabel("Open \(projectDisplay) terminal, \(activityWord)")
        .animation(.spring(response: 0.22, dampingFraction: 0.6), value: hovering)
        .animation(.easeOut(duration: 0.2), value: isWinningLine)
    }

    @ViewBuilder private var result: some View {
        if session.startedAt > 0 {
            TimerText(startedAt: session.startedAt)
                .font(.system(size: 10.5, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.flameGradient)
                .shadow(color: Theme.flame.opacity(0.8), radius: 2)
                .minimumScaleFactor(0.8)
        } else {
            switch session.state {
            case .done, .completed: Text("🍒").font(.system(size: 13))
            case .error:            Text("💥").font(.system(size: 12))
            default:                Text("🍋").font(.system(size: 12)).opacity(0.75)
            }
        }
    }

    private var tone: ActivityReel.Tone {
        switch session.state {
        case .permission:        return .amber
        case .error:             return .red
        case .idle:              return .dim
        default:                 return .gold
        }
    }

    /// Flash quickly on a fresh jackpot, pulse on permission, otherwise steady.
    private var flashRate: Double? {
        switch session.state {
        case .done:       return 9
        case .permission: return 4
        default:          return nil
        }
    }

    private var activityOutline: Color? {
        switch session.state {
        case .permission:        return Theme.amber
        case .error:             return .red
        case .done, .completed:  return Theme.flame
        default:                 return nil
        }
    }

    private var dotColor: Color {
        switch session.state {
        case .permission, .error: return Theme.amber
        case .done, .completed:   return Theme.green
        case .idle:               return .white.opacity(0.35)
        default:                  return Theme.gold
        }
    }

    private var projectDisplay: String {
        let p = session.project.isEmpty ? "session" : session.project
        return p.count > 20 ? p.prefix(19) + "…" : p
    }

    private var activityWord: String {
        switch session.state {
        case .done:       return "JACKPOT!"
        case .completed:  return "JACKPOT"
        case .error:      return "BUST"
        case .idle:       return "IDLE"
        case .permission:
            return session.label.localizedCaseInsensitiveContains("permission")
                ? "🔔 PERMISSION" : "🔔 INPUT"
        default:
            return (session.label.isEmpty ? "Working" : session.label)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".… "))
                .uppercased()
        }
    }

    private var helpText: String {
        session.detail.isEmpty
            ? "Open \(projectDisplay) terminal"
            : "Open \(projectDisplay) terminal · \(session.detail)"
    }
}

/// Gold arrow marking the winning line; it blinks like a casino chaser light.
private struct WinMarker: View {
    let symbol: String
    let visible: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 2 == 0
            Image(systemName: symbol)
                .font(.system(size: 6.5, weight: .black))
                .foregroundStyle(Theme.goldGradient)
                .shadow(color: Theme.flame, radius: on ? 3 : 0)
                .opacity(visible ? (on ? 1 : 0.35) : 0)
        }
    }
}

/// One reel window: a dark red drum with a cylindrical highlight in a polished gold bezel. Its
/// content drops in from above and bounces to a stop whenever `spinToken` changes, delayed per
/// reel so the three stop left-to-right like a real machine.
private struct ReelCell<Content: View>: View {
    let outline: Color?
    var lit = false
    let spinToken: Int
    let stopDelay: Double
    @ViewBuilder var content: Content

    @StateObject private var landedState = ViewState(true)

    private var landed: Bool {
        get { landedState.value }
        nonmutating set { landedState.value = newValue }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: landed ? 0 : -26)
            .blur(radius: landed ? 0 : 2.5)
            .background(
                shape.fill(LinearGradient(
                    stops: [
                        .init(color: Color(.sRGB, red: 0.05, green: 0.0, blue: 0.0, opacity: 1), location: 0),
                        .init(color: Color(.sRGB, red: 0.30, green: 0.03, blue: 0.03, opacity: 1), location: 0.5),
                        .init(color: Color(.sRGB, red: 0.05, green: 0.0, blue: 0.0, opacity: 1), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom))
            )
            .overlay {
                if let outline {
                    shape.strokeBorder(outline, lineWidth: 1.4)
                        .shadow(color: outline, radius: 3)
                } else {
                    shape.strokeBorder(Theme.goldGradient, lineWidth: lit ? 1.8 : 1.2)
                        .shadow(color: Theme.flame.opacity(lit ? 0.9 : 0), radius: 3)
                }
            }
            .clipShape(shape)
            .onChange(of: spinToken) { _, _ in
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { landed = false }
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.48).delay(stopDelay)) {
                        landed = true
                    }
                }
            }
    }
}

/// The center reel. A new activity rolls in from the top while the old one rolls out below.
/// Fresh jackpots strobe; permission requests pulse amber until answered.
struct ActivityReel: View {
    enum Tone { case gold, amber, red, dim }

    let word: String
    let tone: Tone
    let flashRate: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: flashRate == nil)) { context in
            let brightness = flashRate.map {
                0.45 + 0.55 * (0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * $0))
            } ?? 1
            ZStack {
                styled(Text(word))
                    .id(word)
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .tracking(0.7)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 5)
                    .opacity(brightness)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)))
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.6), value: word)
        }
    }

    @ViewBuilder private func styled(_ text: Text) -> some View {
        switch tone {
        case .gold:
            text.foregroundStyle(Theme.flameGradient)
                .shadow(color: Theme.flame.opacity(0.9), radius: 2.5)
        case .amber:
            text.foregroundStyle(Theme.amber)
                .shadow(color: Theme.amber.opacity(0.9), radius: 2.5)
        case .red:
            text.foregroundStyle(Color.red)
                .shadow(color: .red, radius: 2.5)
        case .dim:
            text.foregroundStyle(Color.white.opacity(0.4))
        }
    }
}

/// Chasing marquee bulbs along the bottom of the cabinet.
struct MarqueeBulbs: View {
    let count: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.16)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.16)
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    let lit = (index + step) % 3 == 0
                    Circle()
                        .fill(lit ? Theme.gold : Color(.sRGB, red: 0.35, green: 0.16, blue: 0.02, opacity: 1))
                        .frame(width: 4, height: 4)
                        .shadow(color: lit ? Theme.flame : .clear, radius: 3)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// The side lever: a gold arm with a glossy green knob. Every spin swings it down and lets it
/// spring back up.
struct SlotLever: View {
    let spinToken: Int

    @StateObject private var pulledState = ViewState(false)

    private var pulled: Bool {
        get { pulledState.value }
        nonmutating set { pulledState.value = newValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(RadialGradient(
                    colors: [Color(.sRGB, red: 0.75, green: 1, blue: 0.7, opacity: 1),
                             Theme.knobGreen,
                             Color(.sRGB, red: 0.05, green: 0.35, blue: 0.08, opacity: 1)],
                    center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0.5, endRadius: 8))
                .frame(width: 13, height: 13)
                .shadow(color: .black.opacity(0.6), radius: 1.5, y: 1)
            Capsule()
                .fill(LinearGradient(
                    colors: [Color(.sRGB, red: 0.7, green: 0.42, blue: 0.05, opacity: 1),
                             Color(.sRGB, red: 1, green: 0.95, blue: 0.7, opacity: 1),
                             Theme.gold,
                             Color(.sRGB, red: 0.6, green: 0.35, blue: 0.03, opacity: 1)],
                    startPoint: .leading, endPoint: .trailing))
                .frame(width: 4, height: 34)
        }
        .scaleEffect(x: 1, y: pulled ? -0.85 : 1, anchor: .bottom)
        .frame(height: 47, alignment: .bottom)
        .overlay(alignment: .bottom) {
            // Gold mount bolted to the cabinet side.
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.goldGradient)
                .frame(width: 10, height: 12)
                .overlay(Circle().fill(Color.black.opacity(0.45)).frame(width: 3, height: 3))
                .offset(y: 6)
        }
        .onChange(of: spinToken) { _, _ in
            withAnimation(.easeIn(duration: 0.14)) { pulled = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.45)) { pulled = false }
            }
        }
        .help("Pull to spin")
    }
}

/// An LCD-like credit window used for the collapsed badges in slot-machine style.
struct SlotCounter: View {
    let text: String
    var showsCheck = false

    var body: some View {
        HStack(spacing: 2) {
            if showsCheck {
                Image(systemName: "checkmark").font(.system(size: 7, weight: .black))
            }
            Text(text).font(.system(size: 9.5, weight: .black, design: .rounded).monospacedDigit())
        }
        .foregroundStyle(Theme.flameGradient)
        .shadow(color: Theme.flame.opacity(0.9), radius: 2)
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Theme.cabinetDeep))
        .overlay(Capsule().strokeBorder(Theme.goldGradient, lineWidth: 1))
    }
}
