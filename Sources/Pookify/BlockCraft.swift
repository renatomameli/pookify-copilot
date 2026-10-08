import SwiftUI
import IslandCore

/// Block Craft presentation of one session: a bevelled inventory slot holding a pixel-art block
/// (stone being mined while working, a gem when finished, flashing TNT for permission), the
/// project in shadowed block lettering, the activity, and the elapsed time as a green XP number.
///
/// The row is exactly `Theme.sessionRowHeight` tall, like the classic row, because the AppKit
/// click router maps clicks to sessions from that fixed geometry.
struct BlockCraftRow: View {
    let session: SessionInfo
    let isSelected: Bool
    let isHovered: Bool
    let index: Int
    /// Changes whenever the island opens; the slots then pop in like picked-up items.
    let spinToken: Int

    @StateObject private var poppedState = ViewState(true)

    private var popped: Bool {
        get { poppedState.value }
        nonmutating set { poppedState.value = newValue }
    }

    var body: some View {
        HStack(spacing: 6) {
            BlockIcon(kind: BlockIcon.Kind(session.state), seed: session.project.count)
                .frame(width: 18, height: 18)
                .scaleEffect(isHovered ? 1.15 : 1)
            Text(projectDisplay)
                .blockText(size: 11, color: .white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(activity)
                .blockText(size: 9.5, color: activityColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 76, alignment: .trailing)
                .modifier(Blink(rate: blinkRate))
            xp
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: Theme.sessionRowHeight)
        .background(BevelSlot(selected: isSelected, hovered: isHovered))
        .padding(.horizontal, 5)
        .scaleEffect(popped ? 1 : 0.3)
        .opacity(popped ? 1 : 0)
        .contentShape(Rectangle())
        .help(helpText)
        .accessibilityLabel("Open \(projectDisplay) terminal, \(activity)")
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: isHovered)
        .onChange(of: spinToken) { _, _ in
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { popped = false }
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.55)
                    .delay(0.05 * Double(min(index, 10)))) {
                    popped = true
                }
            }
        }
    }

    @ViewBuilder private var xp: some View {
        if session.startedAt > 0 {
            TimerText(startedAt: session.startedAt)
                .blockText(size: 10.5, color: Theme.xpGreen)
                .minimumScaleFactor(0.8)
        } else {
            Text(session.state == .idle ? "z Z" : "—")
                .blockText(size: 10, color: Theme.mcGray)
        }
    }

    private var projectDisplay: String {
        let p = session.project.isEmpty ? "session" : session.project
        return p.count > 20 ? p.prefix(19) + "…" : p
    }

    private var activity: String {
        switch session.state {
        case .done:       return "DIAMONDS!"
        case .completed:  return "Crafted"
        case .error:      return "You died"
        case .idle:       return "Sleeping"
        case .permission:
            return session.label.localizedCaseInsensitiveContains("permission") ? "TNT! Allow?" : "Respond!"
        case .thinking:   return "Brewing"
        case .tool:
            let label = session.label.lowercased()
            if label.contains("edit") || label.contains("writ") { return "Crafting" }
            if label.contains("read") || label.contains("search") { return "Mining" }
            if label.contains("run") { return "Smelting" }
            if label.contains("web") || label.contains("fetch") { return "Exploring" }
            if label.contains("deleg") || label.contains("agent") { return "Trading" }
            if label.contains("plan") { return "Building" }
            return "Mining"
        }
    }

    private var activityColor: Color {
        switch session.state {
        case .done:              return Theme.mcAqua
        case .completed:         return Theme.mcGreen
        case .error, .permission: return Theme.mcRed
        case .idle:              return Theme.mcGray
        default:                 return Theme.mcYellow
        }
    }

    private var blinkRate: Double? {
        switch session.state {
        case .permission: return 0.45
        case .done:       return 0.2
        default:          return nil
        }
    }

    private var helpText: String {
        session.detail.isEmpty
            ? "Open \(projectDisplay) terminal"
            : "Open \(projectDisplay) terminal · \(session.detail)"
    }
}

/// Hard on/off blinking, like block-game UI text.
private struct Blink: ViewModifier {
    let rate: Double?

    func body(content: Content) -> some View {
        if let rate {
            TimelineView(.periodic(from: .now, by: rate)) { context in
                let on = Int(context.date.timeIntervalSinceReferenceDate / rate) % 2 == 0
                content.opacity(on ? 1 : 0.25)
            }
        } else {
            content
        }
    }
}

