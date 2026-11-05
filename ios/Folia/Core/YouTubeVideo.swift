import Foundation

// Only canonical YouTube video identifiers reach the embedded player's JavaScript bridge.
struct YouTubeVideo: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var artist: String
    var queueID: String? = nil

    static func identifier(from text: String) -> String? {
        guard let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              url.port == nil, let host = url.host?.lowercased() else { return nil }
        let id: String?
        if host == "youtu.be" {
            let parts = url.path.split(separator: "/")
            id = parts.count == 1 ? String(parts[0]) : nil
        } else if ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"].contains(host) {
            if url.path == "/watch" {
                let values = (url.queryItems ?? []).filter { $0.name == "v" }
                id = values.count == 1 ? values[0].value : nil
            } else {
                let parts = url.path.split(separator: "/")
                id = parts.count == 2 && ["shorts", "embed", "live"].contains(String(parts[0])) ? String(parts[1]) : nil
            }
        } else { return nil }
        return id.flatMap { validID($0) ? $0 : nil }
    }

    static func validID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }
}

struct YouTubeSnapshot: Decodable {
    let session: String
    let videoID: String
    let state: Int
    let time: Double
    let duration: Double
    let title: String?
    let author: String?

    func belongs(to session: UUID, videoID: String) -> Bool {
        self.session == session.uuidString && self.videoID == videoID
            && [-1, 0, 1, 2, 3, 5].contains(state)
            && time.isFinite && duration.isFinite && time >= 0 && duration >= 0
            && time <= 86_400 && duration <= 86_400
    }
}

struct LyricSearchRecord: Decodable, Identifiable, Sendable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: Double
    let syncedLyrics: String?

    func matches(title: String, artist: String, duration: Double) -> Bool {
        Self.key(trackName) == Self.key(title) && Self.key(artistName) == Self.key(artist)
            && duration.isFinite && self.duration.isFinite && abs(self.duration - duration) <= 2
            && !(syncedLyrics ?? "").isEmpty
    }

    private static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }
}
