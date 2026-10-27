import NexlineCore
import UIKit

/// Opens apps and links from Nexa's replies. The app's own scheme first so the native app opens; when nothing
/// handles it (the app isn't installed), the web address. `open` reports that without `canOpenURL`, so no
/// scheme list is needed in Info.plist.
@MainActor
enum AppLauncher {
    /// Settings toggle: open apps by themselves in voice mode (the RN app's `appLaunch`, on by default).
    nonisolated static let settingKey = "appLaunch"

    static func open(_ link: AppLink) {
        guard let app = link.appURL else {
            if let web = link.webURL { UIApplication.shared.open(web) }
            return
        }
        UIApplication.shared.open(app) { opened in
            guard !opened, let web = link.webURL else { return }
            UIApplication.shared.open(web)
        }
    }

    static func open(_ url: URL) {
        UIApplication.shared.open(url)
    }
}