extension View {
    /// Bold monospaced lettering with a hard one-pixel drop shadow.
    func blockText(size: CGFloat, color: Color) -> some View {
        font(.system(size: size, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .shadow(color: Color(.sRGB, white: 0.08, opacity: 1), radius: 0, x: 1, y: 1)
    }
}

/// A square inventory slot: dark well, light top-left edge, dark bottom-right edge. The selected
/// session gets a thick white hotbar frame; hovering lightens the slot.
private struct BevelSlot: View {
    let selected: Bool
    let hovered: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(Color(.sRGB, white: hovered ? 0.36 : 0.2, opacity: 0.92))
            VStack(spacing: 0) {
                Rectangle().fill(.white.opacity(0.28)).frame(height: 1.5)
                Spacer(minLength: 0)
                Rectangle().fill(.black.opacity(0.65)).frame(height: 1.5)
            }
            HStack(spacing: 0) {
                Rectangle().fill(.white.opacity(0.28)).frame(width: 1.5)
                Spacer(minLength: 0)
                Rectangle().fill(.black.opacity(0.65)).frame(width: 1.5)
            }
            if selected || hovered {
                Rectangle().strokeBorder(.white.opacity(selected ? 0.95 : 0.55), lineWidth: 2)
            }
        }
    }
}

/// An 8×8 pixel-art block, drawn in code. Working sessions mine a stone block whose cracks grow;
/// permission is a flashing TNT block; finished sessions show a sparkling gem; errors are lava;
/// idle sessions are a grass block.
struct BlockIcon: View {
    enum Kind {
        case stone, grass, tnt, lava, diamond, emerald

        init(_ state: AgentState) {
            switch state {
            case .thinking, .tool: self = .stone
            case .permission:      self = .tnt
            case .done:            self = .diamond
            case .completed:       self = .emerald
            case .error:           self = .lava
            case .idle:            self = .grass
            }
        }

        var animated: Bool { self != .grass && self != .emerald }
    }

