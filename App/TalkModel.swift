import AVFoundation
import NexlineAudio
import NexlineCore
import os
import SwiftUI
import UIKit

/// Live mic level, kept apart from the model so only the meter redraws ~47 times a second.
@MainActor
final class Meter: ObservableObject {
    @Published var db = Level.silenceDB
    @Published var threshold: Float = -45
}

/// One voice conversation with Nexa: listen, send the turn, speak the reply sentence by sentence as it
/// streams in, listen again.
///
/// The user can cut in while Nexa speaks: the barge-in detector (on the echo-cancelled mic level) stops
/// playback, and serve.py is told what was actually heard. While Nexa thinks or speaks, recognizer text is
/// ignored, because it may be her own echo; after a cut-in, what the recognizer hears is the next turn.
@MainActor
final class TalkModel: ObservableObject {
    enum Phase: String {
        case off = "Off"
        case starting = "Starting…"
        case listening = "Listening"
        case thinking = "Thinking…"
        case speaking = "Speaking"
    }

    struct Line: Identifiable, Equatable, Codable {
        var id = UUID().uuidString
        let fromUser: Bool
        var text: String
        /// When it was said; unknown for messages loaded from serve.py.
        var time: Date? = nil
        /// A photo sent with it (a file in `ChatStore`).
        var imageFile: String? = nil
        /// The turn failed and `text` says why.
        var failed = false
    }

    /// A tool Hermes is running for the current reply.
    struct ToolTrace: Identifiable, Equatable {
        let id: String
        var done: Bool
    }

    struct LogLine: Identifiable {
        let id: Int
        let text: String
    }

    /// A piece of the reply on its way to the speaker. Voice pieces start synthesizing when created.
    private enum Job {
        case silence(ms: Int)
        case voice(String, AsyncThrowingStream<[Float], Error>)
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var hearing = ""
    /// Who the conversation is with. Voice and chat follow it.
    @Published private(set) var bot: Bot = .nexa
    /// The conversation with `bot`. Nexa's is the shared one (kiosk included), refreshed from serve.py while the
    /// app is open; the others are kept on the phone.
    @Published private(set) var lines: [Line] = [] {
        didSet { ChatStore.shared.save(bot, lines) }
    }
    @Published private(set) var tools: [ToolTrace] = []
    /// Mic off: she can keep talking, nothing is heard and nothing cuts her off.
    @Published var muted = false
    /// Standby: only sentences that start with her name count (then the conversation window keeps her awake).
    @Published var standby = false
    /// False while standby waits for her name.
    @Published private(set) var awake = true
    /// Voice is off because a mix is playing; it comes back when the mix stops.
    @Published private(set) var pausedForMusic = false
    /// "first audio 1.2 s" for the voice screen's debug line.
    @Published private(set) var lastTiming: String?
    /// Her voice and the mic level, read by the voice screen every frame (not published).
    let levels = VoiceLevels()
    /// A typed message is being answered while voice is off.
    @Published private(set) var typing = false
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var checking = false
    @Published private(set) var keysSet = TalkModel.keysPresent()
    let meter = Meter()

    /// Setup A from the audio spike (build 4): passed with echo cancellation on.
    private static let setup = VoiceEngine.SessionSetup(
        name: "default mode + A2DP + AirPlay", mode: .default,
        options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay])
    private static var localeID: String { SpeechLanguage.current.locale }

    private let engine = VoiceEngine()
    private let listener = Listener()
    private let deepgram = DeepgramListener()
    private let mic = MicRouter()
    private let voices = VoiceChain()
    private let nexa = NexaClient.shared
    private var historyTask: Task<Void, Never>?
    private var typedTask: Task<Void, Never>?
    private var historyProblem: String?
    private var lastTurnAt = 0.0
    /// The reply whose OPEN: line was already launched, so coming back to the app doesn't launch it again.
    private var launchedReply: String?
    /// Who is listening right now (Deepgram falls back to the iPhone mid-session).
    private var ears = EarsChoice.iphone
    private var detector = BargeInDetector()
    /// A sound over her voice pauses her; the user's words cut her off, anything else lets her carry on.
    private var gate = CutInGate()
    /// Everything paused so far: a piece still streaming in when she carries on lands this much later.
    private var pausedTotal = 0.0
    /// The piece being synthesized now: it joins the timeline only once it has streamed in, but its echo
    /// must already be told from the user's words.
    private var speakingText = ""
    /// After she carries on, echo cancellation settles again on her voice: cut-ins are strict until then.
    private var strictUntil = 0.0
    private var endpointer = Endpointer()
    private var observers: [NSObjectProtocol] = []
    private var logCount = 0
    private let logger = Logger(subsystem: "com.nexlineai.voice", category: "talk")

