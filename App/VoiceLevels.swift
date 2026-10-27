import Foundation
import NexlineCore

/// What the voice screen animates with: her voice as it actually leaves the speaker, and the user's mic.
///
/// Her audio is queued ahead of playback, so each chunk is cut into ~50 ms windows stamped with the uptime they
/// will be heard at; the screen samples the window under "now" every frame. Nothing here touches the engine.
@MainActor
final class VoiceLevels {
    /// The echo-cancelled mic level, updated ~47 times a second.
    var micDB: Float = Level.silenceDB

    private struct Window {
        let start: Double
        let end: Double
        let level: Float
    }

    private var windows: [Window] = []

    func addSpeech(_ samples: [Float], start: Double, seconds: Double) {
        guard !samples.isEmpty, seconds > 0 else { return }
        let rate = Double(samples.count) / seconds
        let size = max(1, Int(rate * 0.05))
        var index = 0
        while index < samples.count {
            let end = min(index + size, samples.count)
            var sum: Float = 0
            for i in index..<end { sum += samples[i] * samples[i] }
            let rms = (sum / Float(end - index)).squareRoot()
            let db = 20 * log10(max(rms, 1e-6))
            let level = min(1, max(0, (db + 48) / 36))
            windows.append(Window(start: start + Double(index) / rate, end: start + Double(end) / rate, level: level))
            index = end
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let firstLive = windows.firstIndex(where: { $0.end > now - 1 }), firstLive > 0 {
            windows.removeFirst(firstLive)
        }
    }

    func clearSpeech() {
        windows.removeAll()
    }

    /// 0…1, her voice at uptime `t` (0 when she is silent).
    func speech(at t: Double) -> Float {
        for window in windows where window.start <= t && t < window.end {
            return window.level
        }
        return 0
    }

    /// 0…1, the user's voice.
    var mic: Float {
        min(1, max(0, (micDB + 62) / 40))
    }
}
