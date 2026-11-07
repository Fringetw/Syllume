import Foundation

// Account-scoped playlist snapshots contain metadata and local IDs, never expiring audio URLs.
struct YouTubePlaylistChoice: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    var collection: LibraryCollection { id == "liked" ? .liked : .playlist(id) }
    static let liked = YouTubePlaylistChoice(id: "liked", title: "喜歡的影片")
}

struct SyncedYouTubeSong: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let videoID: String
    let title: String
    let artist: String
    var duration: Double?
    init?(_ entry: LibraryEntry) {
        guard let videoID = YouTubeVideo.identifier(from: entry.url.absoluteString) else { return nil }
        id = entry.id; self.videoID = videoID; title = entry.title; artist = entry.subtitle; duration = entry.duration
    }
}

struct YouTubeAudioBinding: Codable, Equatable, Sendable {
    let trackID: String
    let quality: String
}

struct YouTubeSyncSnapshot: Codable, Equatable {
    var choice: YouTubePlaylistChoice?
    var songs: [SyncedYouTubeSong] = []
    var bindings: [String: YouTubeAudioBinding] = [:]
    var lastSync: Date?
}

struct DownloadAudioCandidate: Sendable {
    let url: URL
    let title: String
    let artist: String
    let duration: Double
    let format: String
    let bitrate: Int
    let source: String
    var lossless: Bool { ["flac", "alac", "wav", "aiff", "aif"].contains(format.lowercased()) }
    var quality: String { source + " · " + format.uppercased() + (lossless ? " 無損" : bitrate > 0 ? " \(bitrate / 1000) kbps" : " 原始音質") }
    static func preferred(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.lossless != rhs.lossless { return lhs.lossless }
        return lhs.bitrate > rhs.bitrate
    }
}

enum DownloadSongMatch {
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func sameDuration(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b, a.isFinite, b.isFinite, a > 0, b > 0 else { return false }
        return abs(a - b) <= max(5, min(a, b) * 0.025)
    }

    // Require title, artist and version evidence before automatically downloading another platform's recording.
    static func matches(_ song: SyncedYouTubeSong, title: String, artists: [String], duration: Double?) -> Bool {
        guard sameDuration(song.duration, duration) else { return false }
        let versions = ["live", "remix", "cover", "acoustic", "instrumental", "karaoke", "nightcore", "sped up", "slowed", "medley", "翻唱", "現場", "伴奏", "合唱", "串燒"]
        let targetText = song.title.lowercased(), candidateText = title.lowercased()
        for version in versions {
            if targetText.contains(version) != candidateText.contains(version) { return false }
        }
        let target = normalized(song.title + " " + song.artist)
        let knownArtists = artists.map(normalized).filter { !$0.isEmpty }
        guard knownArtists.contains(where: { target.contains($0) }) else { return false }
        var cleaned = song.title
        for text in ["official music video", "official video", "official audio", "music video", "lyric video", "lyrics video", "official mv", "official", "完整版", "中文字幕", "繁體中文", "中字"] {
            cleaned = cleaned.replacingOccurrences(of: text, with: "", options: .caseInsensitive)
        }
        for artist in artists { cleaned = cleaned.replacingOccurrences(of: artist, with: "", options: .caseInsensitive) }
        let key = normalized(title)
        guard !key.isEmpty else { return false }
        if normalized(cleaned) == key { return true }
        return cleaned.components(separatedBy: CharacterSet(charactersIn: "/／|｜「」『』\"“”"))
            .contains { normalized($0) == key }
    }

    static func safeAudioURL(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value), parts.scheme == "https", let host = parts.host,
              !host.isEmpty, parts.user == nil, parts.password == nil, parts.fragment == nil else { return nil }
        return parts.url
    }
}
