import SwiftUI
import UIKit

@main
struct EncoreApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = BrowserStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            BrowserView()
                .environmentObject(store)
                .tint(.encoreAccent)
                .onChange(of: scenePhase) { phase in
                    store.scenePhaseChanged(phase)
                }
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
    static let encoreAccent = Color(red: 1.0, green: 0.22, blue: 0.37)
}
