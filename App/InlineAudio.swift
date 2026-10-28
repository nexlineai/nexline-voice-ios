import AVFoundation
import MediaPlayer
import NexlineCore
import SwiftUI

/// Mixcloud and SoundCloud mixes played inside the app, through serve.py's `/youtube/stream` cache proxy (the
/// kiosk's player). The first play of a mix makes the Jetson download it: the proxy answers 503 while it
/// warms, so the card says "preparing" and retries until the file is ready (then seeking is instant).
///
/// One mix plays at a time. Voice processing gates music to near silence, so voice stops while a mix plays and
/// starts again when it stops or is paused. Lock screen and Control Center show it and can pause it.
///
/// Grooveline Radio plays here too, straight from Icecast. The stream is Ogg Vorbis, which iOS plays since 18.4
/// (Safari 18.4 release notes; build 27 is the first test of AVPlayer with it). If the player can't, the card
/// falls back to Chrome and the log says why.
@MainActor
final class InlineAudio: ObservableObject {
    static let shared = InlineAudio()
    /// The one live stream every Grooveline Radio link means.
    static let radioStream = URL(string: "https://radio.grooveline.org/auto")!

    enum State: Equatable {
        case idle, warming, loading, playing, paused, failed
    }

    struct Meta: Equatable {
        var title: String
        var channel: String
        var art: URL?
        var duration: Double
    }

    /// The mix that owns playback (nil when nothing is loaded).
    @Published private(set) var url: URL?
    @Published private(set) var kind: MediaKind = .mixcloud
    @Published private(set) var state: State = .idle
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var meta: [URL: Meta] = [:]

    weak var talk: TalkModel?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var observers: [NSObjectProtocol] = []
    private var session = 0
    private var autoplayed: Set<URL> = []
    private var holdsVoice = false
    private var artwork: MPMediaItemArtwork?
    private var radioStartedAt: Date?

