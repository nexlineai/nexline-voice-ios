import Foundation

/// Who speaks Nexa's replies. The chosen one goes first; when it fails, the next ones in `fallbacks` take over.
enum VoiceChoice: String, CaseIterable, Identifiable {
    case xai, deepgram, iphone

    static let storageKey = "voice"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .xai: return "xAI (Ara)"
        case .deepgram: return "Deepgram (Thalia)"
        case .iphone: return "iPhone voice"
        }
    }

    /// Short name for the log.
    var name: String {
        switch self {
        case .xai: return "xAI"
        case .deepgram: return "Deepgram"
        case .iphone: return "iPhone"
        }
    }

    /// The chosen voice first, then the others in fallback order. The iPhone voice needs no network, so it is
    /// last unless chosen.
    var chain: [VoiceChoice] {
        [self] + [VoiceChoice.xai, .deepgram, .iphone].filter { $0 != self }
    }

    static var current: VoiceChoice {
        UserDefaults.standard.string(forKey: storageKey).flatMap { VoiceChoice(rawValue: $0) } ?? .xai
    }
}

/// Who turns the user's speech into text. Deepgram falls back to the iPhone's recognizer.
enum EarsChoice: String, CaseIterable, Identifiable {
    case deepgram, iphone

    static let storageKey = "ears"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .deepgram: return "Deepgram (Nova-3)"
        case .iphone: return "iPhone (on device)"
        }
    }

    static var current: EarsChoice {
        UserDefaults.standard.string(forKey: storageKey).flatMap { EarsChoice(rawValue: $0) } ?? .deepgram
    }
}
