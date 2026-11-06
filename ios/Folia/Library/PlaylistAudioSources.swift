import Foundation

// Guest requests only. No Google token, platform cookie, trial stream or encrypted music file is used.
actor PlaylistAudioSources {
    static let shared = PlaylistAudioSources()
    private let session: URLSession
    private var blockedUntil: [String: Date] = [:]
    private var nextRequest: [String: Date] = [:]

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
    }

    func resolve(_ entry: LibraryEntry) async throws -> [DownloadableAudio] {
        guard let requested = PlaylistAudioRules.song(entry), !requested.artist.isEmpty else { throw PlaylistAudioError.noMatch }
        async let netease = attempt { try await self.netease(requested) }
        async let qq = attempt { try await self.qq(requested) }
        let results = await [netease, qq]
        try Task.checkCancellation()
        let audio = results.flatMap { (try? $0.get()) ?? [] }.sorted(by: PlaylistAudioRules.better)
        if !audio.isEmpty { return audio }
        if results.contains(where: {
            if case .failure(let error) = $0 { return error as? PlaylistAudioError == .rateLimited }; return false
        }) { throw PlaylistAudioError.rateLimited }
        if results.contains(where: { if case .failure = $0 { return true }; return false }) { throw PlaylistAudioError.unavailable }
        throw PlaylistAudioError.noAudio
    }

    private func attempt(_ action: @Sendable () async throws -> [DownloadableAudio]) async -> Result<[DownloadableAudio], Error> {
        do { return .success(try await action()) } catch { return .failure(error) }
    }

    func lyrics(_ audio: DownloadableAudio) async -> [LyricLine] {
        (try? await SubtitleNetwork.shared.lyrics(SubtitleRecord(song: audio.song), netease: "", original: [])) ?? []
    }

    func coolDown(_ provider: String) { blockedUntil[provider] = Date().addingTimeInterval(60) }

    private func netease(_ requested: SubtitleSong) async throws -> [DownloadableAudio] {
        let query = String((requested.title + " " + requested.artist).prefix(160))
        let search = try await read(URL(string: "https://music.163.com/api/cloudsearch/pc")!, provider: "netease",
                                    body: SubtitleNetwork.neteaseForm(query), contentType: "application/x-www-form-urlencoded")
        let matches = try SubtitleSourceDecoders.neteaseSearch(search).filter {
            PlaylistAudioRules.matches($0.song, requested: requested)
        }.prefix(2)
        var result: [DownloadableAudio] = []
        for match in matches {
            try Task.checkCancellation()
            var form = URLComponents()
            form.queryItems = [.init(name: "ids", value: "[" + match.song.id + "]"),
                               .init(name: "level", value: "hires"), .init(name: "encodeType", value: "flac")]
            let data = try await read(URL(string: "https://music.163.com/api/song/enhance/player/url/v1")!,
                                      provider: "netease", body: Data((form.percentEncodedQuery ?? "").utf8),
                                      contentType: "application/x-www-form-urlencoded")
            var audio = (try? PlaylistAudioRules.neteaseAudio(data, song: match.song)) ?? []
            if audio.isEmpty {
                // The legacy endpoint may offer a lower guest quality; its actual bitrate is retained.
                var parts = URLComponents(string: "https://music.163.com/api/song/enhance/player/url")!
                parts.queryItems = [.init(name: "ids", value: "[" + match.song.id + "]"), .init(name: "br", value: "999000")]
                let fallback = try await read(parts.url!, provider: "netease")
                audio = (try? PlaylistAudioRules.neteaseAudio(fallback, song: match.song)) ?? []
            }
            result += audio
        }
        return result
    }

    private func qq(_ requested: SubtitleSong) async throws -> [DownloadableAudio] {
        var parts = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")!
        parts.queryItems = [.init(name: "w", value: String((requested.title + " " + requested.artist).prefix(100))),
                            .init(name: "format", value: "json"), .init(name: "p", value: "1"), .init(name: "n", value: "8")]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let data = try await read(parts.url!, provider: "qq")
        let records = try SubtitleSourceDecoders.qqSearch(data).filter { PlaylistAudioRules.matches($0.song, requested: requested) }.prefix(2)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["data"] as? [String: Any], let songs = body["song"] as? [String: Any],
              let rows = songs["list"] as? [[String: Any]] else { throw PlaylistAudioError.unavailable }
        var result: [DownloadableAudio] = []
        for record in records {
            guard let row = rows.first(where: { String(describing: $0["songid"] ?? "") == record.song.id }),
                  let mid = row["songmid"] as? String else { continue }
            let media = (row["strMediaMid"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? mid
            guard [mid, media].allSatisfy({ $0.range(of: "^[A-Za-z0-9]{1,100}$", options: .regularExpression) != nil }) else { continue }
            let names = PlaylistAudioRules.qqFormats.map { $0.prefix + media + "." + $0.ext }
            let payload: [String: Any] = [
                "comm": ["uin": 0, "format": "json", "ct": 24, "cv": 0],
                "req_0": ["module": "vkey.GetVkeyServer", "method": "CgiGetVkey", "param": [
                    "guid": String(UInt64.random(in: 1_000_000_000...9_999_999_999)), "songmid": names.map { _ in mid },
                    "songtype": names.map { _ in 0 }, "filename": names, "uin": "0", "loginflag": 1, "platform": "20"]]]
            // This gateway accepts the JSON envelope in data; no account session is supplied.
            var endpoint = URLComponents(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!
            endpoint.queryItems = [.init(name: "format", value: "json"),
                                   .init(name: "data", value: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self))]
            let response = try await read(endpoint.url!, provider: "qq")
            result += (try? PlaylistAudioRules.qqAudio(response, song: record.song, mediaID: media)) ?? []
        }
        return result
    }

    private func read(_ url: URL, provider: String, body: Data? = nil, contentType: String = "application/json") async throws -> Data {
        try Task.checkCancellation()
        guard Date() >= (blockedUntil[provider] ?? .distantPast) else { throw PlaylistAudioError.rateLimited }
        let time = max(Date(), nextRequest[provider] ?? .distantPast)
        nextRequest[provider] = time.addingTimeInterval(0.5)
        let delay = time.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.setValue(provider == "qq" ? "https://y.qq.com/" : "https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("Folia-iOS/0.4.0", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (bytes, response) = try await session.bytes(for: request, delegate: PlaylistMetadataRedirect(host: url.host ?? ""))
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw PlaylistAudioError.unavailable }
        if http.statusCode == 429 || http.statusCode == 503 {
            let delay = min(3600, max(60, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60))
            blockedUntil[provider] = Date().addingTimeInterval(delay)
            throw PlaylistAudioError.rateLimited
        }
        guard (200..<300).contains(http.statusCode), response.expectedContentLength <= 8_000_000 else {
            throw PlaylistAudioError.unavailable
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 8_000_000 else { throw PlaylistAudioError.unavailable }
            data.append(byte)
        }
        return data
    }
}

private final class PlaylistMetadataRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    let host: String
    init(host: String) { self.host = host }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == host, parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443 else { completionHandler(nil); return }
        completionHandler(request)
    }
}
