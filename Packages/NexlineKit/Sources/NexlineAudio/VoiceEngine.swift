#if os(iOS)
import AVFoundation
import NexlineCore
import os

/// One AVAudioEngine for the mic and the bot's voice.
///
/// With voice processing on, iOS cancels echo using what the player sends to the speaker as the
/// reference, so the mic stays open while the bot talks and the user can cut in (barge-in).
/// The RN app could not do this: its recorder and player were separate audio units.
///
/// The audio session is configured once (`configureSession`); `start` and every restart only
/// rebuild the engine. Re-applying the session on each restart fed a stop/restart loop in build 2.
public final class VoiceEngine {
    public struct MicBlock: Sendable {
        public let levelDB: Float
        public let durationMs: Double
    }

    /// The audio session settings the engine runs under. Spike builds compare several.
    public struct SessionSetup: @unchecked Sendable {
        public let name: String
        public let mode: AVAudioSession.Mode
        public let options: AVAudioSession.CategoryOptions
        public let preferredSampleRate: Double?

        public init(name: String, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions,
                    preferredSampleRate: Double? = nil) {
            self.name = name
            self.mode = mode
            self.options = options
            self.preferredSampleRate = preferredSampleRate
        }
    }

    public enum EngineError: LocalizedError {
        case noMicrophone
        case sessionNotConfigured

        public var errorDescription: String? {
            switch self {
            case .noMicrophone: return "no microphone input (0 Hz)"
            case .sessionNotConfigured: return "audio session not configured"
            }
        }
    }

    /// 24 kHz mono float: the format xAI streams, so a TTS stream can be scheduled as it arrives.
    public static let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    /// Called on the audio thread for every mic block. Set before `start`.
    public var onMicBlock: (@Sendable (MicBlock) -> Void)?
    /// Engine messages worth showing in a log.
    public var onEvent: (@Sendable (String) -> Void)?
    /// Rebuild the engine after a configuration change. Off while comparing setups, so a setup
    /// that can't stay up shows as stopped instead of being papered over.
    public var autoRestart = true

    public private(set) var voiceProcessing = true
    public private(set) var setup: SessionSetup?
    /// Every configuration-change notification since launch.
    public private(set) var configChanges = 0
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var started = false
    private var configObserver: NSObjectProtocol?
    private var recentRestarts: [Date] = []
    /// Bumped by every stop (and so every start), so a pending restart can tell it is stale.
    private var generation = 0
    private let log = Logger(subsystem: "com.nexlineai.voice", category: "engine")

    public init() {}

    public var isRunning: Bool { started && engine.isRunning }

    /// Stops the engine and applies `setup` to the shared session.
    public func configureSession(_ setup: SessionSetup) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: setup.mode, options: setup.options)
        if let rate = setup.preferredSampleRate { try session.setPreferredSampleRate(rate) }
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        self.setup = setup
        report("session: \(setup.name), hardware in \(Int(session.sampleRate)) Hz")
    }

    /// Starts a fresh engine. Voice processing can only change while stopped, so a toggle is a restart.
    public func start(voiceProcessing: Bool) throws {
        stop()
        guard setup != nil else { throw EngineError.sessionNotConfigured }
        self.voiceProcessing = voiceProcessing

        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(voiceProcessing)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.playbackFormat)

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw EngineError.noMicrophone }
        let sink = onMicBlock
        let rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let db = Level.rmsDB(UnsafeBufferPointer(start: channels[0], count: frames))
            sink?(MicBlock(levelDB: db, durationMs: Double(frames) / rate * 1000))
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.configurationChanged()
        }

        engine.prepare()
        try engine.start()
        started = true
        report("engine on: echo cancellation \(voiceProcessing ? "on" : "off"), mic \(Int(rate)) Hz × \(format.channelCount)")
    }

    public func stop() {
        generation += 1
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        guard started else { return }
        started = false
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Queues buffers in `playbackFormat`. `completion` runs once, when the last buffer has played
    /// or playback was stopped.
    public func play(_ buffers: [AVAudioPCMBuffer], completion: @escaping @Sendable () -> Void) {
        guard isRunning, let last = buffers.last else {
            completion()
            return
        }
        for buffer in buffers.dropLast() { player.scheduleBuffer(buffer) }
        player.scheduleBuffer(last, completionCallbackType: .dataPlayedBack) { _ in completion() }
        player.play()
    }

    public func stopPlayback() {
        player.stop()
    }

    private func configurationChanged() {
        configChanges += 1
        report("configuration change #\(configChanges), engine \(engine.isRunning ? "still running" : "stopped")")
        guard autoRestart else { return }
        // A route change (headphones, car) stops the engine. Let the route settle, then rebuild.
        scheduleRestart(after: 0.5)
    }

    private func scheduleRestart(after seconds: Double) {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == gen, !self.engine.isRunning else { return }
            let now = Date()
            self.recentRestarts = self.recentRestarts.filter { now.timeIntervalSince($0) < 60 } + [now]
            guard self.recentRestarts.count <= 5 else {
                self.report("audio keeps reconfiguring, stopped restarting (toggle echo cancellation to retry)")
                return
            }
            do {
                try self.start(voiceProcessing: self.voiceProcessing)
                self.report("engine restarted")
            } catch {
                self.report("engine restart failed: \(error.localizedDescription), retrying in 1 s")
                self.scheduleRestart(after: 1)
            }
        }
    }

    private func report(_ message: String) {
        log.info("\(message, privacy: .public)")
        onEvent?(message)
    }
}
#endif
