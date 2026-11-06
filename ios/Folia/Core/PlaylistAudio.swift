import Foundation

struct YouTubePlaylistChoice: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    static let liked = Self(id: "$liked", title: "喜歡的影片")
    var collection: LibraryCollection { id == Self.liked.id ? .liked : .playlist(id) }
    var valid: Bool {
        id == Self.liked.id || (!id.isEmpty && id.count <= 200 &&
            id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
    }
}

struct PlaylistAudioBinding: Codable, Sendable {
    let fingerprint: String
    let trackID: String
    let provider: String
    let quality: String
}

struct YouTubePlaylistCache: Codable, Sendable {
    var choice: YouTubePlaylistChoice?
    var entries: [LibraryEntry] = []
    var bindings: [String: PlaylistAudioBinding] = [:]
    var syncedAt: Date?
}

enum PlaylistAudioError: LocalizedError, Equatable {
    case unavailable, noMatch, noAudio, incomplete, invalidFile, oversized, storage, rateLimited
    var errorDescription: String? {
        switch self {
        case .unavailable: "音源暫時無法連線，請稍後重試。"
        case .noMatch: "無法確認同一首、同一版本的音源。"
        case .noAudio: "來源未提供可下載的完整音檔，可能受會員、授權或地區限制。"
        case .incomplete: "來源只有片段或時長不符，未存成完整歌曲。"
        case .invalidFile: "來源沒有提供 iPhone 可播放的有效音訊。"
        case .oversized: "音訊檔超過單曲 1 GB 上限。"
        case .storage: "可用儲存空間不足，已停止下載。"
        case .rateLimited: "來源要求稍後再試，已暫停這個來源的請求。"
        }
    }
}

struct DownloadableAudio: Sendable {
    let provider: String
    let song: SubtitleSong
    let url: URL
    let fileExtension: String
    let qualityRank: Int
    let bitrate: Int
    var identity: String { "\(provider):\(song.id):\(fileExtension):\(qualityRank):\(bitrate)" }
}

enum PlaylistAudioRules {
    static let maximumBytes: Int64 = 1_000_000_000

    static func videoID(_ entry: LibraryEntry) -> String? { YouTubeVideo.identifier(from: entry.url.absoluteString) }

    static func song(_ entry: LibraryEntry) -> SubtitleSong? {
        guard let id = videoID(entry), let duration = entry.duration, duration > 0, duration <= 5400 else { return nil }
        return YouTubeCaptionDecoders.metadata(id: id, title: entry.title, artist: entry.subtitle, duration: duration)
    }

    static func fingerprint(_ entry: LibraryEntry) -> String {
        let song = song(entry)
        return [videoID(entry) ?? "", titleKey(song?.title ?? entry.title), artistKey(song?.artist ?? entry.subtitle),
                String(Int((entry.duration ?? 0).rounded()))].joined(separator: "|")
    }

    static func titleKey(_ text: String) -> String {
        var value = text.replacingOccurrences(
            of: #"(?i)[(\[【（]\s*(?:official(?:\s+(?:music\s+)?video|\s+audio)?|music\s+video|lyric(?:s|\s+video)?|mv|hd|4k|中文字幕|中字)\s*[)\]】）]"#,
            with: "", options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"(?i)\s*[-|–—]?\s+(?:official\s+(?:music\s+video|video|audio)|music\s+video|lyric\s+video|lyrics|mv|hd|4k)\s*$"#,
            with: "", options: .regularExpression)
        return key(value)
    }

    static func artistKey(_ text: String) -> String {
        key(text.replacingOccurrences(of: #"(?i)\s*(?:-\s*topic|vevo|\s+official(?:\s+channel)?)\s*$"#,
                                      with: "", options: .regularExpression))
    }

