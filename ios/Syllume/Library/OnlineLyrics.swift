import Foundation

// LRCLIB returns timed lyrics independently of YouTube's video stream and account credentials.
actor OnlineLyrics {
    static let shared = OnlineLyrics()
    private var nextRequest = Date.distantPast
    private var blockedUntil = Date.distantPast

    func exact(title: String, artist: String, duration: Double) async throws -> LyricSearchRecord? {
        guard duration >= 1, duration <= 3600, !title.isEmpty, !artist.isEmpty else { return nil }
        let names = DownloadSongMatch.artistNames(artist)
        guard let firstArtist = names.first else { return nil }
        let data = try await request(path: "get-cached", items: [URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: names.joined(separator: ", ")),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))])
        if let data, let record = try? JSONDecoder().decode(LyricSearchRecord.self, from: data),
           record.matches(title: title, artist: artist, duration: duration) { return record }
        for name in DownloadSongMatch.queryNames(for: firstArtist).prefix(2) {
            let records = try await search(title: title, artist: name)
            if let record = records.filter({ $0.matches(title: title, artist: artist, duration: duration) })
                .min(by: { abs($0.duration - duration) < abs($1.duration - duration) }) { return record }
        }
        return nil
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
        let now = Date()
        guard now >= blockedUntil else { throw DiagnosticProblem(code: .rateLimit) }
        let scheduled = max(now, nextRequest)
        nextRequest = scheduled.addingTimeInterval(0.4)
        if scheduled > now { try await Task.sleep(for: .seconds(scheduled.timeIntervalSince(now))) }
        guard Date() >= blockedUntil else { throw DiagnosticProblem(code: .rateLimit) }
        var parts = URLComponents(string: "https://lrclib.net/api/" + path)!
        parts.queryItems = items
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: parts.url!, timeoutInterval: 15)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        request.setValue("Syllume-iOS/\(version) (https://github.com/Fringetw/Syllume)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 429 || http.statusCode == 503 {
            let delay = max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60)
            blockedUntil = Date().addingTimeInterval(delay * 1.1)
            throw DiagnosticProblem(code: .rateLimit, httpStatus: http.statusCode)
        }
        guard http.statusCode == 200, data.count <= 8_000_000 else { throw URLError(.badServerResponse) }
        return data
    }
}
