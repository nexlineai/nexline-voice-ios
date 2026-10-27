import NexlineCore
import SwiftUI
import UIKit

/// Full-screen voice (the RN voice screen): her orb in a halo of particles that moves with her real voice
/// while she speaks and with yours while she listens, what she says, and mute, standby and end.
struct VoiceModeView: View {
    let bot: Bot
    @EnvironmentObject private var talk: TalkModel
    @EnvironmentObject private var router: Router
    @State private var debug = false
    @State private var showLog = false
    /// Lines already there when voice mode opened: only what is said from now on is shown.
    @State private var startCount: Int?

    var body: some View {
        ZStack {
            AmbientBackground(accent: bot.accent, intensity: 1.4)
            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text(bot.name)
                        .font(.system(size: 26, weight: .heavy))
                        .tracking(2)
                        .foregroundStyle(bot.accent)
                    Text(bot.tagline).metaStyle(10, color: Theme.muted)
                }
                .padding(.top, 18)

                Spacer(minLength: 8)
                Button(action: talk.hush) {
                    AuraOrb(bot: bot, phase: talk.phase, quiet: talk.muted || talk.pausedForMusic, levels: talk.levels)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop her talking")

                VStack(spacing: 10) {
                    Text(stateLabel)
                        .font(Theme.mono(10))
                        .tracking(2.2)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: stateLabel)
                        .onTapGesture { withAnimation { debug.toggle() } }
                    if debug {
                        HStack(spacing: 12) {
                            Text(talk.lastTiming ?? "no turn yet").font(Theme.mono(10)).foregroundStyle(bot.accent)
                            Button("log") { showLog = true }.font(Theme.mono(10, weight: .bold))
                        }
                    }
                }
                .padding(.top, 22)
                Spacer(minLength: 8)

                transcript
                    .frame(maxHeight: 280)
                    .padding(.horizontal, 24)

                controls
                    .padding(.top, 16)
                    .padding(.bottom, 12)
            }
        }
        .statusBarHidden(false)
        .task {
            await talk.select(bot)
            startCount = talk.lines.count
            if talk.phase == .off && !talk.pausedForMusic {
                await talk.startVoice(standby: Prefs.bool(Prefs.standby, default: false))
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sensoryFeedback(trigger: talk.phase) { old, new in
            switch (old, new) {
            case (_, .thinking): return .impact(weight: .light, intensity: 0.6)
            case (.thinking, .speaking): return .impact(weight: .medium, intensity: 0.5)
            case (.speaking, .listening): return .selection
            default: return nil
            }
        }
        .sheet(isPresented: $showLog) { LogView().environmentObject(talk) }
    }

    private var stateLabel: String {
        if talk.pausedForMusic { return "MUSIC · VOICE IS PAUSED" }
        if talk.muted { return "MUTED" }
        switch talk.phase {
        case .off: return "CONNECTING…"
        case .starting: return "STARTING…"
        case .listening:
            return talk.standby && !talk.awake ? "STANDBY · SAY “\(bot.name.uppercased())…”" : "LISTENING"
        case .thinking: return "THINKING…"
        case .speaking: return "SPEAKING · TALK TO INTERRUPT"
        }
    }

    // MARK: What is being said

    private var newLines: [TalkModel.Line] {
        guard talk.bot == bot, let startCount, talk.lines.count > startCount else { return [] }
        return Array(talk.lines.suffix(from: min(startCount, talk.lines.count)))
    }

    @ViewBuilder private var transcript: some View {
        let recent = newLines
        let reply = recent.last.flatMap { $0.fromUser ? nil : $0 }
        let question = recent.last(where: { $0.fromUser })
        VStack(spacing: 12) {
            if let reply, reply.failed {
                Text(reply.text).font(.footnote).foregroundStyle(Theme.coral).multilineTextAlignment(.center)
            } else if let reply, !reply.text.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 10) {
                            RichBody(text: reply.text, centered: true)
                            Color.clear.frame(height: 1).id("end")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollIndicators(.hidden)
                    .onChange(of: reply.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            } else if let question {
                Text("“\(question.text)”")
                    .font(.body.italic())
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            } else {
                Text(talk.standby && !talk.awake ? "Say “\(bot.name)” to wake her" : "Just start talking")
                    .font(.body)
                    .foregroundStyle(Theme.faint)
            }
            Group {
                if !talk.hearing.isEmpty {
                    Text("“\(talk.hearing)”")
                        .font(.body.italic())
                        .foregroundStyle(bot.accent)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .glassEffect(Glass.regular.tint(bot.accent.opacity(0.12)),
                                     in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                } else {
                    Color.clear.frame(height: 40)
                }
            }
            .animation(.snappy, value: talk.hearing.isEmpty)
        }
    }

    // MARK: Buttons

    private var controls: some View {
        GlassEffectContainer(spacing: 28) {
            HStack(spacing: 28) {
                RoundButton(symbol: talk.muted ? "mic.slash.fill" : "mic.fill",
                            tint: talk.muted ? Theme.danger : nil, label: talk.muted ? "Unmute" : "Mute") {
                    talk.muted.toggle()
                }
                RoundButton(symbol: talk.standby ? "moon.fill" : "moon", tint: talk.standby ? bot.accent : nil,
                            label: talk.standby ? "Standby off" : "Standby") {
                    talk.setStandby(!talk.standby)
                }
                RoundButton(symbol: "xmark", tint: Theme.danger, label: "End") {
                    router.voice = nil
                    Task { await talk.endVoice() }
                }
            }
        }
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.7), trigger: talk.muted)
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.7), trigger: talk.standby)
    }
}