    private init() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self?.seek(seconds: time) }
            return .success
        }
    }

    func state(for url: URL) -> State { self.url == url ? state : .idle }

    // MARK: Playing

    /// `autoplay` starts a mix only the first time it arrives, never when history scrolls by again.
    func play(url: URL, kind: MediaKind, autoplay: Bool = false) {
        let url = kind == .radio ? Self.radioStream : url
        if autoplay {
            guard !autoplayed.contains(url) else { return }
            autoplayed.insert(url)
        }
        if self.url == url, player != nil {
            if state == .paused { resume() }
            return
        }
        teardown()
        self.url = url
        self.kind = kind
        state = .loading
        position = 0
        duration = meta[url]?.duration ?? 0
        loadMeta(url, kind)
        session += 1
        let mine = session
        Task { await self.start(url, mine) }
    }

    func toggle() {
        switch state {
        case .playing: pause()
        case .paused: resume()
        case .idle, .failed: if let url { play(url: url, kind: kind) }
        case .warming, .loading: break
        }
    }

    func pause() {
        guard state == .playing, let player else { return }
        // Live: pausing would resume stale audio later, so drop the connection and reconnect on play.
        if kind == .radio { teardown() } else { player.pause() }
        state = .paused
        updateNowPlaying()
        Task { await releaseVoice() }
    }

    func resume() {
        if kind == .radio, state == .paused, let url {
            play(url: url, kind: .radio)
            return
        }
        guard state == .paused, let player else { return }
        state = .playing
        Task {
            await holdVoice()
            activateSession()
            player.play()
            updateNowPlaying()
        }
    }

    /// She heard her name over the music: hold it while she answers. Voice owns the session now, and `resume()`
    /// brings the music back (voice goes back to listening for her name).
    func pauseForVoice() {
        guard state == .playing, let player else { return }
        if kind == .radio { teardown() } else { player.pause() }
        state = .paused
        holdsVoice = false
        updateNowPlaying()
    }

    /// Stops and forgets the mix, and gives voice back.
    func stop() {
        session += 1
        teardown()
        url = nil
        state = .idle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        Task { await releaseVoice() }
    }

    /// Voice is starting and owns the audio session now: drop the mix without deactivating the session or
    /// asking voice to come back (a deferred `stop()` would switch the new voice session off).
    func yieldToVoice() {
        session += 1
        teardown()
        url = nil
        state = .idle
        holdsVoice = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(fraction: Double) {
        guard duration > 0 else { return }
        seek(seconds: max(0, min(1, fraction)) * duration)
    }

    func seek(seconds: Double) {
        guard let player else { return }
        position = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        updateNowPlaying()
    }

    private func start(_ url: URL, _ mine: Int) async {
        await holdVoice()
        guard mine == session else { return }
        if kind == .radio {
            startRadio(url)
            return
        }
        let query = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "audio", value: "1")]
        // Ask before handing the URL to the player: a cache miss makes the Jetson download first, and AVPlayer
        // would report that as an opaque error. Monster mixes get the server's 15-minute download budget.
        let deadline = Date().addingTimeInterval(15 * 60)
        while mine == session {
            let code = await NexaClient.shared.status("youtube/stream", query: query, range: "bytes=0-1")
            guard mine == session else { return }
            if code == 200 || code == 206 { break }
            if code != 503 || Date() > deadline {
                state = .failed
                await releaseVoice()
                return
            }
            state = .warming
            try? await Task.sleep(for: .seconds(3))
        }
        guard mine == session, let headers = NexaClient.shared.accessHeaders() else { return }

        activateSession()
        let asset = AVURLAsset(url: NexaClient.shared.url("youtube/stream", query: query),
                               options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time, item) }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.finished() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.failed() }
        })
        player.play()
        state = .playing
        updateNowPlaying()
    }

    private func startRadio(_ url: URL) {
        activateSession()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        radioStartedAt = Date()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time, item) }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.failed() }
        })
        player.play()
        updateNowPlaying()
    }

    private func tick(_ time: CMTime, _ item: AVPlayerItem) {
        guard item === player?.currentItem else { return }
        if item.status == .failed {
            failed()
            return
        }
        if kind == .radio {
            // Live: playing once time moves; nothing after 10 s means the player can't take the stream.
            if time.seconds > 0.2, state == .loading {
                state = .playing
                talk?.musicNote("radio: playing in the app")
                updateNowPlaying()
            } else if state == .loading, let started = radioStartedAt, Date().timeIntervalSince(started) > 10 {
                failed()
            }
            return
        }
        position = time.seconds.isFinite ? time.seconds : 0
        let total = item.duration.seconds
        if total.isFinite, total > 0, abs(total - duration) > 1 {
            duration = total
            updateNowPlaying()
        }
    }

    private func finished() {
        player?.pause()
        player?.seek(to: .zero)
        position = 0
        state = .paused
        updateNowPlaying()
        Task { await releaseVoice() }
    }

    private func failed() {
        if kind == .radio {
            let why = player?.currentItem?.error?.localizedDescription ?? "no audio after 10 s"
            talk?.musicNote("radio: the iPhone can't play the stream (\(why)), the card opens Chrome")
        }
        teardown()
        state = .failed
        Task { await releaseVoice() }
    }

    private func teardown() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        player?.pause()
        player = nil
        radioStartedAt = nil
    }

    // MARK: Sharing the audio session with voice

    private func holdVoice() async {
        guard !holdsVoice else { return }
        holdsVoice = true
        await talk?.pauseForMusic()
    }

    private func releaseVoice() async {
        guard holdsVoice else { return }
        holdsVoice = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        await talk?.musicStopped()
    }

    private func activateSession() {
        let audio = AVAudioSession.sharedInstance()
        // Voice listens for her name during the music and set the session up for both (play and record).
        if talk?.musicListening == true {
            try? audio.setActive(true)
            return
        }
        try? audio.setCategory(.playback, mode: .default)
        try? audio.setActive(true)
    }

    // MARK: What is playing

    private func updateNowPlaying() {
        guard let url else { return }
        let info = meta[url]
        var now: [String: Any] = [
            MPMediaItemPropertyTitle: info?.title ?? Self.slugTitle(url),
            MPMediaItemPropertyArtist: info?.channel ?? kind.label,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: kind == .radio,
        ]
        if duration > 0 { now[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { now[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = now
    }

    /// Public metadata, no key needed: Mixcloud's API and SoundCloud's oEmbed (the kiosk uses the same).
    func loadMeta(_ url: URL, _ kind: MediaKind) {
        guard meta[url] == nil else { return }
        meta[url] = Meta(title: Self.slugTitle(url), channel: kind.label, art: nil, duration: 0)
        Task {
            guard let loaded = await Self.fetchMeta(url, kind) else { return }
            meta[url] = loaded
            if self.url == url {
                if duration == 0 { duration = loaded.duration }
                await loadArtwork(loaded.art)
                updateNowPlaying()
            }
        }
    }

    private func loadArtwork(_ art: URL?) async {
        guard let art, let result = try? await URLSession.shared.data(from: art),
              let image = UIImage(data: result.0) else { return }
        artwork = Self.makeArtwork(image)
    }

    /// Built outside the main actor: the system asks for the image on a background queue.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private static func fetchMeta(_ url: URL, _ kind: MediaKind) async -> Meta? {
        if kind == .radio {
            return Meta(title: await RadioCard.currentTitle() ?? "Live", channel: "Grooveline Radio", art: nil, duration: 0)
        }
        if kind == .mixcloud {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty, let api = URL(string: "https://api.mixcloud.com/\(path)/"),
                  let result = try? await URLSession.shared.data(from: api),
                  let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any]
            else { return nil }
            let user = json["user"] as? [String: Any]
            let pictures = json["pictures"] as? [String: Any]
            let art = (pictures?["large"] as? String) ?? (pictures?["medium"] as? String)
            return Meta(title: json["name"] as? String ?? slugTitle(url),
                        channel: user?["name"] as? String ?? "Mixcloud",
                        art: art.flatMap { URL(string: $0) },
                        duration: (json["audio_length"] as? Double) ?? 0)
        }
        var components = URLComponents(string: "https://soundcloud.com/oembed")!
        components.queryItems = [URLQueryItem(name: "format", value: "json"),
                                 URLQueryItem(name: "url", value: url.absoluteString)]
        guard let api = components.url, let result = try? await URLSession.shared.data(from: api),
              let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any]
        else { return nil }
        let author = json["author_name"] as? String ?? "SoundCloud"
        var title = json["title"] as? String ?? slugTitle(url)
        // oEmbed titles end in " by <author>"; drop exactly that tail ("Stand by Me" keeps its "by").
        if title.hasSuffix(" by \(author)") { title = String(title.dropLast(" by \(author)".count)) }
        return Meta(title: title, channel: author,
                    art: (json["thumbnail_url"] as? String).flatMap { URL(string: $0) }, duration: 0)
    }

    static func slugTitle(_ url: URL) -> String {
        let last = url.path.split(separator: "/").last.map(String.init) ?? url.absoluteString
        let decoded = last.removingPercentEncoding ?? last
        let words = decoded.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? url.absoluteString : words
    }

    static func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The in-chat player card: artwork, title, channel, play/pause, a progress line you can drag.
struct AudioCard: View {
    let url: URL
    let kind: MediaKind
    @ObservedObject private var audio = InlineAudio.shared

    var body: some View {
        let state = audio.state(for: url)
        let info = audio.meta[url]
        let mine = audio.url == url
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Artwork(url: info?.art, kind: kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info?.title ?? InlineAudio.slugTitle(url))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    Text(info?.channel ?? kind.label)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { AppLauncher.open(url) } label: {
                    Image(systemName: "arrow.up.right.square").foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                Button {
                    if mine { audio.toggle() } else { audio.play(url: url, kind: kind) }
                } label: {
                    ZStack {
                        if state == .warming || state == .loading {
                            ProgressView().tint(Theme.teal)
                        } else {
                            Image(systemName: state == .playing ? "pause.fill" : "play.fill")
                                .font(.title3)
                                .foregroundStyle(Theme.teal)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .glassEffect(Glass.regular.interactive(), in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    ProgressLine(progress: mine && audio.duration > 0 ? audio.position / audio.duration : 0) { fraction in
                        if mine { audio.seek(fraction: fraction) }
                    }
                    Text(timeline(state, mine))
                        .font(Theme.mono(10))
                        .foregroundStyle(state == .failed ? Theme.coral : Theme.muted)
                }
            }
        }
        .padding(12)
        .glassCard(tint: Theme.teal, cornerRadius: 16)
        .onAppear { audio.loadMeta(url, kind) }
    }

    private func timeline(_ state: InlineAudio.State, _ mine: Bool) -> String {
        switch state {
        case .warming: return "preparing the mix on the Jetson…"
        case .loading: return "loading…"
        case .failed: return "didn't play, tap to try again"
        default:
            let duration = mine ? audio.duration : (audio.meta[url]?.duration ?? 0)
            guard duration > 0 else { return kind.label }
            return "\(InlineAudio.time(mine ? audio.position : 0)) / \(InlineAudio.time(duration))"
        }
    }
}

/// A thin progress line; tap or drag to seek.
struct ProgressLine: View {
    let progress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.bg3)
                Capsule().fill(Theme.teal).frame(width: max(0, min(1, progress)) * geo.size.width)
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                onSeek(value.location.x / max(geo.size.width, 1))
            })
        }
        .frame(height: 14)
    }
}

