import Foundation

// Decode full public audio responses; preview URLs and mismatched recording IDs are rejected.
enum DownloadSourceDecoders {
    struct Song: Decodable, Sendable {
        let id: Int
        let name: String
        let artists: [Artist]?
        let ar: [Artist]?
        let duration: Double?
        let dt: Double?
        struct Artist: Decodable, Sendable { let name: String; let alias: [String]?; let alia: [String]? }
        var seconds: Double { (duration ?? dt ?? 0) / 1000 }
        var names: [String] { (artists ?? ar ?? []).flatMap { [$0.name] + ($0.alias ?? []) + ($0.alia ?? []) } }
        var artist: String { (artists ?? ar ?? []).map(\.name).joined(separator: "、") }
    }

    static func search(_ data: Data, for song: SyncedYouTubeSong) throws -> [Song] {
        struct Page: Decodable {
            let code: Int
            let result: Result?
            struct Result: Decodable { let songs: [Song]? }
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        guard page.code == 200 else { throw PlatformError.message("網易雲暫時無法搜尋音源。") }
        return (page.result?.songs ?? []).filter {
            DownloadSongMatch.matches(song, title: $0.name, artists: $0.names, duration: $0.seconds)
        }
    }

    static func audio(_ data: Data, recording: Song) throws -> DownloadAudioCandidate? {
        struct Page: Decodable {
            let code: Int
            let data: [Item]?
            struct Item: Decodable {
                let id: Int; let code: Int?; let url: String?; let br: Int?; let type: String?; let time: Double?
                let freeTrialInfo: LyricJSON?
            }
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        guard page.code == 200, let item = page.data?.first(where: { $0.id == recording.id }),
              item.code == 200, item.freeTrialInfo == nil || item.freeTrialInfo == .null,
              let text = item.url, var parts = URLComponents(string: text), let host = parts.host?.lowercased(),
              host.hasSuffix(".music.126.net") || host == "music.126.net" else { return nil }
        if parts.scheme == "http" { parts.scheme = "https" }
        guard let url = parts.url.flatMap({ DownloadSongMatch.safeAudioURL($0.absoluteString) }),
              let format = item.type?.lowercased(), ["flac", "mp3", "m4a", "aac", "alac", "wav"].contains(format),
              item.time == nil || DownloadSongMatch.sameDuration(item.time.map { $0 / 1000 }, recording.seconds) else { return nil }
        return DownloadAudioCandidate(url: url, title: recording.name, artist: recording.artist,
            duration: recording.seconds, format: format, bitrate: item.br ?? 0, source: "網易雲")
    }
}
