import NexlineCore
import SwiftUI

/// The agents: tap one to chat, tap its mic for live voice. Home Assistant and Settings at the bottom.
struct HomeView: View {
    @EnvironmentObject private var talk: TalkModel
    @EnvironmentObject private var router: Router
    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var audio = InlineAudio.shared
    @State private var shown = false

    var body: some View {
        ZStack {
            AmbientBackground(accent: Theme.teal)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    NowPlayingBar().padding(.horizontal, -12)
                    ForEach(Array(Bot.allCases.enumerated()), id: \.element) { index, bot in
                        BotCard(bot: bot, preview: preview(bot)) {
                            router.path.append(.chat(bot))
                        } onVoice: {
                            router.voice = bot
                        }
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : 24)
                        .animation(.spring(response: 0.55, dampingFraction: 0.82).delay(0.08 * Double(index)), value: shown)
                    }
                    Text("Tap an agent to chat · tap the mic for live voice")
                        .font(.footnote)
                        .foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .animation(.snappy, value: audio.url)
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { footer }
        .onAppear { shown = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NEXLINE")
                .font(.system(size: 32, weight: .heavy))
                .tracking(7)
                .foregroundStyle(LinearGradient(colors: [Theme.teal, Theme.teal.opacity(0.65)],
                                                startPoint: .leading, endPoint: .trailing))
            Text("VOICE AGENTS")
                .font(.system(size: 11, weight: .medium))
                .tracking(4)
                .foregroundStyle(Theme.muted)
            HStack(spacing: 6) {
                Circle()
                    .fill(talk.keysSet ? Theme.teal : Theme.coral)
                    .frame(width: 6, height: 6)
                Text(talk.keysSet ? "nexa · synced with the kiosk" : "nexa · add her token in settings")
                    .metaStyle(10, color: Theme.muted)
            }
            .padding(.top, 6)
        }
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    router.path.append(.devices)
                } label: {
                    Label("Home", systemImage: "house.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.teal)
                .glassEffect(Glass.regular.interactive(), in: Capsule())
                Button {
                    router.settings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.muted)
                .glassEffect(Glass.regular.interactive(), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    /// The last message, one line, without markup.
    private func preview(_ bot: Bot) -> String {
        guard let last = store.lines(bot).last(where: { !$0.text.isEmpty }) else { return bot.tagline }
        let text = last.text
            .components(separatedBy: "\n")
            .filter { AppLink.parse($0) == nil }
            .joined(separator: " ")
            .replacingOccurrences(of: "[*_`#>]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if last.failed { return "couldn't reach \(bot.name)" }
        return (last.fromUser ? "You: " : "") + (text.isEmpty ? (last.imageFile != nil ? "a photo" : "…") : text)
    }
}

private struct BotCard: View {
    let bot: Bot
    let preview: String
    let onOpen: () -> Void
    let onVoice: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Avatar(bot: bot, size: 58)
            VStack(alignment: .leading, spacing: 4) {
                Text(bot.name)
                    .font(.system(size: 18, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(bot.accent)
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(action: onVoice) {
                Image(systemName: "waveform")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(bot.accent)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .glassEffect(Glass.regular.tint(bot.accent.opacity(0.22)).interactive(), in: Circle())
            .accessibilityLabel("Voice with \(bot.name)")
        }
        .padding(14)
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onTapGesture(perform: onOpen)
        .glassCard(tint: bot.accent, cornerRadius: 22, interactive: true)
    }
}
