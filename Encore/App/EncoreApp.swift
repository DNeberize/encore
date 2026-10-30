import SwiftUI
import UIKit

@main
struct EncoreApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = BrowserStore()

    var body: some Scene {
        WindowGroup {
            BrowserView()
                .environmentObject(store)
                .tint(.encoreAccent)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Sets up the audio session and lock-screen controls before any page plays.
        _ = NowPlayingCenter.shared
        application.beginReceivingRemoteControlEvents()
        return true
    }
}

extension Color {
    /// Electric blue, matching the app icon.
    static let encoreAccent = Color(red: 0.16, green: 0.56, blue: 1.0)
    static let encoreAccentDeep = Color(red: 0.31, green: 0.27, blue: 0.90)
}
