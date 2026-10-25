#if os(iOS)
import AVFoundation
import NexlineCore
import os

/// One AVAudioEngine for the mic and the bot's voice.
///
/// With voice processing on, iOS cancels echo using what the player sends to the speaker as the
/// reference, so the mic stays open while the bot talks and the user can cut in (barge-in).
/// The RN app could not do this: its recorder and player were separate audio units.
public final class VoiceEngine {
    public struct MicBlock: Sendable {
        public let levelDB: Float
        public let durationMs: Double
    }

    public enum EngineError: LocalizedError {
        case noMicrophone

        public var errorDescription: String? {
            switch self {
            case .noMicrophone: return "no microphone input (0 Hz)"
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

    public private(set) var voiceProcessing = true
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var started = false
    private var configObserver: NSObjectProtocol?
    private var recentRestarts: [Date] = []
    /// Bumped by every stop (and so every start), so a pending restart retry can tell it is stale.
    private var generation = 0
    private let log = Logger(subsystem: "com.nexlineai.voice", category: "engine")

    public init() {}

    public var isRunning: Bool { started && engine.isRunning }

    /// Starts a fresh engine. Voice processing can only change while stopped, so a toggle is a restart.
    public func start(voiceProcessing: Bool) throws {
        stop()
        self.voiceProcessing = voiceProcessing

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)

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

        // A route change (headphones, car) stops the engine; bring it back with the same settings.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
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

    private func restartAfterConfigurationChange() {
        // Enabling voice processing or re-activating the session can post this notification itself.
        // If the engine still runs there is nothing to do, and the cap stops a restart loop.
        guard !engine.isRunning else { return }
        let now = Date()
        recentRestarts = recentRestarts.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard recentRestarts.count <= 5 else {
            report("audio keeps reconfiguring, stopped restarting (toggle echo cancellation to retry)")
            return
        }
        do {
            try start(voiceProcessing: voiceProcessing)
            report("audio route changed, engine restarted")
        } catch {
            // Mid-reconfiguration the mic can read 0 Hz for a moment. The failed start already
            // dropped the observer, so nothing else would bring the engine back: retry shortly.
            report("engine restart failed: \(error.localizedDescription), retrying")
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.restartAfterConfigurationChange()
            }
        }
    }

    private func report(_ message: String) {
        log.info("\(message, privacy: .public)")
        onEvent?(message)
    }
}
#endif
