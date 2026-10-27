import Foundation
import SwiftUI

/// The three agents. Nexa goes through serve.py on the Jetson, so the phone shares her conversation with the
/// kiosk. Carapava and Mamadona are Hermes gateways spoken to directly (OpenAI streaming, their own key, one
/// gateway session per chat).
enum Bot: String, CaseIterable, Identifiable, Codable, Hashable {
    case nexa, carapava, mamadona

    var id: String { rawValue }

    var name: String {
        switch self {
        case .nexa: return "Nexa"
        case .carapava: return "Cara Pava"
        case .mamadona: return "Mamadona"
        }
    }

    var tagline: String {
        switch self {
        case .nexa: return "Jetson home agent"
        case .carapava: return "Streamline · VPS agent"
        case .mamadona: return "Personal AI assistant"
        }
    }

    var accent: Color {
        switch self {
        case .nexa: return Color(hex: 0xF0C040)
        case .carapava: return Color(hex: 0x19E0D4)
        case .mamadona: return Color(hex: 0xC861FF)
        }
    }

    var avatar: String { "avatar-\(rawValue)" }

    /// The gateway for Carapava and Mamadona; Nexa uses serve.py (`NexaClient`).
    var endpoint: URL? {
        switch self {
        case .nexa: return nil
        case .carapava: return URL(string: "https://agentapi.nexline.ai/v1/chat/completions")
        case .mamadona: return URL(string: "https://agentapi.streamlinemedia.org/v1/chat/completions")
        }
    }

    var defaultModel: String {
        switch self {
        case .nexa: return "default"
        case .carapava: return "carapava"
        case .mamadona: return "mamadona"
        }
    }

    var key: Keychain.Key? {
        switch self {
        case .nexa: return nil
        case .carapava: return .carapavaKey
        case .mamadona: return .mamadonaKey
        }
    }

    /// Her xAI voice (Zé, 27 Oct: ara, leo, eve).
    var defaultXAIVoice: String {
        switch self {
        case .nexa: return "ara"
        case .carapava: return "leo"
        case .mamadona: return "eve"
        }
    }

    var defaultDeepgramVoice: String {
        switch self {
        case .nexa: return "aura-2-thalia-en"
        case .carapava: return "aura-2-orion-en"
        case .mamadona: return "aura-2-luna-en"
        }
    }

    /// What standby listens for at the start of a sentence, including the usual mishearings of "Nexa".
    var wakeNames: [String] {
        switch self {
        case .nexa: return ["nexa", "nexo", "necza", "nexta", "next", "nexus", "nexi", "neksa", "mixer", "mixa", "nexar"]
        case .carapava: return ["carapava", "cara pava", "cara"]
        case .mamadona: return ["mamadona", "mama dona", "mama"]
        }
    }
}

/// How one bot speaks: the engine first in line (the others are the fallback) and its voice on each engine.
/// Nexa's engine keeps the original "voice" key, so the choice made before bots existed carries over.
struct BotVoice: Equatable {
    var engine: VoiceChoice
    var xai: String
    var deepgram: String

    static let xaiVoices = ["ara", "eve", "luna", "leo", "rex", "sal"]
    static let deepgramVoices = ["aura-2-thalia-en", "aura-2-luna-en", "aura-2-asteria-en", "aura-2-andromeda-en",
                                 "aura-2-helena-en", "aura-2-apollo-en", "aura-2-orion-en", "aura-2-arcas-en"]

    static func engineKey(_ bot: Bot) -> String { bot == .nexa ? VoiceChoice.storageKey : "voice.\(bot.rawValue)" }
    static func xaiKey(_ bot: Bot) -> String { "voice.xai.\(bot.rawValue)" }
    static func deepgramKey(_ bot: Bot) -> String { "voice.deepgram.\(bot.rawValue)" }

    static func current(_ bot: Bot) -> BotVoice {
        let defaults = UserDefaults.standard
        return BotVoice(
            engine: defaults.string(forKey: engineKey(bot)).flatMap { VoiceChoice(rawValue: $0) } ?? .xai,
            xai: defaults.string(forKey: xaiKey(bot)) ?? bot.defaultXAIVoice,
            deepgram: defaults.string(forKey: deepgramKey(bot)) ?? bot.defaultDeepgramVoice)
    }

    /// "Thalia" from "aura-2-thalia-en".
    static func deepgramLabel(_ id: String) -> String {
        let parts = id.split(separator: "-")
        guard parts.count >= 3 else { return id }
        return parts[parts.count - 2].capitalized
    }
}

/// Zé's switches (UserDefaults). Defaults follow the RN app, except standby, which starts off so voice mode
/// behaves exactly like the build tested on 27 Oct until he turns it on.
enum Prefs {
    static let bargeIn = "bargeIn"
    static let autoplayMedia = "autoplayMedia"
    static let standby = "standbyByDefault"
    static let conversationWindow = "conversationWindowMin"
    static let speechLanguage = "speechLanguage"

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static var conversationWindowMinutes: Int {
        UserDefaults.standard.object(forKey: conversationWindow) as? Int ?? 3
    }

    static func modelKey(_ bot: Bot) -> String { "model.\(bot.rawValue)" }

    static func model(_ bot: Bot) -> String {
        let override = UserDefaults.standard.string(forKey: modelKey(bot))?.trimmingCharacters(in: .whitespaces) ?? ""
        return override.isEmpty ? bot.defaultModel : override
    }
}

/// The language Zé speaks to the app, one at a time (Deepgram's "multi" turned short English into Spanish).
enum SpeechLanguage: String, CaseIterable, Identifiable {
    case en, pt, nl

    var id: String { rawValue }
    var label: String {
        switch self {
        case .en: return "English"
        case .pt: return "Português"
        case .nl: return "Nederlands"
        }
    }

    var locale: String {
        switch self {
        case .en: return "en-US"
        case .pt: return "pt-PT"
        case .nl: return "nl-NL"
        }
    }

    static var current: SpeechLanguage {
        UserDefaults.standard.string(forKey: Prefs.speechLanguage).flatMap { SpeechLanguage(rawValue: $0) } ?? .en
    }
}
