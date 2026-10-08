import SwiftUI
import IslandCore

/// Formula 1 pit-wall presentation of one session: a timing-tower line with position, team
/// stripe, project, sector lights, race status, and the lap clock.
///
/// The row is exactly `Theme.sessionRowHeight` tall, like the classic row, because the AppKit
/// click router maps clicks to sessions from that fixed geometry.
struct PitWallRow: View {
    let session: SessionInfo
    let position: Int
    let isLeader: Bool
    let isHovered: Bool
    /// Changes whenever the tower refreshes; rows then slide in from the right, staggered.
    let spinToken: Int

    private let positionWidth: CGFloat = 22
    private let sectorsWidth: CGFloat = 26
    private let statusWidth: CGFloat = 64
    private let timeWidth: CGFloat = 36

    @StateObject private var arrivedState = ViewState(true)

    private var arrived: Bool {
        get { arrivedState.value }
        nonmutating set { arrivedState.value = newValue }
    }

    private var team: Color { Theme.teamColor(for: session.project) }

    var body: some View {
        HStack(spacing: 4) {
            Text("\(position)")
                .font(Theme.raceFont(11))
                .foregroundStyle(isLeader ? .white : .black)
                .frame(width: positionWidth, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isLeader ? Theme.f1Red : .white.opacity(0.92))
                )
            RoundedRectangle(cornerRadius: 1)
                .fill(team)
                .frame(width: 3, height: 18)
                .shadow(color: team, radius: isHovered ? 4 : 1.5)
            Text(projectDisplay)
                .font(Theme.raceFont(11))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            SectorLights(state: session.state, startedAt: session.startedAt)
                .frame(width: sectorsWidth)
            RaceStatus(session: session)
                .frame(width: statusWidth)
            lapTime
                .frame(width: timeWidth, alignment: .trailing)
        }
        .padding(.horizontal, 5)
        .frame(height: Theme.sessionRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(.sRGB, white: isHovered ? 0.2 : 0.12, opacity: 0.95),
                             Color(.sRGB, white: 0.04, opacity: 0.95)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isHovered ? team : .white.opacity(isLeader ? 0.22 : 0.07),
                                      lineWidth: isHovered ? 1.4 : 0.8)
                )
                .shadow(color: team.opacity(isHovered ? 0.75 : 0), radius: 6)
        )
        // The notch shape's concave top corners narrow the visible body; stay clear of its edges.
        .padding(.horizontal, 5)
        .offset(x: arrived ? (isHovered ? -4 : 0) : 60)
        .opacity(arrived ? 1 : 0)
        .contentShape(Rectangle())
        .help(helpText)
        .accessibilityLabel("Position \(position), open \(projectDisplay) terminal")
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: isHovered)
        .onChange(of: spinToken) { _, _ in
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { arrived = false }
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72)
                    .delay(0.05 * Double(min(position, 10)))) {
                    arrived = true
                }
            }
        }
    }

    @ViewBuilder private var lapTime: some View {
        if session.startedAt > 0 {
            TimerText(startedAt: session.startedAt)
                .font(Theme.raceFont(10.5).monospacedDigit())
                .foregroundStyle(Theme.f1Yellow)
                .minimumScaleFactor(0.8)
        } else {
            switch session.state {
            case .done, .completed: Text("🏁").font(.system(size: 11))
            case .error:            Text("OUT").font(Theme.raceFont(10)).foregroundStyle(Theme.f1Red)
            default:                Text("—").font(Theme.raceFont(10)).foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private var projectDisplay: String {
        let p = session.project.isEmpty ? "session" : session.project
        return (p.count > 20 ? p.prefix(19) + "…" : p).uppercased()
    }

    private var helpText: String {
        session.detail.isEmpty
            ? "Open \(session.project) terminal"
            : "Open \(session.project) terminal · \(session.detail)"
    }
}

/// The race status chip: activity while on track, BOX BOX for permission, chequered flag when
/// finished, DNF on error, and IN PIT while idle.
private struct RaceStatus: View {
    let session: SessionInfo

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: flashRate == nil)) { context in
            let pulse = flashRate.map {
                0.5 + 0.5 * (0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * $0))
            } ?? 1
            Text(word)
                .id(word)
                .font(Theme.raceFont(9.5))
                .tracking(0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(foreground)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, minHeight: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(fill))
                .shadow(color: glow, radius: 3)
                .opacity(pulse)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: word)
        }
    }

    private var word: String {
        switch session.state {
        case .done:       return "🏁 FINISH"
        case .completed:  return "FINISHED"
        case .error:      return "DNF"
        case .idle:       return "IN PIT"
        case .permission:
            return session.label.localizedCaseInsensitiveContains("permission") ? "BOX BOX" : "📻 RADIO"
        default:
            let label = (session.label.isEmpty ? "Push" : session.label)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".… "))
                .uppercased()
            // The chip is narrow: "RUNNING COMMAND" reads better as "RUNNING" than truncated.
            return label.count > 11 ? String(label.split(separator: " ").first ?? Substring(label)) : label
        }
    }

    private var flashRate: Double? {
        switch session.state {
        case .done:       return 9
        case .permission: return 5
        default:          return nil
        }
    }

    private var foreground: Color {
        switch session.state {
        case .permission:        return .black
        case .error:             return .white
        case .idle:              return .white.opacity(0.45)
        case .done, .completed:  return .black
        default:                 return Theme.f1Mint
        }
    }

    private var fill: Color {
        switch session.state {
        case .permission:        return Theme.f1Yellow
        case .error:             return Theme.f1Red
        case .done, .completed:  return .white
        case .idle:              return .white.opacity(0.06)
        default:                 return Theme.f1Mint.opacity(0.12)
        }
    }

    private var glow: Color {
        switch session.state {
        case .permission:        return Theme.f1Yellow.opacity(0.8)
        case .error:             return Theme.f1Red.opacity(0.8)
        case .done:              return .white.opacity(0.7)
        default:                 return .clear
        }
    }
}

