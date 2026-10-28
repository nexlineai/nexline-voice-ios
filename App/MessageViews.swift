import NexlineCore
import SwiftUI
import UIKit

/// One message, RN-style: a mono meta line, then a bubble with a coloured rail on the speaker's side (teal for
/// the user, the bot's colour for her). Her replies are split into blocks: text, code, pictures, players, cards.
struct MessageBubble: View {
    let line: TalkModel.Line
    let bot: Bot
    /// She is still working on this reply.
    var pending = false
    var onRetry: (() -> Void)?

    var body: some View {
        if line.failed {
            FailedRow(text: line.text, onRetry: onRetry)
        } else if line.fromUser {
            HStack {
                Spacer(minLength: 52)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(meta("you")).metaStyle()
                    VStack(alignment: .trailing, spacing: 6) {
                        if let file = line.imageFile {
                            ChatImage(source: .local(ChatStore.shared.photoURL(file)))
                        }
                        if !line.text.isEmpty {
                            Text(RichText.inline(line.text))
                                .font(.body)
                                .foregroundStyle(Theme.text)
                                .tint(Theme.teal)
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .bubble(rail: Theme.teal, fill: Theme.teal.opacity(0.12), railOnLeading: false)
                    .copyMenu(line.text)
                }
            }
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                Avatar(bot: bot, size: 30, ring: 1.5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(meta(bot.name)).metaStyle()
                    Group {
                        if line.text.isEmpty {
                            TypingDots(color: bot.accent)
                        } else {
                            RichBody(text: line.text)
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .bubble(rail: bot.accent, fill: Color.white.opacity(0.055), railOnLeading: true)
                    .copyMenu(line.text)
                    if pending && !line.text.isEmpty {
                        Circle().fill(bot.accent).frame(width: 5, height: 5)
                            .phaseAnimator([0.3, 1]) { dot, phase in dot.opacity(phase) }
                    }
                }
                Spacer(minLength: 24)
            }
        }
    }

    private func meta(_ who: String) -> String {
        var text = who
        if let time = line.time { text += " · \(time.formatted(date: .omitted, time: .shortened))" }
        if line.text.contains(ReplyBlocks.cutMarker) { text += " · cut off" }
        return text
    }
}

private extension View {
    func bubble(rail: Color, fill: Color, railOnLeading: Bool) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: railOnLeading ? 4 : 16, bottomLeadingRadius: railOnLeading ? 4 : 16,
            bottomTrailingRadius: railOnLeading ? 16 : 4, topTrailingRadius: railOnLeading ? 16 : 4,
            style: .continuous)
        return background(fill, in: shape)
            .overlay(alignment: railOnLeading ? .leading : .trailing) {
                Rectangle().fill(rail).frame(width: 2)
            }
            .overlay(shape.stroke(Theme.glassEdge, lineWidth: 0.5))
            .clipShape(shape)
    }

    func copyMenu(_ text: String) -> some View {
        contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
            ShareLink(item: text)
        }
    }
}

