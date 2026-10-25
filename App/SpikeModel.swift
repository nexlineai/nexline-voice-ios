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
    @Published var floor: Float = -60
    @Published var threshold: Float = -45
}

/// Audio spike: proves echo cancellation + barge-in on the phone with no network and no keys.
///
/// Check audio: tries each session setup with echo cancellation on and keeps the first whose engine
/// is running with live mic data 3 s after starting (in builds 1-3 it stopped itself right after
/// every start, and the engine now resumes after that). Silent test: the
/// phone talks, the user stays quiet. The mic level it hears is the echo that got through, and every
/// detection is a false alarm. Talk-over test: the user cuts in and playback must stop.
@MainActor
final class SpikeModel: ObservableObject {
    enum TestKind: String {
        case silent = "silent"
        case talkOver = "talk-over"
    }

    enum ClipError: Error {
        case missing
        case wrongFormat(String)
        case noBuffer
    }

    struct CheckResult: Identifiable {
        let id = UUID()
        let setup: String
        let error: String?
        let running: Bool
        let configChanges: Int
        let blocks: Int
        let meanDB: Float

        /// Running alone is not enough: a dead tap would read as a perfect -100 again.
        var passed: Bool { error == nil && running && blocks > 0 && meanDB > Level.silenceDB }

        var line: String {
            if let error { return "\(setup): FAIL, \(error)" }
            return String(format: "%@: %@, engine %@, %d config changes, %d mic blocks in the last 2 s, mean %.0f dBFS",
                          setup, passed ? "OK" : "FAIL", running ? "running" : "stopped", configChanges, blocks, meanDB)
        }
    }

    struct RunResult: Identifiable {
        let id = UUID()
        let kind: TestKind
        let echoCancellation: Bool
        let setup: String
        let route: String
        /// Every mic block of the run. For the silent test this is the echo that got through.
        let levels: LevelStats
        let thresholdDB: Float
        let seconds: Double
        let detections: Int
        let firstDetectionSec: Double?

        var line: String {
            let mode = "\(kind.rawValue), echo cancel \(echoCancellation ? "ON" : "OFF"), setup \(setup)"
            // No blocks at all means a dead engine, which would otherwise read as a perfect -100 / 0.
            guard levels.count > 0 else {
                return String(format: "%@: NO MIC DATA after %.1f s, audio engine not running [%@]", mode, seconds, route)
            }
            switch kind {
            case .silent:
                return String(format: "%@: %.1f s, echo mean %.0f / peak %.0f dBFS, false alarms %d [%@]",
                              mode, seconds, levels.meanDB, levels.peakDB, detections, route)
            case .talkOver:
                if let t = firstDetectionSec {
                    return String(format: "%@: stopped on your voice at %.1f s [%@]", mode, t, route)
                }
                return String(format: "%@: your voice was not detected in %.1f s, mic peak %.0f dBFS vs threshold %.0f [%@]",
                              mode, seconds, levels.peakDB, thresholdDB, route)
            }
        }
    }

    struct LogLine: Identifiable {
        let id: Int
        let text: String
    }

