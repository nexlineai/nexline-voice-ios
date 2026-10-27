import SwiftUI

@main
struct NexlineVoiceApp: App {
    var body: some Scene {
        WindowGroup {
            TalkView()
                .preferredColorScheme(.dark)
        }
    }
}
