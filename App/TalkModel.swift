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

    struct Line: Identifiable, Equatable {
        var id = UUID().uuidString
        let fromUser: Bool
        var text: String
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
    /// The shared conversation (kiosk included), refreshed from serve.py while the app is open.
    @Published private(set) var lines: [Line] = []
    /// A typed message is being answered while voice is off.
    @Published private(set) var typing = false
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var checking = false
    @Published private(set) var keysSet = TalkModel.keysPresent()
    let meter = Meter()

    /// Setup A from the audio spike (build 4): passed with echo cancellation on.
    private static let setup = VoiceEngine.SessionSetup(
        name: "default mode + A2DP", mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
    private static let localeID = "en-US"

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
    private var endpointer = Endpointer()
    private var observers: [NSObjectProtocol] = []
    private var logCount = 0
    private let logger = Logger(subsystem: "com.nexlineai.voice", category: "talk")

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
    private var timeline = HeardTimeline()
    private var turnEndedAt = 0.0
    private var firstTextAt: Double?
    private var firstAudioAt: Double?
    /// A turn only counts if the mic heard the user above the line since listening began. Without this,
    /// a few echo words recognized after Nexa stops could start a turn by themselves (a self-talk loop).
    private var listeningSince = 0.0
    private var lastLoudAt = -1.0

    private static var now: Double { ProcessInfo.processInfo.systemUptime }
    private var playing: Bool { Self.now < playbackEnd }

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
        observeSession()
    }

    /// Only Nexa's token is required: without the xAI or Deepgram key the fallbacks take over.
    nonisolated static func keysPresent() -> Bool {
        Keychain.get(.nexaClientID) != nil && Keychain.get(.nexaClientSecret) != nil
    }

    func keysChanged() {
        keysSet = Self.keysPresent()
    }

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
        guard keysSet, !turnBusy else { return }
        do {
            let messages = try await nexa.history()
            guard !turnBusy else { return }
            let fresh = messages.enumerated().map { Line(id: "h\($0.offset)", fromUser: $0.element.fromUser, text: $0.element.text) }
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
    func sendTyped(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, keysSet else { return }
        switch phase {
        case .off:
            sendTextOnly(text)
        case .starting:
            return
        case .listening:
            endpointer.reset()
            hearing = ""
            send(text)
        case .thinking, .speaking:
            cutIn()
            endpointer.reset()
            send(text)
        }
    }

    private func sendTextOnly(_ text: String) {
        typedTask?.cancel()
        lines.append(Line(fromUser: true, text: text))
        lines.append(Line(fromUser: false, text: ""))
        lastTurnAt = Self.now
        typing = true
        typedTask = Task { [weak self] in
            guard let self else { return }
            var reply = ""
            do {
                for try await event in self.nexa.chat(text) {
                    if case .text(let full) = event {
                        reply = full
                        self.showReply(full)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.note("Nexa: \(error.localizedDescription)")
                    if reply.isEmpty { self.showReply("(no reply: \(error.localizedDescription))") }
                }
            }
            self.lastTurnAt = Self.now
            self.typing = false
        }
    }

    // MARK: Start and stop

    func toggle() async {
        if phase == .off { await start() } else { await stop() }
    }

    func start() async {
        guard phase == .off else { return }
        guard keysSet else {
            note("add Nexa's token first (Settings)")
            return
        }
        phase = .starting
        let voice = VoiceChoice.current
        voices.reset(primary: voice)
        note("voice: " + voice.chain.map(\.name).joined(separator: " → "))
        do {
            try engine.configureSession(Self.setup)
            try engine.start(voiceProcessing: true)
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
        phase = .off
    }

    private func beginListening() {
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
                    onResult: { [weak self] text, isFinal, endsAt in self?.recognized(text, isFinal: isFinal, endsAt: endsAt) },
                    onSpeechEnd: { [weak self] in self?.speechEnded() },
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
        let playing = self.playing
        meter.db = block.levelDB
        meter.threshold = detector.threshold(playing: playing)
        if !playing && block.levelDB > detector.threshold(playing: false) { lastLoudAt = Self.now }
        let speech = detector.process(levelDB: block.levelDB, durationMs: block.durationMs, playing: playing)
        if speech && phase == .speaking { cutIn() }
    }

    private func recognized(_ text: String, isFinal: Bool, endsAt: Double?) {
        guard phase == .listening else { return }
        // Deepgram's results arrive late: one whose audio ended before listening began is Nexa's echo.
        if let endsAt, endsAt < listeningSince { return }
        endpointer.add(text, isFinal: isFinal, at: Self.now)
        hearing = endpointer.text
    }

    private func speechEnded() {
        guard phase == .listening else { return }
        endpointer.speechEnded(at: Self.now)
    }

    private func tick() {
        let now = Self.now
        switch phase {
        case .listening:
            guard let text = endpointer.take(at: now) else { return }
            hearing = ""
            guard lastLoudAt >= listeningSince else {
                note("ignored, the mic never heard you loud enough (echo?): \"\(text)\"")
                return
            }
            send(text)
        case .thinking, .speaking:
            // Also ends a turn whose voice failed, which would otherwise stay "thinking".
            if !replyOpen && pending.isEmpty && speakTask == nil && now >= playbackEnd { finishReply() }
        default:
            break
        }
    }

    private func cutIn() {
        let now = Self.now
        let heard = timeline.heard(at: now)
        let complete = timeline.fullyPlayed(at: now) && !replyOpen && pending.isEmpty
        cutReply(report: !complete, heard: heard)
        note(complete ? "you talked as she finished" : "you cut in after: \"\(heard)\"")
        beginListening()
        lastLoudAt = now
    }

    // MARK: Nexa's turn

    private func send(_ text: String) {
        generation += 1
        let gen = generation
        lines.append(Line(fromUser: true, text: text))
        lines.append(Line(fromUser: false, text: ""))
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

        chatTask = Task { [weak self] in
            guard let self else { return }
            var flusher = SentenceFlusher()
            var reply = ""
            do {
                for try await event in self.nexa.chat(text) {
                    guard gen == self.generation else { return }
                    switch event {
                    case .text(let full):
                        reply = full
                        if self.firstTextAt == nil { self.firstTextAt = Self.now }
                        self.showReply(full)
                        if let piece = flusher.take(full, final: false) { self.speak(piece, gen) }
                    case .tool(let label, let status):
                        self.note("tool: \(label) \(status)")
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
                self.note("Nexa: \(error.localizedDescription)")
                if reply.isEmpty { self.showReply("(no reply: \(error.localizedDescription))") }
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
                var startAt: Double?
                var seconds = 0.0
                do {
                    for try await chunk in stream {
                        guard gen == generation else { return }
                        let at = schedule(chunk)
                        if startAt == nil { startAt = at }
                        seconds += Double(chunk.count) / VoiceEngine.playbackFormat.sampleRate
                        if next == nil && !pending.isEmpty { next = open(pending.removeFirst()) }
                    }
                } catch {
                    note("voice: \(error.localizedDescription)")
                }
                if let startAt { timeline.add(text, start: startAt, end: startAt + seconds) }
            }
        }
    }

    /// Queues audio after what is already playing. Returns when it will start playing.
    @discardableResult
    private func schedule(_ samples: [Float]) -> Double {
        let now = Self.now
        let startAt = max(playbackEnd, now)
        let seconds = engine.enqueue(samples)
        guard seconds > 0 else { return startAt }
        playbackEnd = startAt + seconds
        if firstAudioAt == nil {
            firstAudioAt = now
            phase = .speaking
            let text = firstTextAt.map { String(format: "first text %.1f s, ", $0 - turnEndedAt) } ?? ""
            note(String(format: "%@first audio %.1f s after your turn ended", text, now - turnEndedAt))
        }
        return startAt
    }

    private func finishReply() {
        chatTask = nil
        speakTask = nil
        lastTurnAt = Self.now
        launchOpenLine()
        beginListening()
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
        engine.stopPlayback()
        playbackEnd = 0
        if report {
            let client = self.nexa
            Task { await client.reportInterrupt(heard: heard) }
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
            Task { @MainActor in self?.note("route: \(inputs) → \(outputs)") }
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
        if log.count > 80 { log.removeFirst(log.count - 80) }
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
