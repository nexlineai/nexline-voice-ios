import AVFoundation
import NexlineAudio
import NexlineCore
import os
import Speech
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
/// Silent test: the phone talks, the user stays quiet. The mic level it hears is the echo that
/// got through, and every detection is a false alarm. Talk-over test: the user cuts in and
/// playback must stop. Run both with echo cancellation on and off to compare.
@MainActor
final class SpikeModel: ObservableObject {
    enum TestKind: String {
        case silent = "silent"
        case talkOver = "talk-over"
    }

    struct RunResult: Identifiable {
        let id = UUID()
        let kind: TestKind
        let echoCancellation: Bool
        let route: String
        let echo: LevelStats
        let detections: Int
        let firstDetectionSec: Double?

        var line: String {
            let mode = "\(kind.rawValue), echo cancel \(echoCancellation ? "ON" : "OFF")"
            switch kind {
            case .silent:
                return String(format: "%@: echo mean %.0f / peak %.0f dBFS, false alarms %d [%@]",
                              mode, echo.meanDB, echo.peakDB, detections, route)
            case .talkOver:
                if let t = firstDetectionSec {
                    return String(format: "%@: stopped on your voice at %.1f s [%@]", mode, t, route)
                }
                return "\(mode): your voice was not detected [\(route)]"
            }
        }
    }

    struct LogLine: Identifiable {
        let id: Int
        let text: String
    }

    let meter = Meter()
    @Published private(set) var voiceProcessing = true
    @Published private(set) var running: TestKind?
    @Published private(set) var ready = false
    @Published private(set) var route = "–"
    @Published private(set) var runs: [RunResult] = []
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var localeReport = "checking…"

    private let engine = VoiceEngine()
    private let speech = SpeechClip()
    private var detector = BargeInDetector()
    private var clip: [AVAudioPCMBuffer] = []
    private var booted = false
    private var runID = 0
    private var runStart = Date()
    private var echo = LevelStats()
    private var detections = 0
    private var firstDetection: Double?
    private var observers: [NSObjectProtocol] = []
    private var logCount = 0
    private let logger = Logger(subsystem: "com.nexlineai.voice", category: "spike")

    private static let clipText = """
        Echo test. I will keep talking for about twenty seconds, so the microphone hears me through the speaker. \
        In the silent test, stay quiet and let me finish. Every time the app thinks you spoke is a false alarm, \
        and with echo cancellation on there should be none. In the talk-over test, say something while I am \
        still talking, and I should stop within a fraction of a second. Then switch echo cancellation off and \
        run both tests again, so we can compare. The copy button puts the results on the clipboard. \
        That is the end of the test.
        """

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
        do {
            try engine.start(voiceProcessing: voiceProcessing)
        } catch {
            note("Audio engine failed: \(error.localizedDescription)")
            return
        }
        do {
            clip = try await speech.render(Self.clipText)
            let seconds = Double(clip.reduce(0) { $0 + Int($1.frameLength) }) / VoiceEngine.playbackFormat.sampleRate
            note(String(format: "test clip ready, %.1f s", seconds))
            ready = true
        } catch {
            note("Could not render the test clip: \(error)")
        }
        await checkSpeechLocales()
    }

    func setVoiceProcessing(_ on: Bool) {
        voiceProcessing = on
        restartEngine()
    }

    func start(_ kind: TestKind) {
        guard ready, running == nil else { return }
        runID += 1
        let id = runID
        echo = LevelStats()
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
        UIPasteboard.general.string = ([head] + runs.reversed().map(\.line) + ["", localeReport])
            .joined(separator: "\n")
        note("results copied")
    }

    // MARK: - Private

    private func handle(_ block: VoiceEngine.MicBlock) {
        let playing = running != nil
        let detected = detector.process(levelDB: block.levelDB, durationMs: block.durationMs, playing: playing)
        meter.db = block.levelDB
        meter.floor = detector.noiseFloorDB
        meter.threshold = detector.threshold(playing: playing)

        guard let kind = running else { return }
        if kind == .silent { echo.add(block.levelDB) }
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
        let result = RunResult(kind: kind, echoCancellation: voiceProcessing, route: route, echo: echo,
                               detections: detections, firstDetectionSec: firstDetection)
        runs.insert(result, at: 0)
        note(result.line)
    }

    private func restartEngine() {
        stop()
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

    private func checkSpeechLocales() async {
        let wanted = ["en-US", "en-GB", "pt-PT", "pt-BR", "nl-NL"]
        let supported = Set(await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) })
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        guard !supported.isEmpty else {
            localeReport = "SpeechTranscriber: not supported on this device"
            return
        }
        localeReport = wanted.map { id in
            let state = installed.contains(id) ? "installed" : supported.contains(id) ? "downloadable" : "not supported"
            return "\(id): \(state)"
        }.joined(separator: "\n")
    }

    private func note(_ text: String) {
        logger.notice("\(text, privacy: .public)")
        logCount += 1
        log.append(LogLine(id: logCount, text: text))
        if log.count > 60 { log.removeFirst(log.count - 60) }
    }

    private static func describeRoute() -> String {
        let r = AVAudioSession.sharedInstance().currentRoute
        let inputs = r.inputs.map(\.portName).joined(separator: ", ")
        let outputs = r.outputs.map(\.portName).joined(separator: ", ")
        return "\(inputs.isEmpty ? "no mic" : inputs) → \(outputs.isEmpty ? "no output" : outputs)"
    }
}
