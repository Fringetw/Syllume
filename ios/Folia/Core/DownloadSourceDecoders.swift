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
                let freeTrialInfo: LyricJSON?; let size: Int?; let sr: Double?
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
            duration: recording.seconds, format: format, bitrate: item.br ?? 0, source: "網易雲",
            recording: SubtitleSong(id: String(recording.id), source: "netease", title: recording.name, artist: recording.artist, durationMs: recording.seconds * 1000),
            expectedBytes: item.size.flatMap { $0 > 0 ? $0 : nil }, sampleRate: item.sr)
    }

    struct QQSong: Decodable, Sendable {
        let songmid: String
        let strMediaMid: String?
        let songid: Int
        let songname: String
        let singer: [Singer]
        let interval: Double
        struct Singer: Decodable, Sendable { let name: String }
        var mid: String { songmid }
        var mediaID: String { (strMediaMid?.isEmpty == false ? strMediaMid : nil) ?? songmid }
        var artist: String { singer.map(\.name).joined(separator: "、") }
    }

    static let qqFormats: [(prefix: String, format: String, bitrate: Int, bits: Int?)] = [
        ("RS01", "flac", 0, 24), ("F000", "flac", 0, nil), ("M800", "mp3", 320_000, nil),
        ("M500", "mp3", 128_000, nil), ("C600", "m4a", 96_000, nil), ("C400", "m4a", 48_000, nil)
    ]

    static func qqSearch(_ data: Data, for song: SyncedYouTubeSong) throws -> [QQSong] {
        struct Page: Decodable {
            let code: Int; let data: Body?
            struct Body: Decodable {
                let song: List?
                struct List: Decodable { let list: [QQSong]? }
            }
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        guard page.code == 0 else { throw PlatformError.message("QQ 音樂暫時無法搜尋音源。") }
        func valid(_ value: String) -> Bool { value.range(of: #"^[A-Za-z0-9]{1,32}$"#, options: .regularExpression) != nil }
        return (page.data?.song?.list ?? []).filter {
            valid($0.mid) && valid($0.mediaID)
                && DownloadSongMatch.matches(song, title: $0.songname, artists: $0.singer.map(\.name), duration: $0.interval)
        }
    }

    static func qqAudio(_ data: Data, recording: QQSong) throws -> [DownloadAudioCandidate] {
        struct Page: Decodable {
            let code: Int; let req_0: Response?
            struct Response: Decodable {
                let code: Int; let data: Body?
                struct Body: Decodable {
                    let sip: [String]; let midurlinfo: [Item]
                    struct Item: Decodable {
                        let songmid: String; let filename: String; let purl: String
                        let result: Int?; let ekey: String?
                    }
                }
            }
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        guard page.code == 0, page.req_0?.code == 0, let body = page.req_0?.data else { return [] }
        let roots = body.sip.compactMap { value -> URL? in
            guard var components = URLComponents(string: value), let host = components.host?.lowercased(),
                host == "qqmusic.qq.com" || host.hasSuffix(".qqmusic.qq.com"),
                components.query == nil, components.port == nil,
                components.path == "/" || components.path.isEmpty else { return nil }
            if components.scheme == "http" { components.scheme = "https" }
            return components.url.flatMap { DownloadSongMatch.safeAudioURL($0.absoluteString) }
        }
        guard let root = roots.first else { return [] }
        return qqFormats.compactMap { format in
            let name = format.prefix + recording.mediaID + "." + format.format
            guard let item = body.midurlinfo.first(where: {
                $0.songmid == recording.mid && $0.filename == name && ($0.result ?? 0) == 0 && ($0.ekey ?? "").isEmpty
            }), item.purl.hasPrefix(name + "?"), !item.purl.contains("#"),
                let url = URL(string: item.purl, relativeTo: root)?.absoluteURL,
                url.host == root.host, url.lastPathComponent == name else { return nil }
            return DownloadAudioCandidate(url: url, title: recording.songname, artist: recording.artist,
                duration: recording.interval, format: format.format, bitrate: format.bitrate, source: "QQ 音樂",
                recording: SubtitleSong(id: String(recording.songid), source: "qq", title: recording.songname,
                    artist: recording.artist, durationMs: recording.interval * 1000), bits: format.bits)
        }
    }
}