/// Cover art, or the service's icon while it loads.
private struct Artwork: View {
    let url: URL?
    let kind: MediaKind

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: kind == .mixcloud ? "dot.radiowaves.left.and.right" : "waveform")
                .foregroundStyle(Theme.teal)
        }
        .frame(width: 46, height: 46)
        .background(Theme.bg3)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// While a mix plays: a small bar above the chat or the agent list to pause or stop it from anywhere.
struct NowPlayingBar: View {
    @ObservedObject private var audio = InlineAudio.shared

    var body: some View {
        if let url = audio.url, audio.state != .idle {
            let info = audio.meta[url]
            HStack(spacing: 10) {
                Artwork(url: info?.art, kind: audio.kind).scaleEffect(0.75).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info?.title ?? InlineAudio.slugTitle(url))
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(audio.state == .warming ? "preparing…" : (info?.channel ?? audio.kind.label))
                        .font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { audio.toggle() } label: {
                    Image(systemName: audio.state == .playing ? "pause.fill" : "play.fill")
                        .frame(width: 32, height: 32)
                        .contentTransition(.symbolEffect(.replace))
                }
                Button { audio.stop() } label: {
                    Image(systemName: "xmark").frame(width: 32, height: 32)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.teal)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassCard(tint: Theme.teal, cornerRadius: 22)
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
