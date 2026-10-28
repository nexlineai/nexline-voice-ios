import AVFoundation
import Foundation
import Speech

/// On-device speech recognition (iOS 26 SpeechAnalyzer + SpeechTranscriber), fed with the voice engine's
/// echo-cancelled mic buffers, so the bot's own voice mostly doesn't reach it.
///
/// `feed` runs on the audio thread; everything else on the main actor.
final class Listener: @unchecked Sendable {
    enum ListenerError: LocalizedError {
        case unsupportedLocale(String)
        case noAudioFormat

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let id): return "speech recognition doesn't support \(id)"
            case .noAudioFormat: return "speech recognition gave no audio format"
            }
        }
    }

    /// What the audio thread needs, swapped under the lock.
    private struct Feed {
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let format: AVAudioFormat
    }

    private let lock = NSLock()
    private var feed: Feed?
    /// Audio thread only.
    private var converter: AVAudioConverter?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?

    /// Starts recognition. `onResult(text, isFinal)` is called on the main actor.
    @MainActor
    func start(localeID: String, onResult: @escaping @MainActor (String, Bool) -> Void,
               onEvent: @escaping @MainActor (String) -> Void) async throws {
        await stop()

        let status = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
        }
        if status != .authorized { onEvent("speech permission: \(status.rawValue) (trying anyway)") }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw ListenerError.unsupportedLocale(localeID)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onEvent("downloading speech model for \(locale.identifier)…")
            try await install.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ListenerError.noAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber], options: nil)
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputs)
        self.analyzer = analyzer

        resultsTask = Task { @MainActor in
            do {
                for try await result in transcriber.results {
                    onResult(String(result.text.characters), result.isFinal)
                }
            } catch {
                onEvent("speech recognition stopped: \(error.localizedDescription)")
            }
        }

        lock.lock()
        feed = Feed(continuation: continuation, format: format)
        lock.unlock()
        onEvent("listening in \(locale.identifier), \(Int(format.sampleRate)) Hz")
    }

    @MainActor
    func stop() async {
        lock.lock()
        let old = feed
        feed = nil
        lock.unlock()
        old?.continuation.finish()
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            await analyzer.cancelAndFinishNow()
            self.analyzer = nil
        }
    }

    /// Audio thread: converts a mic buffer to the recognizer's format and hands it over.
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = feed
        lock.unlock()
        guard let current else { return }

        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != current.format {
            converter = AVAudioConverter(from: buffer.format, to: current.format)
            converter?.primeMethod = .none
        }
        guard let converter else { return }

        let ratio = current.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: current.format, frameCapacity: capacity) else { return }
        let given = Flag()
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if given.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given.value = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return }
        current.continuation.yield(AnalyzerInput(buffer: out))
    }
}

/// A one-shot flag the converter's input block can set (the block may be `@Sendable`). Also used by `TurnRecorder`.
final class Flag: @unchecked Sendable {
    var value = false
}