    private var bargeInOn = true
    /// Playing on a music-only speaker (Bluetooth A2DP, AirPlay) without echo cancellation. Voice processing only
    /// allows call routes, so iOS played her on the iPhone instead of the JBL (build 18); headphones and cars move
    /// to their call profile instead and keep it. The mic hears her here, so loudness can't cut her off: words that
    /// aren't in her reply do (build 22).
    private var speakerMode = false
    private var windowUntil = 0.0
    private var resumeVoiceAfterMusic = false

    /// Bumped by every new turn and every cut-in, so work from an older turn can tell it is stale.
    private var generation = 0
    private var chatTask: Task<Void, Never>?
    private var speakTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    /// Reply segments waiting to be synthesized.
    private var pending: [SpeechText.Segment] = []
    /// True while Nexa's reply is still streaming in.
    private var replyOpen = false
    /// When everything queued so far finishes playing (uptime seconds).
    private var playbackEnd = 0.0
    /// Echo cancellation settles on the first seconds of her voice after the engine starts or the route changes;
    /// until then cut-ins need more (build 15 cut every first reply after one word). Set by the first audio.
    private var settlingUntil: Double?
    private static let settleSeconds = 3.5
    private var timeline = HeardTimeline()
    private var turnEndedAt = 0.0
    private var firstTextAt: Double?
    private var firstAudioAt: Double?
    /// A turn only counts if the mic heard the user above the line since listening began. Without this,
    /// a few echo words recognized after Nexa stops could start a turn by themselves (a self-talk loop).
    private var listeningSince = 0.0
    private var lastLoudAt = -1.0
    /// When the user's last recognized word ended, and what ended their speech, for the turn-end log line.
    private var lastWordAt: Double?
    private var speechEndedBy: String?
    /// Her words when she was paused, and after words cut her off there: this turn's words around the pause that
    /// are hers are her echo.
    private var pausedHerWords: Set<String> = []
    private var echoCut: (at: Double, herWords: Set<String>)?
    /// Carapava and Mamadona keep their history on their own server, so a cut-off reply is only fixed there
    /// by telling them on the next turn what the user heard.
    private var agentCutNote: String?

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// The Bluetooth or AirPlay output the session plays to, if any.
    private static var musicOutput: String? {
        let music: [AVAudioSession.Port] = [.bluetoothA2DP, .airPlay, .bluetoothLE]
        return AVAudioSession.sharedInstance().currentRoute.outputs.first { music.contains($0.portType) }?.portName
    }

    private static var onPhoneSpeaker: Bool {
        let phone: [AVAudioSession.Port] = [.builtInSpeaker, .builtInReceiver]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { phone.contains($0.portType) }
    }
    private var playing: Bool { Self.now < playbackEnd && !gate.isPaused }

    init() {
        let router = self.mic
        engine.onMicBlock = { [weak self] block in
            Task { @MainActor in self?.micBlock(block) }
        }
        engine.onMicBuffer = { buffer in router.feed(buffer) }
        voices.onNote = { [weak self] message in self?.note(message) }
        engine.onEvent = { [weak self] message in
            Task { @MainActor in self?.note(message) }
        }
        lines = ChatStore.shared.lines(.nexa)
        observeSession()
    }

    // MARK: Bots

    /// Switches the conversation to `newBot` (stopping voice if it runs for another one).
    func select(_ newBot: Bot) async {
        guard newBot != bot else { return }
        if phase != .off { await endVoice() }
        typedTask?.cancel()
        typedTask = nil
        typing = false
        bot = newBot
        agentCutNote = nil
        lines = ChatStore.shared.lines(newBot)
        tools = []
        hearing = ""
        historyProblem = nil
        if newBot == .nexa { await refreshHistory() }
    }

    /// Nexa needs her Access token; the others only their own key, checked when they are asked.
    var canChat: Bool { bot != .nexa || keysSet }

    /// The reply stream for this turn: serve.py for Nexa, the gateway for the others.
    private func replies(_ text: String, image: String?,
                         voice: Bool = false) -> AsyncThrowingStream<ChatStreamParser.Event, Error> {
        if bot == .nexa { return nexa.chat(text, image: image) }
        let cut = agentCutNote
        agentCutNote = nil
        return AgentClient.chat(bot, text: text, history: Array(lines.dropLast(2)), image: image,
                                cutOffAfter: cut, voice: voice)
    }

    private func trace(_ label: String, _ status: String) {
        let name = label.replacingOccurrences(of: "mcp_", with: "").replacingOccurrences(of: "_mcp_", with: "_")
        let done = status == "completed" || status == "done"
        if let index = tools.firstIndex(where: { $0.id == name }) {
            tools[index].done = done
        } else {
            tools.append(ToolTrace(id: name, done: done))
        }
    }

    private func showFailure(_ error: Error) {
        guard let last = lines.indices.last, !lines[last].fromUser else { return }
        lines[last].text = error.localizedDescription
        lines[last].failed = true
    }

