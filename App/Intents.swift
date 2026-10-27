import AppIntents

extension Bot: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Agent" }

    static var caseDisplayRepresentations: [Bot: DisplayRepresentation] {
        [.nexa: "Nexa", .carapava: "Cara Pava", .mamadona: "Mamadona"]
    }
}

/// "Talk to Nexa": opens straight into voice mode, from Siri, the Action button or a Shortcut (hands-free in
/// the car, where the RN app used the `nexlinevoice://voice/nexa` link).
struct TalkIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to an agent"
    static let description = IntentDescription("Opens voice mode, ready to listen.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Agent", default: .nexa)
    var bot: Bot

    @MainActor
    func perform() async throws -> some IntentResult {
        Router.shared.voice = bot
        return .result()
    }
}

struct NexlineShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkIntent(),
            phrases: [
                "Talk to \(\.$bot) in \(.applicationName)",
                "Start \(.applicationName)",
                "\(.applicationName) voice",
            ],
            shortTitle: "Talk",
            systemImageName: "waveform")
    }
}
