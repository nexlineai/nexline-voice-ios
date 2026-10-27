import AVFoundation
import Foundation
import NexlineAudio

/// Speaks with the chosen voice and falls back on its own: xAI → Deepgram → the iPhone's voice.
///
/// A voice that fails before its first audio (error, missing key, or no audio within its deadline) hands the
/// same piece to the next one and is skipped for the rest of the session, so later sentences don't pay the
/// wait again. A voice that fails after audio started is not replaced mid-sentence (that would repeat the
/// start in another voice); the piece just ends there.
@MainActor
final class VoiceChain {
    var onNote: (String) -> Void = { _ in }

    private var chain: [VoiceChoice] = VoiceChoice.xai.chain
    private var down: Set<VoiceChoice> = []

    /// Starts a session with `primary` first. Voices marked down get another chance.
    func reset(primary: VoiceChoice) {
        chain = primary.chain
        down = []
    }

    /// Starts synthesizing at once; chunks are buffered until read.
    func stream(_ text: String) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let worker = Task { @MainActor in
                let candidates = self.chain.filter { !self.down.contains($0) }
                let order = candidates.isEmpty ? [VoiceChoice.iphone] : candidates
                for (index, choice) in order.enumerated() {
                    let failure = await self.attempt(choice, text, into: continuation)
                    guard let failure, !Task.isCancelled else { break }
                    self.down.insert(choice)
                    let next = index + 1 < order.count ? "using \(order[index + 1].name)" : "nothing left to speak with"
                    self.onNote("voice: \(choice.name) failed (\(failure)), \(next)")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    /// Plays one voice into `continuation`. Returns why it failed before any audio, or nil once it spoke.
    private func attempt(_ choice: VoiceChoice, _ text: String,
                         into continuation: AsyncThrowingStream<[Float], Error>.Continuation) async -> String? {
        let state = AttemptState()
        let source = Self.source(choice, text)
        let run = Task { @MainActor () -> String? in
            do {
                for try await chunk in source {
                    state.gotAudio = true
                    continuation.yield(chunk)
                }
            } catch {
                guard state.gotAudio else { return error.localizedDescription }
                self.onNote("voice: \(choice.name) stopped mid-sentence (\(error.localizedDescription))")
                return nil
            }
            return state.gotAudio ? nil : "no audio"
        }
        let limit = Self.deadline(choice)
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled, !state.gotAudio else { return }
            state.timedOut = true
            run.cancel()
        }
        let failure = await withTaskCancellationHandler {
            await run.value
        } onCancel: {
            run.cancel()
        }
        watchdog.cancel()
        if state.timedOut && !state.gotAudio { return String(format: "no audio within %.0f s", limit) }
        return failure
    }

    /// How long a voice may take to its first audio. xAI is ~1.1 s; Deepgram measured 2.5 s and more on the
    /// kiosk (16 Oct); the iPhone voice is on-device but slow to load the first time.
    private static func deadline(_ choice: VoiceChoice) -> Double {
        switch choice {
        case .xai: return 4
        case .deepgram: return 6
        case .iphone: return 10
        }
    }

    /// One voice on its own, without fallback (Check connection tests each one).
    static func source(_ choice: VoiceChoice, _ text: String) -> AsyncThrowingStream<[Float], Error> {
        switch choice {
        case .xai: return XAIVoice.stream(text)
        case .deepgram: return DeepgramVoice.stream(text)
        case .iphone: return DeviceVoice.stream(text)
        }
    }
}

@MainActor
private final class AttemptState {
    var gotAudio = false
    var timedOut = false
}

/// The iPhone's built-in voice: no network and no key, so it is the last fallback.
enum DeviceVoice {
    static func stream(_ text: String) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    // One synthesizer per piece: the next piece is prepared while the current one plays.
                    let clip = SpeechClip()
                    for buffer in try await clip.render(text) {
                        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { continue }
                        continuation.yield(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
}