    /// Empties the conversation. Nexa's goes on serve.py too, so the kiosk starts fresh as well.
    func clearChat() async {
        if phase == .thinking || phase == .speaking { cutReply(report: false) }
        typedTask?.cancel()
        typing = false
        if bot == .nexa { try? await nexa.post("history/clear") }
        lines = []
        tools = []
        ChatStore.shared.clear(bot)
    }

    /// After the stored chats changed (Settings › Clear all chats).
    func reloadLines() {
        lines = ChatStore.shared.lines(bot)
    }

    // MARK: Voice mode

    /// Starts voice for the current bot. Standby is chosen by the screen: voice mode follows the setting, live
    /// chat never waits for the name (the user just tapped to talk).
    func startVoice(standby: Bool) async {
        self.standby = standby
        windowUntil = 0
        awake = !standby
        muted = false
        bargeInOn = Prefs.bool(Prefs.bargeIn, default: true)
        resumeVoiceAfterMusic = false
        pausedForMusic = false
        InlineAudio.shared.yieldToVoice()
        await start()
    }

    func endVoice() async {
        resumeVoiceAfterMusic = false
        pausedForMusic = false
        await stop()
    }

    func setStandby(_ on: Bool) {
        standby = on
        windowUntil = 0
        awake = !on
    }

    /// Tap on the orb: stop her now (like talking over her).
    func hush() {
        if phase == .thinking || phase == .speaking { cutIn() }
    }

    /// A mix needs the audio session without voice processing (it gates music to near silence), so voice stops
    /// while it plays and starts again after.
    func pauseForMusic() async {
        guard phase != .off else { return }
        resumeVoiceAfterMusic = true
        pausedForMusic = true
        await stop()
    }

    func musicStopped() async {
        guard resumeVoiceAfterMusic else { return }
        resumeVoiceAfterMusic = false
        pausedForMusic = false
        await start()
    }

    /// Standby lets a sentence through when it starts with her name ("Hey Nexa, …"), or while the conversation
    /// window from the last one is still open.
    private func admits(_ text: String) -> Bool {
        guard standby else { return true }
        if Self.now < windowUntil {
            openWindow()
            return true
        }
        let lowered = text.lowercased().replacingOccurrences(
            of: "^(hey|ok|okay|oi|olá|ola)[\\s,]+", with: "", options: .regularExpression)
        let words = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard let first = words.first else { return false }
        let firstTwo = words.prefix(2).joined(separator: " ")
        guard bot.wakeNames.contains(first) || bot.wakeNames.contains(firstTwo) else { return false }
        openWindow()
        return true
    }

    /// Sliding: every accepted sentence and every reply pushes it out, so only real silence re-arms the name.
    private func openWindow() {
        let minutes = Prefs.conversationWindowMinutes
        windowUntil = minutes > 0 ? Self.now + Double(minutes * 60) : 0
    }

    // MARK: Media

    /// The newest reply's mix starts by itself (only replies that arrived now, never history).
    private func autoplayMedia(in reply: String) {
        guard keysSet, Prefs.bool(Prefs.autoplayMedia, default: true) else { return }
        for block in ReplyBlocks.parse(reply) {
            if case .media(let url, let kind) = block, MediaKind.playsInline(url.absoluteString, kind) {
                InlineAudio.shared.play(url: url, kind: kind, autoplay: true)
                return
            }
        }
    }

    /// Only Nexa's token is required: without the xAI or Deepgram key the fallbacks take over.
    nonisolated static func keysPresent() -> Bool {
        Keychain.get(.nexaClientID) != nil && Keychain.get(.nexaClientSecret) != nil
    }

    func keysChanged() {
        keysSet = Self.keysPresent()
        Self.keysCached = keysSet
    }

    /// For views that can't observe the model (reply blocks), so streaming doesn't read the Keychain per frame.
    static var keysCached = TalkModel.keysPresent()

    // MARK: The shared conversation