private struct RoundButton: View {
    let symbol: String
    let tint: Color?
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 66, height: 66)
        }
        .buttonStyle(.plain)
        .glassEffect(Glass.regular.tint(tint?.opacity(0.85)).interactive(), in: Circle())
        .accessibilityLabel(label)
    }
}

// MARK: The orb

/// Smooths the orb's inputs between frames, so state changes and levels glide instead of jumping (the RN halo
/// restarted its loop on every state change; here the orbit keeps its place and only its speed changes).
private final class AuraMotion {
    var gain = 0.15
    var level = 0.0
    var speed = 1.0 / 26
    var clock = 0.0
    var thinking = 0.0
    private var last: Double?

    func step(_ phase: TalkModel.Phase, quiet: Bool, speech: Float, mic: Float, at t: Double) {
        let dt = min(0.05, max(0, t - (last ?? t)))
        last = t
        let target: Double
        let pace: Double
        switch quiet ? .off : phase {
        case .off, .starting: target = 0.15; pace = 1.0 / 26
        case .listening: target = 0.45; pace = 1.0 / 20
        case .thinking: target = 0.9; pace = 1.0 / 6
        case .speaking: target = 0.75; pace = 1.0 / 14
        }
        gain += (target - gain) * min(1, dt * 4)
        speed += (pace - speed) * min(1, dt * 3)
        clock += dt * speed
        let input: Double
        if quiet { input = 0 } else if phase == .speaking { input = Double(speech) } else if phase == .listening {
            input = Double(mic) * 0.8
        } else { input = 0 }
        level += (input - level) * min(1, dt * (input > level ? 22 : 7))
        thinking += ((phase == .thinking && !quiet ? 1 : 0) - thinking) * min(1, dt * 4)
    }
}

private struct Particle {
    let phase: Double
    let direction: Double
    let speed: Double
    let radius: Double
    let size: Double
    let alpha: Double
    let wobble: Double

    /// The same halo every time (seeded like the RN app's).
    static let all: [Particle] = {
        var seed: Int64 = 7
        func random() -> Double {
            seed = (seed * 16807) % 2147483647
            return Double(seed - 1) / 2147483646
        }
        let count = 26
        return (0..<count).map { i in
            Particle(phase: Double(i) / Double(count) * 2 * .pi + random() * 0.5,
                     direction: i % 3 == 0 ? -1 : 1,
                     speed: 0.6 + random() * 1.1,
                     radius: 0.78 + random() * 0.42,
                     size: 2.5 + (random() * 5).rounded(.down),
                     alpha: 0.45 + random() * 0.5,
                     wobble: 0.04 + random() * 0.08)
        }
    }()
}

struct AuraOrb: View {
    let bot: Bot
    let phase: TalkModel.Phase
    let quiet: Bool
    let levels: VoiceLevels
    @State private var motion = AuraMotion()

