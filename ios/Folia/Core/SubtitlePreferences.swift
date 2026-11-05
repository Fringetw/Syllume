import Foundation

struct SubtitlePreferences: Codable, Equatable, Sendable {
    var active = true
    var enabled = true
    var target = "tw"
    var convertOriginal = true
    var convertTranslation = true
    var protectJapanese = true
    var autoSelectChinese = true
    var fallbackOnFailure = true
    var searchDepth = "standard"
    var reportVisible = true
    var neteaseAPI = ""
}

struct SubtitleSong: Codable, Equatable, Sendable {
    let id: String
    let source: String
    let title: String
    let artist: String
    let durationMs: Double
    var ref: String? = nil
}

struct SubtitleInput: Equatable {
    let song: SubtitleSong
    let revision: UUID
    let loading: Bool
}
