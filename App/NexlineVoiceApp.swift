import SwiftUI

@main
struct NexlineVoiceApp: App {
    /// One conversation engine for the whole app: two voice-processing engines would fight over the session.
    @StateObject private var talk = TalkModel()
    @ObservedObject private var router = Router.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(talk)
                .environmentObject(router)
                .preferredColorScheme(.dark)
                .tint(Theme.teal)
                .onOpenURL { router.open($0) }
                .onAppear { InlineAudio.shared.talk = talk }
        }
    }
}

enum Route: Hashable {
    case chat(Bot)
    case devices
}

/// Where the app is: the screen stack, and voice mode on top of it. Siri, the Action button and links
/// (`nexlinevoice://voice/nexa`, the RN app's scheme) land here too.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()

    @Published var path: [Route] = []
    @Published var voice: Bot?
    @Published var settings = false

    func open(_ url: URL) {
        guard url.scheme == "nexlinevoice" else { return }
        let name = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let bot = Bot(rawValue: name.lowercased()) ?? .nexa
        switch url.host {
        case "voice":
            voice = bot
        case "chat":
            voice = nil
            path = [.chat(bot)]
        case "home":
            voice = nil
            path = [.devices]
        default:
            break
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var talk: TalkModel
    @EnvironmentObject private var router: Router
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $router.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .chat(let bot): ChatView(bot: bot)
                    case .devices: DevicesView()
                    }
                }
        }
        .fullScreenCover(item: $router.voice) { bot in
            VoiceModeView(bot: bot)
                .environmentObject(talk)
                .environmentObject(router)
        }
        .sheet(isPresented: $router.settings, onDismiss: { talk.keysChanged() }) {
            SettingsView()
                .environmentObject(talk)
        }
        .onAppear { talk.startSync() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { talk.startSync() } else { talk.stopSync() }
        }
    }
}
