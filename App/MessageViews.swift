import NexlineCore
import SwiftUI
import UIKit

/// One message of the conversation. Nexa's replies are split into blocks like the RN app's MessageBubble:
/// text, code, pictures, media cards, app launches.
struct MessageRow: View {
    let line: TalkModel.Line

    var body: some View {
        if line.fromUser {
            HStack {
                Spacer(minLength: 48)
                Text(line.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nexa").font(.caption.bold()).foregroundStyle(Color.accentColor)
                if line.text.isEmpty {
                    ProgressView()
                } else {
                    ForEach(Array(ReplyBlocks.parse(line.text).enumerated()), id: \.offset) { _, block in
                        BlockView(block: block)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct BlockView: View {
    let block: ReplyBlock

    var body: some View {
        switch block {
        case .line(let text):
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                Color.clear.frame(height: 2)
            } else {
                Text(Self.markdown(text))
            }
        case .code(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.callout.monospaced()).padding(10)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        case .image(let url):
            ChatImage(url: url)
        case .media(_, .radio):
            RadioCard()
        case .media(let url, let kind):
            CardButton(icon: Self.icon(kind), title: kind.label, subtitle: Self.shortLink(url)) {
                AppLauncher.open(url)
            }
        case .open(let link):
            CardButton(icon: "arrow.up.forward.app", title: "Open \(link.label)", subtitle: link.query) {
                AppLauncher.open(link)
            }
        case .camera(let entityID):
            Label("Camera \(entityID): comes with the Home Assistant screen", systemImage: "video")
                .font(.footnote).foregroundStyle(.secondary)
        case .haDevice(let entityID):
            Label("\(entityID): comes with the Home Assistant screen", systemImage: "house")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// Bold, italics, inline code and links; anything else stays as written.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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
        ((url.host ?? "") + url.path).replacingOccurrences(of: "www.", with: "")
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
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.bold()).foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
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

/// A picture from a reply. Nexa's own pictures sit behind Cloudflare Access; NexaClient adds the token for
/// those only.
private struct ChatImage: View {
    let url: URL
    @State private var image: UIImage?
    @State private var failed = false
    @State private var fullScreen = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture { fullScreen = true }
            } else if failed {
                Label("The picture didn't load", systemImage: "photo")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                    .frame(height: 160)
                    .overlay(ProgressView())
            }
        }
        .task(id: url) { await load() }
        .fullScreenCover(isPresented: $fullScreen) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Button { fullScreen = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white)
                }
                .padding()
            }
        }
    }

    private func load() async {
        if let cached = ImageCache.shared.object(forKey: url as NSURL) {
            image = cached
            return
        }
        do {
            let data = try await NexaClient.shared.imageData(url)
            guard let loaded = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
            ImageCache.shared.setObject(loaded, forKey: url as NSURL)
            image = loaded
        } catch {
            failed = true
        }
    }
}

// MARK: Radio

/// Grooveline Radio, live. The stream is Ogg, which iOS can't play in-app but Chrome can, so the card shows
/// what's on air (Icecast status) and opens the site in Chrome. Port of the RN app's RadioCard.
struct RadioCard: View {
    @State private var nowPlaying: String?

    private static let status = URL(string: "https://radio.grooveline.org/status-json.xsl")!

    var body: some View {
        CardButton(icon: "radio", title: "Grooveline Radio · live",
                   subtitle: nowPlaying ?? "tap to listen in Chrome") {
            if let chrome = AppLink(key: "chrome", query: "https://grooveline.org") { AppLauncher.open(chrome) }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func refresh() async {
        guard let result = try? await URLSession.shared.data(from: Self.status),
              let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let stats = json["icestats"] as? [String: Any]
        else { return }
        let sources = (stats["source"] as? [[String: Any]]) ?? ((stats["source"] as? [String: Any]).map { [$0] } ?? [])
        guard let mount = sources.first(where: { ($0["listenurl"] as? String ?? "").contains("/auto") }) ?? sources.first
        else { return }
        let artist = mount["artist"] as? String ?? ""
        let title = mount["title"] as? String ?? ""
        var text = !artist.isEmpty && !title.isEmpty ? "\(artist) – \(title)" : (title.isEmpty ? artist : title)
        if let listeners = mount["listeners"] as? Int { text += " · \(listeners) listening" }
        nowPlaying = text.isEmpty ? nil : text
    }
}