private struct FailedRow: View {
    let text: String
    let onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(Theme.coral)
                .multilineTextAlignment(.center)
            if let onRetry {
                Button("Retry", action: onRetry)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

/// Three dots bouncing in turn while she thinks.
struct TypingDots: View {
    var color: Color = Theme.muted

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = sin((t * 2 * .pi / 0.7) - Double(i) * 1.2)
                    Circle()
                        .fill(color.opacity(0.55 + 0.45 * max(0, phase)))
                        .frame(width: 7, height: 7)
                        .offset(y: -4 * max(0, phase))
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: Rich text

enum RichText {
    private static let bareURL = try! NSRegularExpression(
        pattern: "(?<![(<\\[])\\bhttps?://[^\\s<>()\\[\\]]*[^\\s<>()\\[\\].,;:!?'\"]")

    /// Bold, italics, inline code, links, and bare URLs made tappable. Anything else stays as written.
    static func inline(_ text: String) -> AttributedString {
        let linked = bareURL.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "<$0>")
        var result = (try? AttributedString(
            markdown: linked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        // Explicit SwiftUI keys: with UIKit imported too, `.font` and `.foregroundColor` are ambiguous.
        var code = AttributeContainer()
        code[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = Font.system(.callout, design: .monospaced)
        code[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Theme.gold
        code[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Theme.bg0
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].mergeAttributes(code)
        }
        return result
    }
}

/// Her reply as blocks (the RN `RichBody`): text lines with headings, lists and quotes; code with a copy
/// button; pictures; the mix player; media, radio and app cards; cameras and devices.
struct RichBody: View {
    let text: String
    var centered = false

    var body: some View {
        let blocks = ReplyBlocks.parse(text)
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block, centered: centered)
            }
        }
    }
}

private struct BlockView: View {
    let block: ReplyBlock
    let centered: Bool

    var body: some View {
        switch block {
        case .line(let text):
            LineView(text: text, centered: centered)
        case .code(let lang, let code):
            CodeBlock(lang: lang, code: code)
        case .image(let url):
            ChatImage(source: .remote(url))
        case .media(_, .radio):
            RadioCard()
        case .media(let url, let kind):
            if MediaKind.playsInline(url.absoluteString, kind) && TalkModel.keysCached {
                AudioCard(url: url, kind: kind)
            } else {
                CardButton(icon: Self.icon(kind), title: kind.label, subtitle: Self.shortLink(url)) {
                    AppLauncher.open(url)
                }
            }
        case .open(let link):
            CardButton(icon: "arrow.up.forward.app", title: "Open \(link.label)", subtitle: link.query) {
                AppLauncher.open(link)
            }
        case .camera(let entityID):
            CameraFrame(entityID: entityID)
        case .haDevice(let entityID):
            HADeviceCard(entityID: entityID)
        }
    }

    static func icon(_ kind: MediaKind) -> String {
        switch kind {
        case .youtube: return "play.rectangle.fill"
        case .soundcloud: return "waveform"
        case .mixcloud: return "dot.radiowaves.left.and.right"
        case .spotify: return "music.note"
        case .video: return "film"
        case .audio: return "play.circle"
        case .radio: return "radio"
        }
    }

    static func shortLink(_ url: URL) -> String {
        let text = ((url.host ?? "") + url.path).replacingOccurrences(of: "www.", with: "")
        return text.count > 44 ? String(text.prefix(44)) + "…" : text
    }
}

private struct LineView: View {
    let text: String
    let centered: Bool

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Color.clear.frame(height: 4)
        } else if let heading = Self.heading(trimmed) {
            Text(RichText.inline(heading.text))
                .font(Self.font(heading.level))
                .foregroundStyle(Theme.text)
                .padding(.top, 2)
        } else if let item = Self.listItem(trimmed) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.marker).foregroundStyle(Theme.muted).font(.callout.monospacedDigit())
                paragraph(item.text)
            }
        } else if trimmed.hasPrefix("> ") {
            paragraph(String(trimmed.dropFirst(2)))
                .italic()
                .opacity(0.85)
                .padding(.leading, 9)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.muted).frame(width: 2) }
        } else {
            paragraph(text)
        }
    }

    private static func font(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.bold()
        case 2: return .headline
        default: return .subheadline.bold()
        }
    }

    private func paragraph(_ content: String) -> some View {
        Text(RichText.inline(content))
            .font(centered ? .title3 : .body)
            .foregroundStyle(Theme.text)
            .tint(Theme.teal)
            .lineSpacing(centered ? 4 : 2)
            .multilineTextAlignment(centered ? .center : .leading)
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        for level in (1...3).reversed() {
            let mark = String(repeating: "#", count: level) + " "
            if line.hasPrefix(mark) { return (level, String(line.dropFirst(mark.count))) }
        }
        return nil
    }

    private static func listItem(_ line: String) -> (marker: String, text: String)? {
        if let first = line.first, "-*•".contains(first), line.dropFirst().first == " " {
            return ("•", String(line.dropFirst(2)))
        }
        guard let dot = line.firstIndex(of: "."), dot > line.startIndex,
              line[..<dot].allSatisfy(\.isNumber), line[line.index(after: dot)...].first == " "
        else { return nil }
        return ("\(line[..<dot]).", String(line[line.index(dot, offsetBy: 2)...]))
    }
}