    /// A is what builds 1-2 used. Each later setup changes one thing, so a pass says what mattered.
    static let setups: [VoiceEngine.SessionSetup] = [
        .init(name: "A default mode + A2DP", mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP]),
        .init(name: "B default mode, speaker only", mode: .default, options: [.defaultToSpeaker]),
        .init(name: "C voiceChat mode, speaker only", mode: .voiceChat, options: [.defaultToSpeaker]),
        // Last, because a preferred rate stays on the session for the setups after it.
        .init(name: "D voiceChat mode, speaker only, 48 kHz", mode: .voiceChat, options: [.defaultToSpeaker],
              preferredSampleRate: 48_000),
    ]

    let meter = Meter()
    @Published private(set) var voiceProcessing = true
    @Published private(set) var running: TestKind?
    @Published private(set) var ready = false
    @Published private(set) var checking = false
    @Published private(set) var checks: [CheckResult] = []
    @Published private(set) var setupName: String?
    @Published private(set) var route = "–"
    @Published private(set) var runs: [RunResult] = []
    @Published private(set) var log: [LogLine] = []

    private let engine = VoiceEngine()
    private var detector = BargeInDetector()
    private var clip: [AVAudioPCMBuffer] = []
    private var booted = false
    private var runID = 0
    private var runStart = Date()
    private var levels = LevelStats()
    private var detections = 0
    private var firstDetection: Double?
    private var measuring = false
    private var checkBlocks = 0
    private var checkLevels = LevelStats()
    private var observers: [NSObjectProtocol] = []
    private var logCount = 0
    private let logger = Logger(subsystem: "com.nexlineai.voice", category: "spike")

    var canTest: Bool { ready && setupName != nil && running == nil && !checking }

    func boot() async {
        guard !booted else { return }
        booted = true
        observeSession()
        route = Self.describeRoute()

        guard await AVAudioApplication.requestRecordPermission() else {
            note("No microphone access. Settings › Nexline Voice › Microphone.")
            return
        }
        engine.onMicBlock = { [weak self] block in
            Task { @MainActor in self?.handle(block) }
        }
        engine.onEvent = { [weak self] message in
            Task { @MainActor in self?.note(message) }
        }
        // A bundled recording, not on-device speech: the synthesizer added its own audio session
        // to the process, one more thing that could reconfigure the engine.
        do {
            let buffer = try Self.loadClip()
            clip = [buffer]
            note(String(format: "test clip ready, %.1f s", Double(buffer.frameLength) / buffer.format.sampleRate))
            ready = true
        } catch {
            note("Could not load the test clip: \(error)")
        }
    }

    func checkAudio() async {
        guard ready, !checking, running == nil else { return }
        checking = true
        checks = []
        setupName = nil
        for setup in Self.setups {
            checks.append(await check(setup))
        }
        engine.stop()
        checking = false

        guard let index = checks.firstIndex(where: \.passed) else {
            note("no setup kept echo cancellation running")
            return
        }
        let setup = Self.setups[index]
        do {
            try engine.configureSession(setup)
            voiceProcessing = true
            try engine.start(voiceProcessing: true)
            detector = BargeInDetector()
            setupName = setup.name
            note("using \(setup.name)")
        } catch {
            note("could not start \(setup.name): \(error.localizedDescription)")
        }
    }

    func setVoiceProcessing(_ on: Bool) {
        voiceProcessing = on
        restartEngine()
    }

    func start(_ kind: TestKind) {
        guard canTest else { return }
        guard engine.isRunning else {
            note("audio engine is off: toggle echo cancellation to restart it")
            return
        }
        runID += 1
        let id = runID
        levels = LevelStats()
        detections = 0
        firstDetection = nil
        detector = BargeInDetector(initialFloorDB: detector.noiseFloorDB)
        running = kind
        runStart = Date()
        note("\(kind.rawValue) test, echo cancellation \(voiceProcessing ? "on" : "off")")
        engine.play(clip) { [weak self] in
            Task { @MainActor in self?.finishRun(id) }
        }
    }

    func stop() {
        guard running != nil else { return }
        engine.stopPlayback()
        finishRun(runID)
    }

    func copyResults() {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let head = "Nexline Voice audio spike, build \(build), iOS \(UIDevice.current.systemVersion)"
        // The log rides along, so a failed run can be diagnosed without a USB cable.
        let lines = [head, "", "Check audio:"] + checks.map(\.line) + [""] + runs.reversed().map(\.line)
            + ["", "Log:"] + log.suffix(30).map(\.text)
        UIPasteboard.general.string = lines.joined(separator: "\n")
        note("results copied")
    }

    // MARK: - Private

    /// Starts `setup` with echo cancellation on, waits 3 s (time to stop and resume), then measures 2 s.
    private func check(_ setup: VoiceEngine.SessionSetup) async -> CheckResult {
        let before = engine.configChanges
        do {
            try engine.configureSession(setup)
            try engine.start(voiceProcessing: true)
        } catch {
            let result = CheckResult(setup: setup.name, error: error.localizedDescription, running: false,
                                     configChanges: engine.configChanges - before, blocks: 0, meanDB: Level.silenceDB)
            note(result.line)
            return result
        }
        try? await Task.sleep(for: .seconds(3))
        checkBlocks = 0
        checkLevels = LevelStats()
        measuring = true
        try? await Task.sleep(for: .seconds(2))
        measuring = false
        let result = CheckResult(setup: setup.name, error: nil, running: engine.isRunning,
                                 configChanges: engine.configChanges - before, blocks: checkBlocks,
                                 meanDB: checkLevels.meanDB)
        note(result.line)
        engine.stop()
        return result
    }

    private func handle(_ block: VoiceEngine.MicBlock) {
        if measuring {
            checkBlocks += 1
            checkLevels.add(block.levelDB)
        }
        let playing = running != nil
        let detected = detector.process(levelDB: block.levelDB, durationMs: block.durationMs, playing: playing)
        meter.db = block.levelDB
        meter.floor = detector.noiseFloorDB
        meter.threshold = detector.threshold(playing: playing)

        guard let kind = running else { return }
        levels.add(block.levelDB)
        guard detected else { return }

        detections += 1
        let t = Date().timeIntervalSince(runStart)
        if firstDetection == nil { firstDetection = t }
        note(String(format: "voice detected at %.1f s (%.0f dBFS)", t, block.levelDB))
        if kind == .talkOver {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            engine.stopPlayback()
            finishRun(runID)
        }
    }

    private func finishRun(_ id: Int) {
        guard id == runID, let kind = running else { return }
        running = nil
        let result = RunResult(kind: kind, echoCancellation: voiceProcessing, setup: String(setupName?.prefix(1) ?? "?"),
                               route: route, levels: levels, thresholdDB: detector.threshold(playing: true),
                               seconds: Date().timeIntervalSince(runStart),
                               detections: detections, firstDetectionSec: firstDetection)
        runs.insert(result, at: 0)
        note(result.line)
    }

    private func restartEngine() {
        stop()
        guard setupName != nil else { return }
        do {
            try engine.start(voiceProcessing: voiceProcessing)
            detector = BargeInDetector()
        } catch {
            note("Audio engine failed: \(error.localizedDescription)")
        }
    }

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.routeChanged() }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw == AVAudioSession.InterruptionType.began.rawValue
            Task { @MainActor in self?.interrupted(began: began) }
        })
    }

    private func routeChanged() {
        let now = Self.describeRoute()
        guard now != route else { return }
        route = now
        note("route: \(now)")
    }

    private func interrupted(began: Bool) {
        if began {
            note("interrupted (call or alarm)")
            stop()
        } else {
            note("interruption over, restarting audio")
            restartEngine()
        }
    }

    private func note(_ text: String) {
        logger.notice("\(text, privacy: .public)")
        logCount += 1
        log.append(LogLine(id: logCount, text: text))
        if log.count > 60 { log.removeFirst(log.count - 60) }
    }

    /// `test-clip.wav`: espeak-ng, 24 kHz mono, so it plays in `VoiceEngine.playbackFormat` as is.
    private static func loadClip() throws -> AVAudioPCMBuffer {
        guard let url = Bundle.main.url(forResource: "test-clip", withExtension: "wav") else { throw ClipError.missing }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate == VoiceEngine.playbackFormat.sampleRate,
              format.channelCount == VoiceEngine.playbackFormat.channelCount else {
            throw ClipError.wrongFormat("\(format)")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ClipError.noBuffer
        }
        try file.read(into: buffer)
        return buffer
    }

    private static func describeRoute() -> String {
        let r = AVAudioSession.sharedInstance().currentRoute
        let inputs = r.inputs.map(\.portName).joined(separator: ", ")
        let outputs = r.outputs.map(\.portName).joined(separator: ", ")
        return "\(inputs.isEmpty ? "no mic" : inputs) → \(outputs.isEmpty ? "no output" : outputs)"
    }
}
