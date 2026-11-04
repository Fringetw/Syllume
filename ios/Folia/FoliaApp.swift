import SwiftUI

// Creates one native playback session for the app.
@main @MainActor
struct FoliaApp: App {
    @State private var library: LocalLibrary
    @State private var player: PlaybackModel
    @State private var navidrome = NavidromeConnection()

    init() {
        let library = LocalLibrary()
        _library = State(initialValue: library)
        _player = State(initialValue: PlaybackModel(library: library))
    }

    var body: some Scene {
        WindowGroup {
            LibraryScreen(library: library, player: player, navidrome: navidrome)
                .preferredColorScheme(.dark)
                .tint(FoliaPalette.accent)
        }
    }
}