    /// Keeps the conversation in step with the kiosk while the app is on screen.
    func startSync() {
        guard historyTask == nil else { return }
        historyTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshHistory()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func stopSync() {
        historyTask?.cancel()
        historyTask = nil
    }

    /// Never during a turn (it would replace the reply being streamed), and not with fewer messages than shown
    /// right after a turn, when serve.py may not have saved it yet.
    private func refreshHistory() async {
        guard keysSet, bot == .nexa, !turnBusy else { return }
        do {
            let messages = try await nexa.history()
            guard bot == .nexa, !turnBusy else { return }
            let old = lines
            let fresh = messages.enumerated().map { item -> Line in
                var line = Line(id: "h\(item.offset)", fromUser: item.element.fromUser, text: item.element.text)
                // serve.py keeps no times; keep the ones this phone saw.
                if item.offset < old.count, old[item.offset].text == line.text {
                    line.time = old[item.offset].time
                    line.imageFile = old[item.offset].imageFile
                }
                return line
            }
            if historyProblem != nil || lines.isEmpty && !fresh.isEmpty {
                note("conversation: \(fresh.count) messages from serve.py")
            }
            historyProblem = nil
            if fresh.count < lines.count && Self.now - lastTurnAt < 15 { return }
            let same = fresh.count == lines.count
                && zip(fresh, lines).allSatisfy { $0.fromUser == $1.fromUser && $0.text == $1.text }
            if !same { lines = fresh }
        } catch {
            let problem = error.localizedDescription
            if problem != historyProblem { note("conversation: can't load (\(problem))") }
            historyProblem = problem
        }
    }

    private var turnBusy: Bool {
        chatTask != nil || typing || phase == .thinking || phase == .speaking
    }

    /// A typed message. With voice on it is a turn like a spoken one (and cuts Nexa off if she is talking);
    /// with voice off the reply only shows as text.
    func sendTyped(_ raw: String, photo: Data? = nil) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || photo != nil, canChat else { return }
        let jpeg = photo.flatMap(PhotoPrep.jpeg)
        switch phase {
        case .off:
            sendTextOnly(text, photo: jpeg)
        case .starting:
            return
        case .listening:
            endpointer.reset()
            hearing = ""
            send(text, photo: jpeg)
        case .thinking, .speaking:
            cutIn()
            endpointer.reset()
            send(text, photo: jpeg)
        }
    }

