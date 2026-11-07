import AVFoundation
import SwiftUI

@main
struct FilmHubApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Keep posters on disk between launches (P3: no re-downloading).
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024,
                                   diskCapacity: 300 * 1024 * 1024)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .task { await app.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.didBecomeActive() }
        }
    }
}
