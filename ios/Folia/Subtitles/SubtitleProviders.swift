import Foundation

// Anonymous, read-only subtitle sources. No platform cookies or Google credentials are sent here.
actor SubtitleNetwork {
    static let shared = SubtitleNetwork()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 7
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()
    private var blockedUntil: [String: Date] = [:]

    static func neteaseURL(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        return parts.url
    }

    func search(_ query: String, provider: String, netease: String, current: SubtitleSong?) async throws -> [SubtitleRecord] {
        switch provider {
        case "netease":
            let custom = Self.neteaseURL(netease)
            let data = try await read(url: url(base: custom ?? URL(string: "https://music.163.com")!,
                path: custom == nil ? "api/search/get/web" : "search", query: [
                    .init(name: custom == nil ? "s" : "keywords", value: query), .init(name: "type", value: "1"),
                    .init(name: "limit", value: "8"), .init(name: "offset", value: "0")]), provider: provider)
            return try SubtitleSourceDecoders.neteaseSearch(data)
        case "qq":
            let data = try await read(url: url(base: URL(string: "https://c.y.qq.com")!, path: "soso/fcgi-bin/client_search_cp",
                query: [.init(name: "w", value: String(query.prefix(60))), .init(name: "format", value: "json"),
                        .init(name: "p", value: "1"), .init(name: "n", value: "8")]), provider: provider)
            return try SubtitleSourceDecoders.qqSearch(data)
        case "ytm":
            // A currently playing video is stronger evidence than a same-title video on another channel.
            let playing: [SubtitleRecord] = current.flatMap { song in
                song.source == "ytm" && YouTubeVideo.validID(song.id) ? [SubtitleRecord(song: song)] : nil
            } ?? []
            do {
                let data = try await read(url: url(base: URL(string: "https://www.youtube.com")!, path: "results",
                    query: [.init(name: "search_query", value: query + " 中文字幕"), .init(name: "hl", value: "zh-TW"),
                            .init(name: "gl", value: "TW")]), provider: provider)
                guard let page = String(data: data, encoding: .utf8) else { throw SubtitleReadError("invalid-response") }
                let found = try YouTubeCaptionDecoders.search(page)
                return Array((playing + found.filter { $0.song.id != playing.first?.song.id }).prefix(8))
            } catch {
                try Task.checkCancellation()
                if !playing.isEmpty { return playing }
                throw error
            }
        case "lrclib":
            let data = try await read(url: url(base: URL(string: "https://lrclib.net/api")!, path: "search",
                query: [.init(name: "q", value: query)]), provider: provider)
            let records = try JSONDecoder().decode([LyricSearchRecord].self, from: data)
            return records.prefix(8).map { record in
                SubtitleRecord(song: SubtitleSong(id: String(record.id), source: provider, title: record.trackName,
                    artist: record.artistName, durationMs: record.duration * 1000),
                    lines: record.syncedLyrics.map { LyricTimeline(lrc: $0).lines })
            }
        default: throw SubtitleReadError("unsupported")
        }
    }

    func lyrics(_ record: SubtitleRecord, netease: String, original: [LyricLine]) async throws -> [LyricLine] {
        let song = record.song
        let lines: [LyricLine]
        switch song.source {
        case "netease":
            guard !song.id.isEmpty, song.id.allSatisfy(\.isNumber) else { throw SubtitleReadError("invalid-response") }
            let custom = Self.neteaseURL(netease)
            let data = try await read(url: url(base: custom ?? URL(string: "https://music.163.com")!,
                path: custom == nil ? "api/song/lyric" : "lyric", query: [.init(name: "id", value: song.id),
                    .init(name: "lv", value: "-1"), .init(name: "tv", value: "-1"), .init(name: "rv", value: "-1")]), provider: song.source)
            lines = try SubtitleSourceDecoders.neteaseLyrics(data)
        case "qq":
            guard let id = Int64(song.id), id > 0 else { throw SubtitleReadError("invalid-response") }
            let b64 = { (value: String) in Data(value.utf8).base64EncodedString() }
            let payload: [String: Any] = [
                "comm": ["ct": 11, "cv": "1003006", "v": "1003006", "tmeAppID": "qqmusiclight", "uid": "0"],
                "request": ["module": "music.musichallSong.PlayLyricInfo", "method": "GetPlayLyricInfo", "param": [
                    "songID": id, "songName": b64(song.title), "singerName": b64(song.artist), "albumName": "",
                    "interval": Int(song.durationMs / 1000), "crypt": 0, "ct": 19, "cv": 2111,
                    "lrc_t": 0, "qrc": 0, "qrc_t": 0, "roma": 1, "roma_t": 0, "trans": 1, "trans_t": 0, "type": 0]]]
            let data = try await read(url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!, provider: "qq",
                body: JSONSerialization.data(withJSONObject: payload))
            lines = try SubtitleSourceDecoders.qqLyrics(data)
        case "ytm": lines = try await youtubeLyrics(id: song.id, baseline: original)
        case "lrclib": lines = record.lines ?? []
        default: throw SubtitleReadError("unsupported")
        }
        guard !lines.isEmpty else { throw SubtitleReadError("empty") }
        return lines
    }

    private func youtubeLyrics(id: String, baseline: [LyricLine]) async throws -> [LyricLine] {
        guard YouTubeVideo.validID(id) else { throw SubtitleReadError("invalid-response") }
        let data = try await read(url: url(base: URL(string: "https://www.youtube.com")!, path: "watch",
            query: [.init(name: "v", value: id), .init(name: "hl", value: "zh-TW")]), provider: "ytm")
        guard let page = String(data: data, encoding: .utf8) else { throw SubtitleReadError("invalid-response") }
        let tracks = try YouTubeCaptionDecoders.tracks(page, videoID: id)
        // Only an existing manually supplied Chinese track, never ASR or tlang machine translation.
        guard let chinese = tracks.filter({ $0.chinese && !$0.automatic }).sorted(by: {
            let preferred = ["zh-Hant", "zh-TW", "zh-HK", "zh", "zh-Hans", "zh-CN"]
            return (preferred.firstIndex(of: $0.language) ?? 99) < (preferred.firstIndex(of: $1.language) ?? 99)
        }).first else { throw SubtitleReadError("captions-unavailable") }
        let sample = baseline.prefix(80).map(\.fullText).joined().prefix(8000)
        let hint = sample.range(of: #"[\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) != nil ? "ja"
            : sample.range(of: #"\p{Hangul}"#, options: .regularExpression) != nil ? "ko"
            : sample.range(of: "[A-Za-z]", options: .regularExpression) != nil ? "en" : nil
        let originals = tracks.filter { !$0.chinese && !$0.automatic }
        let original = originals.first { $0.original } ?? hint.flatMap { code in originals.first { $0.language == code } }
        async let translated = caption(chinese)
        async let originalCues: [LyricLine]? = optionalCaption(original)
        let (translatedLines, originalLines) = try await (translated, originalCues)
        try Task.checkCancellation()
        return YouTubeCaptionDecoders.bilingual(chinese: translatedLines, original: originalLines)
    }
    private func caption(_ track: YouTubeCaptionTrack) async throws -> [LyricLine] {
        let data = try await read(url: track.url, provider: "ytm")
        guard !data.isEmpty else { throw SubtitleReadError("caption-read-failed") }
        return try YouTubeCaptionDecoders.cues(data)
    }
    private func optionalCaption(_ track: YouTubeCaptionTrack?) async -> [LyricLine]? {
        guard let track else { return nil }
        return try? await caption(track)
    }
    private func url(base: URL, path: String, query: [URLQueryItem]) -> URL {
        var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query
        return parts.url!
    }
    private func read(url: URL, provider: String, body: Data? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard Date() >= (blockedUntil[provider] ?? .distantPast) else { throw SubtitleReadError("rate-limited") }
        var request = URLRequest(url: url, timeoutInterval: 7)
        request.setValue(provider == "ytm" ? "Mozilla/5.0 Folia-iOS/0.3.2" : "Folia-iOS/0.3.2", forHTTPHeaderField: "User-Agent")
        if provider == "netease" { request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer") }
        if provider == "qq" {
            request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
            request.setValue("okhttp/3.14.9", forHTTPHeaderField: "User-Agent")
        }
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let policy = SubtitleRedirectGuard(host: url.host ?? "", port: url.port)
        let (bytes, response) = try await session.bytes(for: request, delegate: policy)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw SubtitleReadError("network") }
        if http.statusCode == 429 || http.statusCode == 503 {
            let delay = min(3600, max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60))
            blockedUntil[provider] = Date().addingTimeInterval(delay)
            throw SubtitleReadError("rate-limited")
        }
        if http.statusCode == 401 { throw SubtitleReadError("not-signed-in") }
        if http.statusCode == 403 || http.statusCode == 451 { throw SubtitleReadError("region-restricted") }
        guard (200..<300).contains(http.statusCode), response.expectedContentLength <= 8_000_000 else { throw SubtitleReadError("unavailable") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 8_000_000 else { throw SubtitleReadError("invalid-response") }
            data.append(byte)
        }
        return data
    }
}

private final class SubtitleRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let host: String
    let port: Int?
    init(host: String, port: Int?) { self.host = host; self.port = port }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == host, parts.port == port,
              parts.user == nil, parts.password == nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}
