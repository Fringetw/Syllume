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
            if let initialMode = ProcessInfo.processInfo.environment["SYLLUME_TEST_INITIAL_DISPLAY_MODE"],
               let mode = LyricDisplayMode(rawValue: initialMode) {
                UserDefaults.standard.set(mode.rawValue, forKey: "Folia.LyricDisplayMode")
            }
        }
        #endif
        let library = LocalLibrary()
        _library = State(initialValue: library)
        _player = State(initialValue: PlaybackModel(library: library))
    }

    var body: some Scene {
        WindowGroup {
            libraryView
                .preferredColorScheme(.dark)
                .tint(SyllumePalette.accent)
                .buttonStyle(SyllumePressStyle())
        }
    }

    @ViewBuilder private var libraryView: some View {
        let content = LibraryScreen(library: library, player: player, navidrome: navidrome)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--accessibility-text-fixture") {
            content.dynamicTypeSize(.accessibility3)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
