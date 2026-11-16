import Foundation

// LRCLIB returns timed lyrics independently of YouTube's video stream and account credentials.
actor OnlineLyrics {
    static let shared = OnlineLyrics()
    private struct ExactKey: Hashable, Sendable {
        let title: String
        let artists: [String]
        let duration: Double
    }
    private struct CacheEntry {
        let record: LyricSearchRecord
        let expires: ContinuousClock.Instant
    }
    private struct Lookup {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<LyricSearchRecord?, Error>]
        var idleCancellation: Task<Void, Never>?
    }

    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let clock = ContinuousClock()
    private var nextRequest = Date.distantPast
    private var blockedUntil = Date.distantPast
    private var cachedExact: [ExactKey: CacheEntry] = [:]
    private var lookups: [ExactKey: Lookup] = [:]

    init(transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }) {
        self.transport = transport
    }

    func exact(title: String, artist: String, duration: Double, useCache: Bool = true) async throws -> LyricSearchRecord? {
        guard duration >= 1, duration <= 3600, !title.isEmpty, !artist.isEmpty else { return nil }
        let names = DownloadSongMatch.artistNames(artist)
        guard !names.isEmpty else { return nil }
        try Task.checkCancellation()
        if !useCache { return try await fetchExact(title: title, artist: artist, names: names, duration: duration) }
        let key = ExactKey(title: Self.lookupText(title), artists: names.map(Self.lookupText), duration: duration)
        if let cached = cachedExact[key], cached.expires > clock.now { return cached.record }
        cachedExact[key] = nil
        let waiter = UUID()
        let record = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LyricSearchRecord?, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var lookup = lookups[key] {
                    lookup.idleCancellation?.cancel()
                    lookup.idleCancellation = nil
                    lookup.waiters[waiter] = continuation
                    lookups[key] = lookup
                    return
                }
                let id = UUID()
                let task = Task {
                    do {
                        let result = try await fetchExact(title: title, artist: artist, names: names, duration: duration)
                        finish(key, id: id, result: .success(result))
                    } catch {
                        finish(key, id: id, result: .failure(error))
                    }
                }
                lookups[key] = Lookup(id: id, task: task, waiters: [waiter: continuation])
            }
        } onCancel: {
            Task { await self.release(key, waiter: waiter) }
        }
        try Task.checkCancellation()
        return record
    }

    // Preserve punctuation and recording qualifiers when sharing an exact lookup.
    private static func lookupText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private func release(_ key: ExactKey, waiter: UUID) {
        guard var lookup = lookups[key], let continuation = lookup.waiters.removeValue(forKey: waiter) else { return }
        if lookup.waiters.isEmpty {
            // The provisional track lookup can hand off to the actual recording as playback starts.
            let id = lookup.id
            lookup.idleCancellation = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let pending = lookups[key], pending.id == id, pending.waiters.isEmpty else { return }
                lookups[key] = nil
                pending.task.cancel()
            }
        }
        lookups[key] = lookup
        continuation.resume(throwing: CancellationError())
    }

    private func finish(_ key: ExactKey, id: UUID, result: Result<LyricSearchRecord?, Error>) {
        guard let lookup = lookups[key], lookup.id == id else { return }
        lookups[key] = nil
        lookup.idleCancellation?.cancel()
        if case .success(let record?) = result, let text = record.syncedLyrics,
           text.utf8.count + record.trackName.utf8.count + record.artistName.utf8.count + record.albumName.utf8.count <= 65_536 {
            let now = clock.now
            cachedExact = cachedExact.filter { $0.value.expires > now }
            if cachedExact.count >= 48, let oldest = cachedExact.min(by: { $0.value.expires < $1.value.expires })?.key {
                cachedExact[oldest] = nil
            }
            cachedExact[key] = CacheEntry(record: record, expires: now.advanced(by: .seconds(180)))
        }
        for continuation in lookup.waiters.values { continuation.resume(with: result) }
    }

    private func fetchExact(title: String, artist: String, names: [String], duration: Double) async throws -> LyricSearchRecord? {
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
        while true {
            try Task.checkCancellation()
            let now = Date()
            guard now >= blockedUntil else { throw DiagnosticProblem(code: .rateLimit) }
            let delay = nextRequest.timeIntervalSince(now)
            if delay <= 0 {
                nextRequest = now.addingTimeInterval(0.4)
                break
            }
            try await Task.sleep(for: .seconds(delay))
        }
        var parts = URLComponents(string: "https://lrclib.net/api/" + path)!
        parts.queryItems = items
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: parts.url!, timeoutInterval: 15)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        request.setValue("Syllume-iOS/\(version) (https://github.com/Fringetw/Syllume)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport(request)
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
