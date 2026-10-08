import SwiftUI
import IslandCore

/// Visual constants. Springs are tuned to read as "Apple": a snappy morph on expand with the
/// barest overshoot, a slightly faster collapse so dismissal feels crisp, and a content
/// cross-fade that lags the shape by a hair so content appears to grow out of the pill.
enum Theme {
    // Springs — deliberately slow and fully smooth (no overshoot, no snap). The expand glides the
    // height open; the launch reveal eases the bar out of the notch.
    static let expand   = Animation.spring(response: 0.6, dampingFraction: 1.0)
    // Open/close of the slim bar — unhurried emerge from the notch, and an even calmer retract.
    static let appear    = Animation.spring(response: 1.4, dampingFraction: 0.86)  // open (slow, graceful emerge)
    static let disappear = Animation.spring(response: 1.0, dampingFraction: 1.0)   // retract into notch, smooth, no bounce

    // The pill body — pure, flat black so it fuses seamlessly with the physical notch (no shadow,
    // no gradient: any second tone reads as "not the notch").
    //
    // To experiment with shades WITHOUT rebuilding, launch with the ISLAND_PILL env var:
    //   • a grayscale value 0.0–1.0   (e.g. ISLAND_PILL=0.06  → near-black)
    //   • or a hex string             (e.g. ISLAND_PILL=#0A0A0F)
    // To change the permanent default, edit the `.black` fallback below.
    static let pill: Color = {
        let env = ProcessInfo.processInfo.environment["ISLAND_PILL"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if env.hasPrefix("#"), let c = Color(hexString: env) { return c }
        if let w = Double(env), (0...1).contains(w) { return Color(.sRGB, white: w, opacity: 1) }
        return .black
    }()

    static let amber = Color(.sRGB, red: 0.96, green: 0.74, blue: 0.18, opacity: 1)
    // A calm green for finished ("completed") sessions — distinct from the working accent (blue)
    // and the attention amber, so a resting done session reads as done at a glance.
    static let green = Color(.sRGB, red: 0.36, green: 0.80, blue: 0.50, opacity: 1)
    // Slot-machine style: a casino cabinet. It stays pure black at the very top so it still fuses
    // with the hardware notch, then burns into deep red trimmed with gold.
    static let cabinet = Color(.sRGB, red: 0.42, green: 0.02, blue: 0.04, opacity: 1)
    static let cabinetDeep = Color(.sRGB, red: 0.16, green: 0.0, blue: 0.02, opacity: 1)
    static let gold = Color(.sRGB, red: 1.0, green: 0.80, blue: 0.22, opacity: 1)
    static let flame = Color(.sRGB, red: 1.0, green: 0.42, blue: 0.04, opacity: 1)
    static let knobGreen = Color(.sRGB, red: 0.30, green: 0.82, blue: 0.32, opacity: 1)
    /// Width reserved on each side of the expanded slot cabinet for the pull lever.
    static let leverWidth: CGFloat = 24

    // Pit-wall style: carbon fibre, timing-screen colors, and team liveries.
    static let carbon = Color(.sRGB, white: 0.075, opacity: 1)
    static let f1Red = Color(.sRGB, red: 0.91, green: 0.0, blue: 0.18, opacity: 1)
    static let f1Yellow = Color(.sRGB, red: 1.0, green: 0.84, blue: 0.0, opacity: 1)
    static let f1Green = Color(.sRGB, red: 0.16, green: 0.86, blue: 0.36, opacity: 1)
    static let f1Purple = Color(.sRGB, red: 0.70, green: 0.28, blue: 1.0, opacity: 1)
    static let f1Mint = Color(.sRGB, red: 0.15, green: 0.96, blue: 0.82, opacity: 1)
    static let sectorOff = Color(.sRGB, white: 0.22, opacity: 1)
    private static let teamColors: [Color] = [
        Color(.sRGB, red: 0.91, green: 0.0, blue: 0.18, opacity: 1),   // red
        Color(.sRGB, red: 0.15, green: 0.96, blue: 0.82, opacity: 1),  // teal
        Color(.sRGB, red: 0.21, green: 0.44, blue: 0.78, opacity: 1),  // blue
        Color(.sRGB, red: 1.0, green: 0.50, blue: 0.0, opacity: 1),    // papaya
        Color(.sRGB, red: 0.13, green: 0.60, blue: 0.44, opacity: 1),  // racing green
        Color(.sRGB, red: 1.0, green: 0.53, blue: 0.74, opacity: 1),   // pink
        Color(.sRGB, red: 0.39, green: 0.77, blue: 1.0, opacity: 1),   // sky blue
        Color(.sRGB, red: 0.71, green: 0.73, blue: 0.74, opacity: 1),  // silver
        Color(.sRGB, red: 0.32, green: 0.89, blue: 0.32, opacity: 1),  // lime
        Color(.sRGB, red: 0.40, green: 0.57, blue: 1.0, opacity: 1),   // light blue
    ]

    /// A stable livery per project (Swift's `hashValue` is randomized per launch).
    static func teamColor(for project: String) -> Color {
        let hash = project.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return teamColors[Int(hash % UInt32(teamColors.count))]
    }

    /// Timing-tower lettering: heavy, condensed, italic.
    static func raceFont(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy).width(.condensed).italic()
    }