/// Three mini-sector lights. On track they light up in turn (yellow, green, purple); finished
/// sessions set an all-purple lap, permission holds yellow, a DNF shows red, and idle is dark.
private struct SectorLights: View {
    let state: AgentState
    let startedAt: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.5)
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { sector in
                    let color = color(sector: sector, tick: tick)
                    Capsule()
                        .fill(color)
                        .frame(width: 7, height: 4)
                        .shadow(color: color == Theme.sectorOff ? .clear : color, radius: 2)
                }
            }
        }
    }

    private func color(sector: Int, tick: Int) -> Color {
        switch state {
        case .thinking, .tool:
            let lit = tick % 4
            guard sector < lit else { return Theme.sectorOff }
            return [Theme.f1Yellow, Theme.f1Green, Theme.f1Purple][sector]
        case .done, .completed: return Theme.f1Purple
        case .permission:       return tick % 2 == 0 ? Theme.f1Yellow : Theme.sectorOff
        case .error:            return Theme.f1Red
        case .idle:             return Theme.sectorOff
        }
    }
}

/// The five red start lights under the timing tower. Every refresh plays the start sequence:
/// they come on one by one, then go out together — lights out and away we go.
struct StartLights: View {
    let spinToken: Int

    @StateObject private var litState = ViewState(0)
    @StateObject private var goState = ViewState(false)

    private var lit: Int {
        get { litState.value }
        nonmutating set { litState.value = newValue }
    }
    private var go: Bool {
        get { goState.value }
        nonmutating set { goState.value = newValue }
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<5, id: \.self) { index in
                let on = index < lit
                let color = go ? Theme.f1Green : (on ? Theme.f1Red : Color(.sRGB, red: 0.22, green: 0.03, blue: 0.04, opacity: 1))
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .shadow(color: (on || go) ? color : .clear, radius: 3)
            }
        }
        .onAppear(perform: runSequence)
        .onChange(of: spinToken) { _, _ in runSequence() }
    }

    private func runSequence() {
        lit = 0
        go = false
        for step in 1...5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16 * Double(step)) { lit = step }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
            withAnimation(.easeOut(duration: 0.08)) { lit = 0; go = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
            withAnimation(.easeOut(duration: 0.5)) { go = false }
        }
    }
}

/// Timing-screen badge for the collapsed bar in pit-wall style.
struct PitBadge: View {
    let text: String
    var stripe: Color = Theme.f1Red
    var showsFlag = false

    var body: some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1).fill(stripe).frame(width: 2.5, height: 11)
            if showsFlag { Text("🏁").font(.system(size: 8)) }
            Text(text)
                .font(Theme.raceFont(10).monospacedDigit())
                .foregroundStyle(.white)
        }
        .lineLimit(1)
        .padding(.leading, 3)
        .padding(.trailing, 5)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color(.sRGB, white: 0.13, opacity: 1)))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.18), lineWidth: 0.6))
    }
}

/// Carbon-fibre weave: fine diagonal hatching in both directions.
struct CarbonWeave: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let step: CGFloat = 4
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                path.move(to: CGPoint(x: x + size.height, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            context.stroke(path, with: .color(.white.opacity(0.035)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