    private let orb: CGFloat = 196

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let _ = motion.step(phase, quiet: quiet,
                                speech: levels.speech(at: ProcessInfo.processInfo.systemUptime),
                                mic: levels.mic, at: t)
            let gain = motion.gain
            let level = motion.level
            VStack(spacing: 30) {
                ZStack {
                    Canvas { context, size in
                        drawHalo(&context, size: size, t: t, gain: gain, level: level)
                    }
                    .frame(width: orb * 2.1, height: orb * 2.1)

                    Circle()
                        .fill(bot.accent)
                        .frame(width: orb, height: orb)
                        .blur(radius: 38)
                        .opacity(0.2 + gain * 0.35 + level * 0.35)
                        .scaleEffect(1.05 + gain * 0.15 + level * 0.25)

                    Image(bot.avatar)
                        .resizable()
                        .scaledToFill()
                        .frame(width: orb, height: orb)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(bot.accent, lineWidth: 3))
                        .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1).padding(3))
                        .scaleEffect(pulse(t: t, level: level))
                        .shadow(color: bot.accent.opacity(0.5), radius: 18)
                }
                .frame(width: orb * 2.1, height: orb * 1.7)

                Canvas { context, size in
                    drawBars(&context, size: size, t: t, level: level)
                }
                .frame(width: 120, height: 30)
            }
        }
    }

    private func pulse(t: Double, level: Double) -> CGFloat {
        if quiet { return 1 }
        switch phase {
        case .listening: return 1 + 0.025 * sin(t * 2 * .pi / 3.2) + level * 0.04
        case .thinking: return 0.975 + 0.02 * sin(t * 2 * .pi / 1.0)
        case .speaking: return 1 + level * 0.085
        default: return 1
        }
    }

    private func drawHalo(_ context: inout GraphicsContext, size: CGSize, t: Double, gain: Double, level: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let halo = Double(orb) * 0.64
        let color = bot.accent

        // Two breathing rings.
        for (factor, base, swell) in [(1.3, 0.12, 0.18), (1.66, 0.06, 0.3)] {
            let radius = Double(orb) / 2 * factor * (1 + level * swell + (gain - 0.15) * 0.05)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let opacity = base + (gain - 0.15) / 0.75 * base * 2.4 + level * 0.25
            context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(min(0.8, opacity))), lineWidth: 1.5)
        }

        // While she thinks: a bright arc sweeping around the orb.
        if motion.thinking > 0.02 {
            let radius = Double(orb) / 2 + 14
            let start = Angle(radians: t * 2.6)
            let end = Angle(radians: t * 2.6 + 110 * .pi / 180)
            var arc = Path()
            arc.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
            context.stroke(arc, with: .conicGradient(Gradient(colors: [color.opacity(0), color, .white]),
                                                     center: center, angle: start),
                           style: StrokeStyle(lineWidth: 2.5 * motion.thinking, lineCap: .round))
        }

        // The particles: a soft glow layer, then the bright cores.
        let positions = Particle.all.map { p -> (CGPoint, Double, Double) in
            let angle = p.phase + motion.clock * 2 * .pi * p.speed * p.direction
            let swell = 1 + level * 0.5 + sin(t * 1.4 + p.phase * 5) * p.wobble
            let r = halo * p.radius * swell
            let scale = 0.55 + gain * 0.7 + level * 0.7
            return (CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r),
                    p.size * scale, p.alpha * (0.25 + gain * 0.75))
        }
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 5))
            for (point, size, alpha) in positions {
                let d = size * 2.6
                glow.fill(Path(ellipseIn: CGRect(x: point.x - d / 2, y: point.y - d / 2, width: d, height: d)),
                          with: .color(color.opacity(alpha * 0.7)))
            }
        }
        for (point, size, alpha) in positions {
            context.fill(Path(ellipseIn: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)),
                         with: .color(color.opacity(alpha)))
        }
    }

    /// Thirteen bars under the orb: they breathe when idle and ride the voice level when someone talks.
    private func drawBars(_ context: inout GraphicsContext, size: CGSize, t: Double, level: Double) {
        let count = 13
        let width = 3.0
        let gap = 4.0
        let total = Double(count) * width + Double(count - 1) * gap
        let startX = (Double(size.width) - total) / 2
        let active = quiet ? 0.2 : (phase == .speaking || phase == .listening ? 1.0 : 0.3)
        for i in 0..<count {
            let p = Double(i) / Double(count)
            let centerWeight = 1 - abs(Double(i) - Double(count - 1) / 2) / Double(count) * 0.9
            let idle = 4 + abs(sin(t * 2.2 + p * 7)) * 5
            let talking = 5 + level * 24 * centerWeight * (0.4 + abs(sin(t * 7 + p * 9)))
            let h = min(Double(size.height), idle + (talking - idle) * active)
            let rect = CGRect(x: startX + Double(i) * (width + gap), y: (Double(size.height) - h) / 2, width: width, height: h)
            context.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                         with: .color(bot.accent.opacity(0.35 + active * 0.5 + level * 0.15)))
        }
    }
}