    // Block Craft style: stone, grass, and classic 16-color UI text.
    static let mcGrass = Color(.sRGB, red: 0.36, green: 0.70, blue: 0.23, opacity: 1)
    static let xpGreen = Color(.sRGB, red: 0.50, green: 1.0, blue: 0.13, opacity: 1)
    static let mcYellow = Color(.sRGB, red: 1.0, green: 1.0, blue: 0.33, opacity: 1)
    static let mcAqua = Color(.sRGB, red: 0.33, green: 1.0, blue: 1.0, opacity: 1)
    static let mcGreen = Color(.sRGB, red: 0.33, green: 1.0, blue: 0.33, opacity: 1)
    static let mcRed = Color(.sRGB, red: 1.0, green: 0.33, blue: 0.33, opacity: 1)
    static let mcGray = Color(.sRGB, white: 0.67, opacity: 1)

    /// Deterministic per-pixel noise for the code-drawn block textures.
    static func pixelNoise(_ x: Int, _ y: Int, _ seed: Int) -> Int {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ seed &* 982_451_653)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Int(h ^ (h >> 16))
    }

    /// Polished gold: bright highlight, rich gold, dark bronze, gold again.
    static var goldGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(.sRGB, red: 1.0, green: 0.97, blue: 0.72, opacity: 1), location: 0),
                .init(color: gold, location: 0.35),
                .init(color: Color(.sRGB, red: 0.70, green: 0.40, blue: 0.04, opacity: 1), location: 0.7),
                .init(color: gold, location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
    }

    /// Flaming gold text: yellow core burning into orange.
    static var flameGradient: LinearGradient {
        LinearGradient(
            colors: [Color(.sRGB, red: 1.0, green: 0.96, blue: 0.55, opacity: 1), gold, flame],
            startPoint: .top, endPoint: .bottom)
    }

    // Pill geometry shared by the view and the window's interactive-zone math.
    static let wing: CGFloat = 56        // each side wing (glyph / timer) of the closed bar
    static let dropHeight: CGFloat = 54  // how much taller the expanded drop-down adds

    // ── Multi-session (the Stack) ─────────────────────────────────────────────
    // With 2+ live sessions the expanded drop-down becomes a session list instead of the
    // single-session layout. These knobs size it; with one session nothing here applies.
    static let sessionRowHeight: CGFloat = 28   // one session row in the expanded stack
    static let sessionRowSpacing: CGFloat = 2
    static let sessionRowsVisible = 10          // full rows shown at most; more sessions scroll
    /// Expanded drop-down height for `count` sessions (single session uses `dropHeight`).
    /// Past `sessionRowsVisible` the list scrolls: two thirds of the next row peek out and
    /// dissolve into a deep fog at the bottom edge — that fade is the whole scroll hint.
    /// Nothing is ever dropped.
    static func stackDropHeight(_ count: Int) -> CGFloat {
        let full = CGFloat(min(max(count, 1), sessionRowsVisible))
        if count > sessionRowsVisible {
            return 7 + full * (sessionRowHeight + sessionRowSpacing) + sessionRowHeight * 0.65
        }
        return 7 + full * sessionRowHeight + (full - 1) * sessionRowSpacing + 9
    }

    static func accent(_ provider: Provider) -> Color {
        let c = provider.accentRGB
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }
}

extension Color {
    /// Parse "#RRGGBB" (or "RRGGBB"). Returns nil if malformed.
    init?(hexString: String) {
        var s = hexString
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self = Color(.sRGB,
                     red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255,
                     opacity: 1)
    }
}

/// "0:43" / "1:05" / "12:30" — a compact, single-line media-style clock (with monospaced digits
/// it never reflows or wraps).
func elapsedString(_ seconds: Int) -> String {
    let s = max(0, seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
}
