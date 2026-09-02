import SwiftUI
import IslandCore

/// A lightweight Copilot-inspired robot mark drawn entirely with SwiftUI. It avoids bundled
/// artwork while remaining legible at notch size.
private struct CopilotMark: View {
    let color: Color
    let phase: Double
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .fill(color.opacity(0.18))
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .stroke(color, lineWidth: max(1.2, size * 0.09))
            HStack(spacing: size * 0.18) {
                Circle().fill(.white)
                Circle().fill(.white)
            }
            .frame(width: size * 0.48, height: size * 0.18)
        }
        .frame(width: size * 0.88, height: size * 0.68)
        .overlay(alignment: .top) {
            HStack(spacing: size * 0.38) {
                Capsule().fill(color)
                    .frame(width: size * 0.12, height: size * 0.22)
                    .rotationEffect(.degrees(-18))
                Capsule().fill(color)
                    .frame(width: size * 0.12, height: size * 0.22)
                    .rotationEffect(.degrees(18))
            }
            .offset(y: -size * 0.13)
        }
        .rotationEffect(.degrees(phase * 3.5))
        .offset(y: phase * -0.45)
        .scaleEffect(1 + abs(phase) * 0.025)
    }
}

/// The agent identity mark is fixed on the left wing. It gently moves while Copilot works and
/// rests for permission, completion, and error states.
struct AgentGlyph: View {
    let provider: Provider
    var working: Bool = true
    var size: CGFloat = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 18.0, paused: !working)) { context in
            let phase = working
                ? sin(context.date.timeIntervalSinceReferenceDate * .pi * 2.0)
                : 0
            CopilotMark(color: Theme.accent(provider), phase: phase, size: size)
        }
        .frame(width: size, height: size)
    }
}