    private static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX")).filter { $0.isLetter || $0.isNumber }
    }

    static func matches(_ candidate: SubtitleSong, requested: SubtitleSong) -> Bool {
        let title = titleKey(requested.title), artist = artistKey(requested.artist)
        guard title.count >= 2, !artist.isEmpty, titleKey(candidate.title) == title,
              artistKey(candidate.artist) == artist, requested.durationMs > 0,
              candidate.durationMs.isFinite, candidate.durationMs > 0 else { return false }
        // Keep live, remix, cover and instrumental names intact; duration alone is insufficient.
        return abs(candidate.durationMs - requested.durationMs) <= min(8000, max(2000, requested.durationMs * 0.02))
    }

    static func validAudioURL(_ url: URL, provider: String) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host?.lowercased(), parts.user == nil,
              parts.password == nil, parts.fragment == nil, parts.port == nil || parts.port == 443 else { return false }
        let domain = provider == "netease" ? "music.126.net" : provider == "qq" ? "qqmusic.qq.com" : ""
        return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
    }

    static func better(_ left: DownloadableAudio, _ right: DownloadableAudio) -> Bool {
        if left.qualityRank != right.qualityRank { return left.qualityRank > right.qualityRank }
        if left.bitrate != right.bitrate { return left.bitrate > right.bitrate }
        return left.identity < right.identity
    }

    static func safeFilename(title: String, artist: String, id: String, ext: String) -> String {
        let proposed = "\(title) — \(artist)".map { character -> Character in
            character.unicodeScalars.contains(where: { $0.value < 32 || "/\\:".unicodeScalars.contains($0) }) ? "-" : character
        }
        var stem = ""
        for character in proposed {
            guard (stem + String(character)).utf8.count <= 160 else { break }
            stem.append(character)
        }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return (stem.isEmpty ? "Folia" : stem) + " [\(id)].\(ext)"
    }

    static func validBasename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") &&
            !name.unicodeScalars.contains { $0.value < 32 } && name.utf8.count <= 255
    }

    static func duration(_ value: String?) -> Double? {
        guard let value, let expression = try? NSRegularExpression(pattern: #"^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$"#),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        var seconds = 0.0
        for (index, multiplier) in [(1, 3600.0), (2, 60.0), (3, 1.0)] {
            if let range = Range(match.range(at: index), in: value), let number = Double(value[range]) { seconds += number * multiplier }
        }
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    static func fia(_ lines: [LyricLine]) throws -> Data {
        struct Document: Encodable {
            let format = "folia-lyricdata"
            let version = 1
            let lyrics: Lyrics
            struct Lyrics: Encodable { let lines: [LyricLine]; let isWordByWord: Bool }
        }
        let safe = LyricTimeline(lines: Array(lines.prefix(20_000))).lines
        return try JSONEncoder().encode(Document(lyrics: .init(lines: safe, isWordByWord: true)))
    }

    static func neteaseAudio(_ data: Data, song: SubtitleSong) throws -> [DownloadableAudio] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else { throw PlaylistAudioError.unavailable }
        if let code = root["code"] as? Int, code != 200 { throw PlaylistAudioError.noAudio }
        return rows.compactMap { row in
            guard String(describing: row["id"] ?? "") == song.id,
                  (row["code"] as? Int ?? 200) == 200,
                  (row["freeTrialInfo"] == nil || row["freeTrialInfo"] is NSNull),
                  let value = row["url"] as? String, let url = URL(string: value.replacingOccurrences(of: "http://", with: "https://")),
                  validAudioURL(url, provider: "netease") else { return nil }
            let ext = (row["type"] as? String ?? "").lowercased()
            guard ["mp3", "flac", "m4a"].contains(ext) else { return nil }
            let bitrate = (row["br"] as? NSNumber)?.intValue ?? 0
            let level = row["level"] as? String ?? ""
            let rank = ext == "flac" ? (["hires", "jyeffect", "sky"].contains(level) ? 80 : 60) : bitrate >= 256000 ? 40 : 20
            return DownloadableAudio(provider: "netease", song: song, url: url, fileExtension: ext, qualityRank: rank, bitrate: bitrate)
        }
    }

    static let qqFormats: [(prefix: String, ext: String, rank: Int, bitrate: Int)] = [
        ("RS01", "flac", 80, 0), ("F000", "flac", 60, 0), ("M800", "mp3", 40, 320000),
        ("C600", "m4a", 30, 192000), ("M500", "mp3", 20, 128000), ("C400", "m4a", 10, 96000)
    ]

    static func qqAudio(_ data: Data, song: SubtitleSong, mediaID: String) throws -> [DownloadableAudio] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["code"] as? Int) == 0, let response = root["req_0"] as? [String: Any],
              (response["code"] as? Int) == 0, let payload = response["data"] as? [String: Any],
              let rows = payload["midurlinfo"] as? [[String: Any]], let servers = payload["sip"] as? [String] else {
            throw PlaylistAudioError.unavailable
        }
        let bases = servers.compactMap { URL(string: $0.replacingOccurrences(of: "http://", with: "https://")) }
            .filter { validAudioURL($0, provider: "qq") }
        return rows.compactMap { row in
            guard (row["ekey"] as? String ?? "").isEmpty, (row["result"] as? Int ?? 0) == 0,
                  let file = row["filename"] as? String,
                  let format = qqFormats.first(where: { file == $0.prefix + mediaID + "." + $0.ext }),
                  let path = row["purl"] as? String, !path.isEmpty, let base = bases.first,
                  let url = URL(string: path, relativeTo: base)?.absoluteURL, validAudioURL(url, provider: "qq") else { return nil }
            return DownloadableAudio(provider: "qq", song: song, url: url, fileExtension: format.ext,
                                     qualityRank: format.rank, bitrate: format.bitrate)
        }
    }
}
