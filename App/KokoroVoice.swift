import Foundation
import NexlineCore

/// Kokoro on Nexa's Jetson, through serve.py with Nexa's token (`/phone/speak`), in the kiosk's Kokoro voice.
/// Nexa only. One request per piece: Kokoro makes the whole piece before any of it plays. Never started from
/// here (Zé keeps Kokoro off to save the Jetson's memory); while it is off this fails at once with that reason.
enum KokoroVoice {
    /// Starts synthesizing at once; chunks are buffered until read.
    static func stream(_ text: String) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let spoken = DeepgramVoice.withoutVoiceTags(text)
            guard !spoken.isEmpty else {
                continuation.finish()
                return
            }
            let worker = Task {
                do {
                    let pcm = try await NexaClient.shared.speak(spoken)
                    var decoder = PCM16Decoder()
                    let samples = decoder.decode(pcm)
                    // Half a second at a time, like the voices that stream.
                    var start = 0
                    while start < samples.count {
                        let end = min(start + 12_000, samples.count)
                        continuation.yield(Array(samples[start..<end]))
                        start = end
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
