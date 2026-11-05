import Foundation

struct SubtitleReadError: Error {
    let code: String
    init(_ code: String) { self.code = code }
}

struct SubtitleRecord: Sendable {
    let song: SubtitleSong
    let lines: [LyricLine]?
}

// Searches the app's sources. Credentials never enter the JavaScript engine or diagnostic reports.
actor SubtitleNetwork {
    static let shared = SubtitleNetwork()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 7
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

    func search(_ query: String, provider: String, netease: String) async throws -> [SubtitleRecord] {
        if provider == "lrclib" {
            let data = try await read(base: URL(string: "https://lrclib.net/api")!, path: "search",
                                      query: [.init(name: "q", value: query)], provider: provider)
            let records = try JSONDecoder().decode([LyricSearchRecord].self, from: data)
            return records.prefix(8).map { record in
                SubtitleRecord(song: SubtitleSong(id: String(record.id), source: provider, title: record.trackName,
                    artist: record.artistName, durationMs: record.duration * 1000),
                    lines: record.syncedLyrics.map { LyricTimeline(lrc: $0).lines })
            }
        }
        guard provider == "netease", let base = Self.neteaseURL(netease) else { throw SubtitleReadError("unsupported") }
        let data = try await read(base: base, path: "search", query: [.init(name: "keywords", value: query),
            .init(name: "type", value: "1"), .init(name: "limit", value: "8")], provider: provider)
        let result = try JSONDecoder().decode(NeteaseSearch.self, from: data)
        try check(result.code)
        return (result.result?.songs ?? []).prefix(8).map { song in
            SubtitleRecord(song: SubtitleSong(id: String(song.id), source: provider, title: song.name,
                artist: (song.artists ?? song.ar ?? []).map(\.name).joined(separator: " / "),
                durationMs: song.duration ?? song.dt ?? 0), lines: nil)
        }
    }

    func neteaseLyrics(id: String, base text: String) async throws -> [LyricLine] {
        guard let base = Self.neteaseURL(text), id.allSatisfy(\.isNumber), !id.isEmpty else { throw SubtitleReadError("unsupported") }
        let data = try await read(base: base, path: "lyric", query: [.init(name: "id", value: id)], provider: "netease")
        let result = try JSONDecoder().decode(NeteaseLyrics.self, from: data)
        try check(result.code)
        let original = LyricTimeline(lrc: result.lrc?.lyric ?? "")
        let translation = LyricTimeline(lrc: result.tlyric?.lyric ?? "")
        let romanization = LyricTimeline(lrc: result.romalrc?.lyric ?? "")
        return original.lines.map { line in
            var line = line
            line.translation = translation.lines.first { abs($0.startTime - line.startTime) <= 0.15 }?.fullText
            line.romanization = romanization.lines.first { abs($0.startTime - line.startTime) <= 0.15 }?.fullText
            return line
        }
    }

    private func check(_ code: Int?) throws {
        if code == 301 || code == 401 { throw SubtitleReadError("not-signed-in") }
        if let code, code != 200 { throw SubtitleReadError(code == 429 ? "rate-limited" : "unavailable") }
    }

    private func read(base: URL, path: String, query: [URLQueryItem], provider: String) async throws -> Data {
        guard Date() >= (blockedUntil[provider] ?? .distantPast) else { throw SubtitleReadError("rate-limited") }
        var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query
        var request = URLRequest(url: parts.url!, timeoutInterval: 7)
        request.setValue("Folia-iOS/0.3.1 (https://github.com/Fringetw/folia-ios)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw SubtitleReadError("network") }
        if http.statusCode == 429 || http.statusCode == 503 {
            let delay = min(3600, max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60))
            blockedUntil[provider] = Date().addingTimeInterval(delay)
            throw SubtitleReadError("rate-limited")
        }
        if http.statusCode == 401 { throw SubtitleReadError("not-signed-in") }
        if http.statusCode == 403 || http.statusCode == 451 { throw SubtitleReadError("region-restricted") }
        guard (200..<300).contains(http.statusCode), response.expectedContentLength <= 8_000_000 else {
            throw SubtitleReadError("unavailable")
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 8_000_000 else { throw SubtitleReadError("invalid-response") }
            data.append(byte)
        }
        return data
    }

    private struct NeteaseSearch: Decodable {
        let code: Int?
        let result: Result?
        struct Result: Decodable { let songs: [Song]? }
        struct Song: Decodable {
            let id: Int64
            let name: String
            let artists: [Artist]?
            let ar: [Artist]?
            let duration: Double?
            let dt: Double?
        }
        struct Artist: Decodable { let name: String }
    }
    private struct NeteaseLyrics: Decodable {
        let code: Int?
        let lrc: Text?
        let tlyric: Text?
        let romalrc: Text?
        struct Text: Decodable { let lyric: String? }
    }
}
