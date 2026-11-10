import SwiftUI

// Creates one native playback session for the app.
@main @MainActor
struct SyllumeApp: App {
    @State private var library: LocalLibrary
    @State private var player: PlaybackModel
    @State private var navidrome = NavidromeConnection()

    init() {
        DiagnosticsEvents.shared.beganInitialization()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--presentation-reset") {
            UserDefaults.standard.removeObject(forKey: "Folia.LyricDisplayMode")
            UserDefaults.standard.removeObject(forKey: "Folia.EnergySavingAnimation")
        }
        #endif
        let library = LocalLibrary()
        _library = State(initialValue: library)
        _player = State(initialValue: PlaybackModel(library: library))
    }

    var body: some Scene {
        WindowGroup {
            LibraryScreen(library: library, player: player, navidrome: navidrome)
                .preferredColorScheme(.dark)
                .tint(SyllumePalette.accent)
                .buttonStyle(SyllumePressStyle())
        }
    }
}