    let kind: Kind
    var seed = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.22)) { context in
            let tick = kind.animated ? Int(context.date.timeIntervalSinceReferenceDate / 0.22) : 0
            Canvas { ctx, size in
                let px = size.width / 8
                for y in 0..<8 {
                    for x in 0..<8 {
                        guard let color = color(x: x, y: y, tick: tick) else { continue }
                        ctx.fill(Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px,
                                             width: px + 0.3, height: px + 0.3)),
                                 with: .color(color))
                    }
                }
            }
        }
        .shadow(color: glow, radius: glow == .clear ? 0 : 3)
    }

    private var glow: Color {
        switch kind {
        case .diamond: return Theme.mcAqua.opacity(0.8)
        case .tnt:     return Theme.mcRed.opacity(0.7)
        case .lava:    return Color.orange.opacity(0.7)
        default:       return .clear
        }
    }

    private static let crackPath: [(Int, Int)] = [
        (3, 3), (4, 4), (2, 2), (5, 4), (4, 5), (1, 2), (6, 3), (3, 6),
        (2, 6), (6, 6), (1, 5), (5, 1), (6, 1), (1, 1), (7, 5), (0, 4),
    ]

    private static let gem: [String] = [
        "........",
        "..xxxx..",
        ".xwllmx.",
        "xwllllmx",
        "xllllmdx",
        ".xlmmdx.",
        "..xddx..",
        "...xx...",
    ]

    private func color(x: Int, y: Int, tick: Int) -> Color? {
        let n = Theme.pixelNoise(x, y, seed)
        switch kind {
        case .stone:
            let stage = tick % 7
            let cracked = Self.crackPath.prefix(stage * 3).contains { $0 == (x, y) }
            if cracked { return Color(.sRGB, white: 0.14, opacity: 1) }
            return Color(.sRGB, white: [0.42, 0.48, 0.53, 0.58][n % 4], opacity: 1)
        case .grass:
            let grassDepth = 2 + (Theme.pixelNoise(x, 0, seed + 7) % 2)
            if y < grassDepth {
                return [Color(.sRGB, red: 0.30, green: 0.62, blue: 0.20, opacity: 1),
                        Color(.sRGB, red: 0.37, green: 0.72, blue: 0.25, opacity: 1),
                        Color(.sRGB, red: 0.25, green: 0.55, blue: 0.17, opacity: 1)][n % 3]
            }
            return [Color(.sRGB, red: 0.47, green: 0.33, blue: 0.22, opacity: 1),
                    Color(.sRGB, red: 0.55, green: 0.39, blue: 0.26, opacity: 1),
                    Color(.sRGB, red: 0.40, green: 0.28, blue: 0.18, opacity: 1)][n % 3]
        case .tnt:
            if tick % 2 == 0 { return Color(.sRGB, white: 0.95, opacity: 1) }
            if y == 3 || y == 4 {
                let letter = (x == 2 || x == 4 || x == 5) && y == 3 || (x == 3 || x == 5) && y == 4
                return letter ? Color(.sRGB, white: 0.15, opacity: 1) : Color(.sRGB, white: 0.88, opacity: 1)
            }
            return [Color(.sRGB, red: 0.80, green: 0.15, blue: 0.10, opacity: 1),
                    Color(.sRGB, red: 0.68, green: 0.10, blue: 0.08, opacity: 1)][n % 2]
        case .lava:
            let m = Theme.pixelNoise(x, y, seed + tick)
            return [Color(.sRGB, red: 1.0, green: 0.55, blue: 0.05, opacity: 1),
                    Color(.sRGB, red: 0.95, green: 0.35, blue: 0.02, opacity: 1),
                    Color(.sRGB, red: 1.0, green: 0.80, blue: 0.20, opacity: 1),
                    Color(.sRGB, red: 0.80, green: 0.20, blue: 0.02, opacity: 1)][m % 4]
        case .diamond, .emerald:
            let row = Array(Self.gem[y])
            let isDiamond = kind == .diamond
            switch row[x] {
            case "x": return Color(.sRGB, white: 0.08, opacity: 1)
            case "w":
                // A sparkle that travels around the gem.
                return isDiamond && tick % 6 == 0 ? .white : Color(.sRGB, white: 0.95, opacity: 1)
            case "l": return isDiamond ? Theme.mcAqua : Theme.mcGreen
            case "m": return isDiamond ? Color(.sRGB, red: 0.2, green: 0.8, blue: 0.85, opacity: 1)
                                       : Color(.sRGB, red: 0.15, green: 0.7, blue: 0.3, opacity: 1)
            case "d": return isDiamond ? Color(.sRGB, red: 0.1, green: 0.5, blue: 0.6, opacity: 1)
                                       : Color(.sRGB, red: 0.08, green: 0.45, blue: 0.18, opacity: 1)
            default:  return nil
            }
        }
    }
}

/// A segmented experience bar along the bottom of the island: it fills as sessions finish.
struct XPBar: View {
    let ready: Int
    let total: Int

    var body: some View {
        let segments = 18
        let filled = total > 0 ? Int((Double(ready) / Double(total) * Double(segments)).rounded()) : 0
        HStack(spacing: 1) {
            ForEach(0..<segments, id: \.self) { index in
                Rectangle()
                    .fill(index < filled ? Theme.xpGreen : Color(.sRGB, white: 0.12, opacity: 1))
                    .overlay(alignment: .top) {
                        Rectangle().fill(.white.opacity(index < filled ? 0.35 : 0.05)).frame(height: 1)
                    }
            }
        }
        .padding(1)
        .background(Rectangle().fill(.black))
        .shadow(color: filled > 0 ? Theme.xpGreen.opacity(0.6) : .clear, radius: 2)
        .help("\(ready) of \(total) sessions finished")
    }
}

/// Collapsed-bar badge in Block Craft style: a dark slot with shadowed XP lettering.
struct BlockBadge: View {
    let text: String
    var showsCheck = false

    var body: some View {
        HStack(spacing: 2) {
            if showsCheck { Text("✓").blockText(size: 9.5, color: Theme.xpGreen) }
            Text(text).blockText(size: 10, color: showsCheck ? Theme.xpGreen : .white)
        }
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(BevelSlot(selected: false, hovered: false))
    }
}

/// Fine stone texture for the island body: square pixels in noisy dark greys.
struct StoneTexture: View {
    var body: some View {
        Canvas { ctx, size in
            let px: CGFloat = 4
            for y in 0..<Int(ceil(size.height / px)) {
                for x in 0..<Int(ceil(size.width / px)) {
                    let white = [0.13, 0.15, 0.17, 0.19, 0.16][Theme.pixelNoise(x, y, 3) % 5]
                    ctx.fill(Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px, height: px)),
                             with: .color(Color(.sRGB, white: white, opacity: 1)))
                }
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}
