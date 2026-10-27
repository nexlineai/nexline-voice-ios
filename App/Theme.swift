import SwiftUI

/// The Nexline look, carried over from the RN app's theme (palette of the Grooveline site): near-black
/// background, neon teal accent, one accent colour per bot, mono meta lines. Surfaces are iOS 26 Liquid Glass
/// instead of the RN app's flat translucent fills.
enum Theme {
    static let teal = Color(hex: 0x00D4C8)
    static let coral = Color(hex: 0xFF5E6C)
    static let gold = Color(hex: 0xF0C040)
    static let bg0 = Color(hex: 0x050508)
    static let bg1 = Color(hex: 0x080810)
    static let bg2 = Color(hex: 0x0D0D18)
    static let bg3 = Color(hex: 0x111120)
    static let text = Color(hex: 0xE2E8F8)
    static let muted = Color(red: 200 / 255, green: 210 / 255, blue: 240 / 255).opacity(0.6)
    static let faint = Color(red: 200 / 255, green: 210 / 255, blue: 240 / 255).opacity(0.35)
    static let border = teal.opacity(0.14)
    static let borderStrong = teal.opacity(0.35)
    static let danger = Color(hex: 0xFF3B30)
    static let glassEdge = Color.white.opacity(0.09)

    /// Meta lines, tool traces and state readouts.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    /// A Liquid Glass surface, lightly tinted.
    func glassCard(tint: Color? = nil, cornerRadius: CGFloat = 20, interactive: Bool = false) -> some View {
        glassEffect(Glass.regular.tint(tint?.opacity(0.18)).interactive(interactive),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Mono, spaced-out caps, like the RN app's meta lines.
    func metaStyle(_ size: CGFloat = 9, color: Color = Theme.faint) -> some View {
        font(Theme.mono(size)).tracking(1.1).textCase(.uppercase).foregroundStyle(color)
    }
}

/// Light from the bot's colour at the top and Nexline teal from below, drifting slowly. The RN app faked this
/// with two blurred discs; here it is a real mesh gradient.
struct AmbientBackground: View {
    let accent: Color
    var intensity: Double = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = Float(timeline.date.timeIntervalSinceReferenceDate)
            let top = Theme.bg1.mix(with: accent, by: 0.30 * intensity)
            let topSide = Theme.bg1.mix(with: accent, by: 0.10 * intensity)
            let middle = Theme.bg0.mix(with: accent, by: 0.05 * intensity)
            let bottom = Theme.bg0.mix(with: Theme.teal, by: 0.16 * intensity)
            MeshGradient(
                width: 3, height: 3,
                points: Self.points(t),
                colors: [
                    topSide, top, topSide,
                    Theme.bg0, middle, Theme.bg0,
                    Theme.bg0, bottom, Theme.bg0,
                ],
                background: Theme.bg0,
                smoothsColors: true,
                colorSpace: .perceptual)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// The inner points wander a little; the edges stay put so the screen is always covered.
    private static func points(_ t: Float) -> [SIMD2<Float>] {
        let topX: Float = 0.5 + 0.08 * sin(t * 0.21)
        let leftY: Float = 0.45 + 0.06 * sin(t * 0.17)
        let midX: Float = 0.5 + 0.10 * cos(t * 0.13)
        let midY: Float = 0.5 + 0.08 * sin(t * 0.19)
        let rightY: Float = 0.55 + 0.06 * cos(t * 0.23)
        let bottomX: Float = 0.5 + 0.08 * cos(t * 0.15)
        return [
            SIMD2<Float>(0, 0), SIMD2<Float>(topX, 0), SIMD2<Float>(1, 0),
            SIMD2<Float>(0, leftY), SIMD2<Float>(midX, midY), SIMD2<Float>(1, rightY),
            SIMD2<Float>(0, 1), SIMD2<Float>(bottomX, 1), SIMD2<Float>(1, 1),
        ]
    }
}

/// A bot's round avatar with its accent ring.
struct Avatar: View {
    let bot: Bot
    var size: CGFloat = 56
    var ring: CGFloat = 2

    var body: some View {
        Image(bot.avatar)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(bot.accent, lineWidth: ring))
            .shadow(color: bot.accent.opacity(0.35), radius: size / 8)
    }
}
