import Foundation

// LRCLIB returns timed lyrics independently of YouTube's video stream and account credentials.
actor OnlineLyrics {
    static let shared = OnlineLyrics()
    private var nextRequest = Date.distantPast

    func exact(title: String, artist: String, duration: Double) async throws -> LyricSearchRecord? {
        guard duration >= 1, duration <= 3600, !title.isEmpty, !artist.isEmpty else { return nil }
        let data = try await request(path: "get", items: [URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist), URLQueryItem(name: "duration", value: String(Int(duration.rounded())))])
        guard let data else { return nil }
        let record = try JSONDecoder().decode(LyricSearchRecord.self, from: data)
        return record.matches(title: title, artist: artist, duration: duration) ? record : nil
    }

    func search(title: String, artist: String) async throws -> [LyricSearchRecord] {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var items = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        guard let data = try await request(path: "search", items: items) else { return [] }
        return try JSONDecoder().decode([LyricSearchRecord].self, from: data)
            .filter { !($0.syncedLyrics ?? "").isEmpty }
    }

    private func request(path: String, items: [URLQueryItem]) async throws -> Data? {
        guard Date() >= nextRequest else { throw PlatformError.message("歌詞服務暫時限制請求，請稍後再試。") }
        nextRequest = Date().addingTimeInterval(0.4)
        var parts = URLComponents(string: "https://lrclib.net/api/" + path)!
        parts.queryItems = items
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: parts.url!, timeoutInterval: 15)
        request.setValue("Syllume-iOS/0.3.12 (https://github.com/Fringetw/Syllume)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 429 || http.statusCode == 503 {
            let delay = max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60)
            nextRequest = Date().addingTimeInterval(delay * 1.1)
            throw PlatformError.message("歌詞服務忙碌，請稍後再試。")
        }
        guard http.statusCode == 200, data.count <= 8_000_000 else { throw URLError(.badServerResponse) }
        return data
    }
}
