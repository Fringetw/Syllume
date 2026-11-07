import SwiftUI

// One saved display choice is shared by local and YouTube playback.
enum LyricDisplayMode: String, CaseIterable, Identifiable {
    case sonnet, lumiere, lyrics, cover
    var id: String { rawValue }
    var title: String {
        switch self { case .sonnet: "商籟"; case .lumiere: "繪光"; case .lyrics: "歌詞"; case .cover: "封面" }
    }
}

struct FoliaPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.95 : 1)
            .opacity(configuration.isPressed && enabled ? 0.72 : enabled ? 1 : 0.4)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
            .sensoryFeedback(.selection, trigger: configuration.isPressed) { _, pressed in pressed && enabled }
    }
}