    private func sendTextOnly(_ text: String, photo: Data? = nil) {
        typedTask?.cancel()
        lines.append(Line(fromUser: true, text: text, time: Date(), imageFile: photo.flatMap { ChatStore.shared.storePhoto($0) }))
        lines.append(Line(fromUser: false, text: "", time: Date()))
        lastTurnAt = Self.now
        typing = true
        tools = []
        let stream = replies(text, image: photo.map(PhotoPrep.dataURI))
        typedTask = Task { [weak self] in
            guard let self else { return }
            var reply = ""
            do {
                for try await event in stream {
                    switch event {
                    case .text(let full):
                        reply = full
                        self.showReply(full)
                    case .tool(let label, let status):
                        self.trace(label, status)
                    case .done:
                        break
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.note("\(self.bot.name): \(error.localizedDescription)")
                    if reply.isEmpty { self.showFailure(error) }
                }
            }
            self.lastTurnAt = Self.now
            self.typing = false
            self.tools = []
            if !Task.isCancelled && !reply.isEmpty { self.autoplayMedia(in: reply) }
        }
    }

    // MARK: Start and stop

    func toggle() async {
        if phase == .off { await start() } else { await stop() }
    }

    func start() async {
        guard phase == .off else { return }
        guard canChat else {
            note("add Nexa's token first (Settings)")
            return
        }
        phase = .starting
        settlingUntil = nil
        let botVoice = BotVoice.current(bot)
        let voice = botVoice.engine
        voices.reset(primary: voice, xai: botVoice.xai, deepgram: botVoice.deepgram)
        note("voice: " + voice.chain.map(\.name).joined(separator: " → "))
        do {
            try engine.configureSession(Self.setup)
            let speaker = Self.musicOutput
            speakerMode = false
            gate = CutInGate()
            try engine.start(voiceProcessing: true)
            if let speaker {
                // Voice processing moves the route; give it a moment, then see where she ended up.
                try? await Task.sleep(for: .milliseconds(700))
                guard phase == .starting else { return }
                if Self.onPhoneSpeaker {
                    try engine.configureSession(Self.setup)
                    try engine.start(voiceProcessing: false)
                    speakerMode = true
                    // Words reach the recognizer late, and her voice keeps playing for the speaker's latency.
                    gate.leadIn = 1.5
                    gate.echoTail = 0.4 + AVAudioSession.sharedInstance().outputLatency
                    note("\(speaker) only plays music: echo cancellation off so she plays there; words that aren't hers stop her")
                }
            }
            try await startEars(EarsChoice.current)
        } catch {
            note("start failed: \(error.localizedDescription)")
            await stop()
            return
        }
        beginListening()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.tick()
            }
        }
    }

    func stop() async {
        cutReply(report: false)
        tickTask?.cancel()
        tickTask = nil
        mic.target = nil
        deepgram.stop()
        await listener.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        hearing = ""
        speakerMode = false
        phase = .off
    }

    private func beginListening() {
        echoCut = nil
        endpointer.reset()
        hearing = ""
        listeningSince = Self.now
        phase = .listening
    }

    // MARK: Hearing the user

    /// Starts Deepgram, or the iPhone's recognizer when Deepgram is not chosen or can't start.
    private func startEars(_ choice: EarsChoice) async throws {
        if choice == .deepgram {
            do {
                // Deepgram says when speech ended; these gaps are only the backstop.
                endpointer = Endpointer(finalGap: 1.6, volatileGap: 2.5)
                let stream = self.deepgram
                mic.target = { buffer in stream.feed(buffer) }
                try deepgram.start(
                    onResult: { [weak self] text, isFinal, endsAt, words in
                        self?.recognized(text, isFinal: isFinal, endsAt: endsAt, words: words)
                    },
                    onSpeechEnd: { [weak self] event in self?.speechEnded(by: event) },
                    onFail: { [weak self] reason in Task { await self?.earsFailed(reason) } })
                ears = .deepgram
                note("listening with Deepgram")
                return
            } catch {
                mic.target = nil
                note("listening: Deepgram can't start (\(error.localizedDescription)), using the iPhone")
            }
        }
        endpointer = Endpointer()
        let recognizer = self.listener
        mic.target = { buffer in recognizer.feed(buffer) }
        try await listener.start(
            localeID: Self.localeID,
            onResult: { [weak self] text, isFinal in self?.recognized(text, isFinal: isFinal, endsAt: nil) },
            onEvent: { [weak self] message in self?.note(message) })
        ears = .iphone
    }

    private func earsFailed(_ reason: String) async {
        guard phase != .off, ears == .deepgram else { return }
        note("listening: Deepgram failed (\(reason)), using the iPhone")
        mic.target = nil
        do {
            try await startEars(.iphone)
            if phase == .listening { beginListening() }
        } catch {
            note("listening: the iPhone failed too (\(error.localizedDescription)), stopped")
            await stop()
        }
    }

    private func micBlock(_ block: VoiceEngine.MicBlock) {
        let now = Self.now
        let playing = self.playing
        let paused = gate.isPaused
        // The gaps between her pieces count as playing: the echo tail of a short first piece cut her off there.
        let shielded = !paused && (playing || phase == .speaking)
        let strict = !paused && ((settlingUntil.map { now < $0 } ?? false) || now < strictUntil)
        meter.db = block.levelDB
        meter.threshold = detector.threshold(playing: shielded, strict: strict)
        levels.micDB = muted ? Level.silenceDB : block.levelDB
        if !shielded && block.levelDB > detector.threshold(playing: false) { lastLoudAt = now }
        let speech = detector.process(levelDB: block.levelDB, durationMs: block.durationMs, playing: shielded,
                                      strict: strict)
        if paused {
            act(gate.level(loud: !muted && block.levelDB > detector.threshold(playing: false), at: now), at: now)
            return
        }
        if speech && phase == .speaking && bargeInOn && !speakerMode && !muted {
            let into = settlingUntil.map { now - ($0 - Self.settleSeconds) } ?? 0
            note(String(format: "sound over her: mic %.0f dB over the %.0f dB line (floor %.0f), %@, %.1f s into her voice%@",
                        block.levelDB, meter.threshold, detector.noiseFloorDB,
                        playing ? "while she played" : "in a gap between pieces", into,
                        strict ? ", echo cancellation settling" : ""))
            // Only Deepgram gives word times to tell the user from her echo; the iPhone's recognizer cuts at once.
            if ears == .deepgram {
                gate.pause(at: now, herText: timeline.text(around: now) + " " + speakingText)
                pausedHerWords = gate.herWords
                engine.pausePlayback()
            } else {
                cutIn()
            }
        }
    }

    /// What the gate decided about a sound over her voice.
    private func act(_ action: CutInGate.Action, at now: Double) {
        switch action {
        case .wait:
            break
        case .resume(let pausedAt):
            let held = now - pausedAt
            note(String(format: "carried on after %.1f s, no words from you", held))
            if playbackEnd > pausedAt { playbackEnd += held }
            if let settling = settlingUntil, settling > pausedAt { settlingUntil = settling + held }
            timeline.shift(after: pausedAt, by: held)
            levels.shift(after: pausedAt, by: held)
            pausedTotal += held
            strictUntil = now + 1
            engine.resumePlayback()
        case .cut(let pausedAt, let words):
            note(words.map { "cut off by your words: \"\($0)\"" } ?? "cut off: you kept talking for 1 s")
            cutIn(at: pausedAt)
        }
    }

    private func recognized(_ text: String, isFinal: Bool, endsAt: Double?, words: [HeardWord] = []) {
        if gate.isPaused && !muted {
            // While she is paused for a sound, words decide it; if they cut her off, this result starts the turn.
            act(gate.heard(words), at: Self.now)
        } else if speakerMode && phase == .speaking && bargeInOn && !muted {
            // No echo cancellation on a speaker: the mic hears her too, so words that aren't in her reply are the
            // user. They pause her, and words that follow confirm it as on the phone.
            let script = lines.last(where: { !$0.fromUser }).map { SpeechText.clean($0.text) } ?? ""
            let herWords = CutInGate.vocabulary(script)
            let yours = words.filter { $0.end > turnEndedAt && CutInGate.isForeign($0.text, to: herWords) }
            if !yours.isEmpty {
                note("words over her on the speaker: \"\(yours.map(\.text).joined(separator: " "))\"")
                gate.pause(at: Self.now, herText: script)
                pausedHerWords = gate.herWords
                engine.pausePlayback()
            }
        }
        guard phase == .listening, !muted else { return }
        // Deepgram's results arrive late: one whose audio ended before listening began is Nexa's echo.
        if let endsAt, endsAt < listeningSince { return }
        // After a cut at a pause, so are its words around the pause that are hers (a result can start with her echo).
        var text = text
        if let cut = echoCut {
            let kept = gate.yours(words, pausedAt: cut.at, herWords: cut.herWords)
            if kept.count < words.count { text = kept.map(\.text).joined(separator: " ") }
        }
        if let last = words.last { lastWordAt = last.end }
        endpointer.add(text, isFinal: isFinal, at: Self.now)
        hearing = endpointer.text
    }

    private func speechEnded(by event: String) {
        guard phase == .listening else { return }
        speechEndedBy = event
        endpointer.speechEnded(at: Self.now)
    }

    private func tick() {
        let now = Self.now
        let isAwake = !standby || now < windowUntil
        if awake != isAwake { awake = isAwake }
        switch phase {
        case .listening:
            guard let text = endpointer.take(at: now) else { return }
            hearing = ""
            if ears == .deepgram, let lastWordAt {
                note(String(format: "turn ended %.1f s after your last word (%@%@)", now - lastWordAt,
                            speechEndedBy ?? "no end event, silence backstop",
                            Endpointer.looksUnfinished(text) ? ", sounded unfinished" : ""))
            }
            lastWordAt = nil
            speechEndedBy = nil
            guard lastLoudAt >= listeningSince else {
                note("ignored, the mic never heard you loud enough (echo?): \"\(text)\"")
                return
            }
            guard admits(text) else {
                note("standby, not for \(bot.name): \"\(text)\"")
                return
            }
            send(text)
        case .thinking, .speaking:
            // Also ends a turn whose voice failed, which would otherwise stay "thinking".
            // A speaker plays a little behind the queue (Bluetooth latency): listen once it has really finished.
            let tail = speakerMode ? AVAudioSession.sharedInstance().outputLatency + 0.3 : 0
            if !gate.isPaused && !replyOpen && pending.isEmpty && speakTask == nil && now >= playbackEnd + tail {
                finishReply()
            }
        default:
            break
        }
    }

    /// `pausedAt`: she was paused for the sound then, so that's where she stopped.
    private func cutIn(at pausedAt: Double? = nil) {
        let now = Self.now
        // A typed message or the music hand-off can cut in while she is paused: she stopped at the pause.
        let moment = pausedAt ?? gate.pausedAt ?? now
        let heard = timeline.heard(at: moment)
        let complete = timeline.fullyPlayed(at: moment) && !replyOpen && pending.isEmpty
        cutReply(report: !complete, heard: heard)
        note(complete ? "you talked as she finished" : "you cut in after: \"\(heard)\"")
        beginListening()
        // The words that confirmed the cut were said after the pause and are this turn's start.
        if let pausedAt {
            listeningSince = pausedAt
            echoCut = (pausedAt, pausedHerWords)
        }
        lastLoudAt = now
    }

    // MARK: Nexa's turn

    private func send(_ text: String, photo: Data? = nil) {
        generation += 1
        let gen = generation
        lines.append(Line(fromUser: true, text: text, time: Date(), imageFile: photo.flatMap { ChatStore.shared.storePhoto($0) }))
        lines.append(Line(fromUser: false, text: "", time: Date()))
        tools = []
        lastTurnAt = Self.now
        phase = .thinking
        turnEndedAt = Self.now
        firstTextAt = nil
        firstAudioAt = nil
        timeline = HeardTimeline()
        pending = []
        replyOpen = true
        playbackEnd = 0
        note("you: \(text)")

        let stream = replies(text, image: photo.map(PhotoPrep.dataURI), voice: true)
        chatTask = Task { [weak self] in
            guard let self else { return }
            var flusher = SentenceFlusher()
            var reply = ""
            do {
                for try await event in stream {
                    guard gen == self.generation else { return }
                    switch event {
                    case .text(let full):
                        reply = full
                        if self.firstTextAt == nil { self.firstTextAt = Self.now }
                        self.showReply(full)
                        if let piece = flusher.take(full, final: false) { self.speak(piece, gen) }
                    case .tool(let label, let status):
                        self.note("tool: \(label) \(status)")
                        self.trace(label, status)
                        // "Let me check." has no space after it until the tools finish, so speak it now
                        // instead of seconds later (build 9: first audio 8 s after first text).
                        if let piece = flusher.take(reply, final: true) { self.speak(piece, gen) }
                    case .done:
                        break
                    }
                }
                guard gen == self.generation else { return }
                if let piece = flusher.take(reply, final: true) { self.speak(piece, gen) }
            } catch {
                guard gen == self.generation else { return }
                self.note("\(self.bot.name): \(error.localizedDescription)")
                if reply.isEmpty { self.showFailure(error) }
            }
            self.replyOpen = false
        }
    }

    private func showReply(_ text: String) {
        guard let last = lines.indices.last, !lines[last].fromUser else { return }
        lines[last].text = ReplyBlocks.rewriteMediaURLs(text, base: NexaClient.base.absoluteString)
    }

    private func speak(_ piece: String, _ gen: Int) {
        pending += SpeechText.segments(piece)
        guard speakTask == nil, !pending.isEmpty else { return }
        speakTask = Task { [weak self] in
            await self?.speakLoop(gen)
            if self?.generation == gen { self?.speakTask = nil }
        }
    }

    private func open(_ segment: SpeechText.Segment) -> Job {
        switch segment {
        case .silence(let ms): return .silence(ms: ms)
        case .text(let text): return .voice(text, voices.stream(text))
        }
    }

    /// Plays the reply in order while it streams in. The next piece is synthesized while the current one plays.
    private func speakLoop(_ gen: Int) async {
        var next: Job?
        while gen == generation {
            let job: Job
            if let prefetched = next {
                job = prefetched
                next = nil
            } else if !pending.isEmpty {
                job = open(pending.removeFirst())
            } else if replyOpen {
                try? await Task.sleep(for: .milliseconds(30))
                continue
            } else {
                return
            }

            switch job {
            case .silence(let ms):
                schedule([Float](repeating: 0, count: 24 * ms))
            case .voice(let text, let stream):
                speakingText = text
                var startAt: Double?
                var pausedBefore = 0.0
                var seconds = 0.0
                do {
                    for try await chunk in stream {
                        guard gen == generation else { return }
                        let at = schedule(chunk)
                        if startAt == nil {
                            startAt = at
                            pausedBefore = pausedTotal
                        }
                        seconds += Double(chunk.count) / VoiceEngine.playbackFormat.sampleRate
                        if next == nil && !pending.isEmpty { next = open(pending.removeFirst()) }
                    }
                } catch {
                    note("voice: \(error.localizedDescription)")
                }
                if let startAt {
                    let moved = pausedTotal - pausedBefore
                    timeline.add(text, start: startAt + moved, end: startAt + moved + seconds)
                }
            }
        }
    }

    /// Queues audio after what is already playing. Returns when it will start playing.
    @discardableResult
    private func schedule(_ samples: [Float]) -> Double {
        let now = Self.now
        // While paused, new audio queues behind the pause and moves with everything else when she carries on.
        let startAt = max(playbackEnd, gate.pausedAt ?? now)
        let seconds = engine.enqueue(samples)
        guard seconds > 0 else { return startAt }
        playbackEnd = startAt + seconds
        if settlingUntil == nil { settlingUntil = startAt + Self.settleSeconds }
        levels.addSpeech(samples, start: startAt, seconds: seconds)
        if firstAudioAt == nil {
            firstAudioAt = now
            phase = .speaking
            let text = firstTextAt.map { String(format: "first text %.1f s, ", $0 - turnEndedAt) } ?? ""
            note(String(format: "%@first audio %.1f s after your turn ended", text, now - turnEndedAt))
            lastTiming = String(format: "%@first audio %.1f s", text, now - turnEndedAt)
        }
        return startAt
    }

    private func finishReply() {
        chatTask = nil
        speakTask = nil
        lastTurnAt = Self.now
        tools = []
        if standby { openWindow() }
        launchOpenLine()
        beginListening()
        if let reply = lines.last(where: { !$0.fromUser })?.text { autoplayMedia(in: reply) }
    }

    /// Voice mode opens the app a reply asks for ("play X on YouTube" → OPEN:youtube:X), once, after the reply
    /// has finished: mid-stream the line may still be partial.
    private func launchOpenLine() {
        guard UserDefaults.standard.object(forKey: AppLauncher.settingKey) as? Bool ?? true,
              let reply = lines.last(where: { !$0.fromUser })?.text, reply != launchedReply,
              let link = reply.components(separatedBy: "\n").compactMap(AppLink.parse).last
        else { return }
        launchedReply = reply
        note("opening \(link.label)" + (link.query.map { ": \($0)" } ?? ""))
        AppLauncher.open(link)
    }

    private func cutReply(report: Bool, heard: String = "") {
        generation += 1
        chatTask?.cancel()
        chatTask = nil
        speakTask?.cancel()
        speakTask = nil
        pending = []
        replyOpen = false
        gate.reset()
        engine.stopPlayback()
        playbackEnd = 0
        levels.clearSpeech()
        guard report else { return }
        // Only Nexa's server takes the report; it went to Nexa for every bot until build 19.
        if bot == .nexa {
            let client = self.nexa
            Task { await client.reportInterrupt(heard: heard) }
        } else if let index = lines.lastIndex(where: { !$0.fromUser }) {
            lines[index].text = (heard.isEmpty ? "" : heard + " ") + ReplyBlocks.cutMarker
            agentCutNote = heard
        }
    }

    // MARK: Check connection

    /// Read-only checks: the token passes Access, the Deepgram key is accepted, and each voice speaks one fixed
    /// sentence, so every fallback is known to work before it's needed. Nothing reaches the conversation, so
    /// the kiosk doesn't see it.
    func checkConnection() async {
        guard !checking, phase == .off else { return }
        checking = true
        defer { checking = false }

        do {
            let status = try await nexa.checkConnection()
            note("Nexa: OK, \(status)")
        } catch {
            note("Nexa: FAIL, \(error.localizedDescription)")
        }
        let history = await nexa.probe("history")
        note("Nexa history: " + history)
        let home = await nexa.probe("ha/states")
        note("Nexa home (HA): " + home)

        if Keychain.get(.deepgramKey) != nil {
            do {
                let status = try await DeepgramListener.checkKey()
                note("Deepgram: OK, \(status)")
            } catch {
                note("Deepgram: FAIL, \(error.localizedDescription)")
            }
        } else {
            note("Deepgram: no key, the iPhone listens")
        }

        do {
            try engine.configureSession(Self.setup)
            try engine.start(voiceProcessing: true)
        } catch {
            note("voices: FAIL, \(error.localizedDescription)")
            return
        }
        for choice in VoiceChoice.allCases {
            let started = Self.now
            var first: Double?
            var seconds = 0.0
            do {
                for try await chunk in VoiceChain.source(choice, "This is the \(choice.name) voice.") {
                    if first == nil { first = Self.now - started }
                    seconds += engine.enqueue(chunk)
                }
                guard let first else { throw CheckError.noAudio }
                note(String(format: "voice %@: OK, first audio %.1f s", choice.name, first))
                try? await Task.sleep(for: .seconds(seconds + 0.4))
            } catch {
                note("voice \(choice.name): FAIL, \(error.localizedDescription)")
            }
        }
        engine.stop()
    }

    /// Settings: one sentence in a voice, so a choice can be heard before it is kept. Only while voice is off.
    func previewVoice(_ choice: VoiceChoice, xai: String, deepgram: String) async {
        guard !checking, phase == .off else { return }
        checking = true
        defer { checking = false }
        do {
            try engine.configureSession(Self.setup)
            try engine.start(voiceProcessing: true)
        } catch {
            note("voice preview: \(error.localizedDescription)")
            return
        }
        var seconds = 0.0
        do {
            for try await chunk in VoiceChain.source(choice, "Hey, this is how I sound now.", xai: xai, deepgram: deepgram) {
                seconds += engine.enqueue(chunk)
            }
        } catch {
            note("voice preview \(choice.name): \(error.localizedDescription)")
        }
        try? await Task.sleep(for: .seconds(seconds + 0.3))
        engine.stop()
    }

    private enum CheckError: LocalizedError {
        case noAudio
        var errorDescription: String? { "no audio" }
    }

    // MARK: Session events and log

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw == AVAudioSession.InterruptionType.began.rawValue
            Task { @MainActor in
                guard let self else { return }
                if began && self.phase != .off {
                    self.note("interrupted (call or alarm), stopped")
                    await self.stop()
                }
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            let route = AVAudioSession.sharedInstance().currentRoute
            let inputs = route.inputs.map(\.portName).joined(separator: ", ")
            let outputs = route.outputs.map(\.portName).joined(separator: ", ")
            Task { @MainActor in
                guard let self else { return }
                self.note("route: \(inputs) → \(outputs)")
                self.settlingUntil = nil
                // The speaker went away: back to echo cancellation on whatever is left.
                if self.speakerMode && self.phase != .off && Self.musicOutput == nil {
                    self.speakerMode = false
                    self.note("the speaker is gone, starting again with echo cancellation")
                    await self.stop()
                    await self.start()
                }
            }
        })
    }

    func copyLog() {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let head = "Nexline Voice, talk build \(build), iOS \(UIDevice.current.systemVersion)"
        UIPasteboard.general.string = ([head, ""] + log.map(\.text)).joined(separator: "\n")
        note("log copied")
    }

    private func note(_ text: String) {
        logger.notice("\(text, privacy: .public)")
        logCount += 1
        log.append(LogLine(id: logCount, text: text))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}

/// Hands the engine's mic buffers to whoever is listening (Deepgram or the iPhone's recognizer).
/// `feed` runs on the audio thread.
final class MicRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var _target: ((AVAudioPCMBuffer) -> Void)?

    var target: ((AVAudioPCMBuffer) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _target }
        set { lock.lock(); _target = newValue; lock.unlock() }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        target?(buffer)
    }
}