private struct CodeBlock: View {
    let lang: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "code" : lang).metaStyle(10, color: Theme.muted)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        copied = false
                    }
                } label: {
                    Label(copied ? "copied" : "copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.teal)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.success, trigger: copied) { _, now in now }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider().overlay(Theme.border)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xC8E6E4))
                    .padding(10)
                    .textSelection(.enabled)
            }
        }
        .background(Color(hex: 0x04040A), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }
}

/// A tappable card: icon, title, one line under it.
struct CardButton: View {
    let icon: String
    let title: String
    var subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(Theme.teal)
                    .frame(width: 34, height: 34)
                    .background(Theme.bg3, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Theme.muted)
            }
            .padding(10)
            .frame(minWidth: 220)
            .glassCard(cornerRadius: 14, interactive: true)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Pictures

/// Pictures stay in memory, so the history refresh every few seconds doesn't load them again.
@MainActor
private enum ImageCache {
    static let shared = NSCache<NSURL, UIImage>()
}

/// A picture in a message: one she sent (Nexa's own sit behind Cloudflare Access; NexaClient adds the token for
/// those only) or a photo the user attached. Tap for full screen with pinch to zoom.
struct ChatImage: View {
    enum Source: Equatable {
        case remote(URL)
        case local(URL)

        var url: URL {
            switch self {
            case .remote(let url), .local(let url): return url
            }
        }

        var remoteURL: URL? {
            if case .remote(let url) = self { return url }
            return nil
        }
    }

    let source: Source
    @State private var image: UIImage?
    @State private var failed = false
    @State private var fullScreen = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 230, height: min(230, 230 * image.size.height / max(image.size.width, 1)))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { fullScreen = true }
            } else if failed {
                if case .remote(let url) = source {
                    Link(url.absoluteString, destination: url).font(.footnote).tint(Theme.teal)
                } else {
                    Label("photo missing", systemImage: "photo").font(.footnote).foregroundStyle(Theme.muted)
                }
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.bg3)
                    .frame(width: 230, height: 160)
                    .overlay(ProgressView().tint(Theme.teal))
            }
        }
        .task(id: source) { await load() }
        .fullScreenCover(isPresented: $fullScreen) {
            if let image { Lightbox(image: image, link: source.remoteURL) }
        }
    }

    private func load() async {
        let key = source.url as NSURL
        if let cached = ImageCache.shared.object(forKey: key) {
            image = cached
            return
        }
        do {
            let data: Data
            switch source {
            case .remote(let url): data = try await NexaClient.shared.imageData(url)
            case .local(let url): data = try Data(contentsOf: url)
            }
            guard let loaded = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
            ImageCache.shared.setObject(loaded, forKey: key)
            image = loaded
        } catch {
            failed = true
        }
    }
}

/// Full screen picture: pinch or double-tap to zoom, drag when zoomed, share, open in the browser.
private struct Lightbox: View {
    let image: UIImage
    let link: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.opacity(0.96).ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(zoom)
                .offset(offset)
                .gesture(MagnifyGesture()
                    .onChanged { zoom = max(1, min(5, settledZoom * $0.magnification)) }
                    .onEnded { _ in
                        settledZoom = zoom
                        if zoom <= 1.05 { reset() }
                    })
                .simultaneousGesture(DragGesture()
                    .onChanged { value in
                        guard zoom > 1 else { return }
                        offset = CGSize(width: settledOffset.width + value.translation.width,
                                        height: settledOffset.height + value.translation.height)
                    }
                    .onEnded { value in
                        if zoom > 1 {
                            settledOffset = offset
                        } else if value.translation.height > 120 {
                            dismiss()
                        }
                    })
                .onTapGesture(count: 2) {
                    withAnimation(.spring) {
                        if zoom > 1 { reset() } else { zoom = 2.5; settledZoom = 2.5 }
                    }
                }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 12) {
                ShareLink(item: Image(uiImage: image), preview: SharePreview("Picture", image: Image(uiImage: image))) {
                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                }
                if let link {
                    Button { AppLauncher.open(link) } label: {
                        Image(systemName: "safari").frame(width: 44, height: 44)
                    }
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .buttonStyle(.glass)
            .padding(16)
        }
    }

    private func reset() {
        zoom = 1
        settledZoom = 1
        offset = .zero
        settledOffset = .zero
    }
}

// MARK: Radio

/// Grooveline Radio, live: what's on air (Icecast status) and a play button. It plays in the app (`InlineAudio`);
/// if the iPhone can't play the stream, a tap opens the site in Chrome instead. Port of the RN app's RadioCard.
struct RadioCard: View {
    @ObservedObject private var audio = InlineAudio.shared
    @State private var nowPlaying: String?
    @State private var listeners: Int?

    private static let status = URL(string: "https://radio.grooveline.org/status-json.xsl")!

    private var state: InlineAudio.State { audio.state(for: InlineAudio.radioStream) }

    private var line: String {
        switch state {
        case .playing: return nowPlaying ?? "playing"
        case .loading, .warming: return "connecting…"
        case .failed: return "tap to listen in Chrome"
        case .idle, .paused: return nowPlaying ?? "tap to listen"
        }
    }

    var body: some View {
        Button {
            switch state {
            case .failed:
                if let chrome = AppLink(key: "chrome", query: "https://grooveline.org") { AppLauncher.open(chrome) }
            case .playing:
                audio.pause()
            case .loading, .warming:
                break
            case .idle, .paused:
                audio.play(url: InlineAudio.radioStream, kind: .radio)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundStyle(Theme.coral)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .frame(width: 42, height: 42)
                    .background(Theme.coral.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Grooveline Radio").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        Text("LIVE").font(Theme.mono(9, weight: .bold)).foregroundStyle(Theme.coral)
                    }
                    Text(line)
                        .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    if let listeners {
                        Text("\(listeners) listening").font(Theme.mono(10)).foregroundStyle(Theme.faint)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: state == .failed ? "arrow.up.right"
                      : state == .playing ? "pause.fill" : "play.fill")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            .padding(12)
            .frame(minWidth: 230)
            .glassCard(tint: Theme.coral, cornerRadius: 16, interactive: true)
        }
        .buttonStyle(.plain)
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func refresh() async {
        guard let mount = await Self.mount() else { return }
        nowPlaying = Self.text(mount)
        listeners = mount["listeners"] as? Int
    }

    /// What's on air now, for the lock screen too.
    static func currentTitle() async -> String? {
        await mount().flatMap(text)
    }

    private static func mount() async -> [String: Any]? {
        guard let result = try? await URLSession.shared.data(from: status),
              let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let stats = json["icestats"] as? [String: Any]
        else { return nil }
        let sources = (stats["source"] as? [[String: Any]]) ?? ((stats["source"] as? [String: Any]).map { [$0] } ?? [])
        return sources.first(where: { ($0["listenurl"] as? String ?? "").contains("/auto") }) ?? sources.first
    }

    private static func text(_ mount: [String: Any]) -> String? {
        let artist = mount["artist"] as? String ?? ""
        let title = mount["title"] as? String ?? ""
        let text = !artist.isEmpty && !title.isEmpty ? "\(artist) – \(title)" : (title.isEmpty ? artist : title)
        return text.isEmpty ? nil : text
    }
}
