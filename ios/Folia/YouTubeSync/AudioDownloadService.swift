import Foundation
#if canImport(YouTubeKit)
import YouTubeKit
#endif

// Public sources use a cookie-free session; Google OAuth remains confined to playlist metadata.
actor AudioDownloadService {
    static let shared = AudioDownloadService()
    private var blockedUntil: [String: Date] = [:]
    private var videoMetadata: [String: (title: String, artist: String, duration: Double, expires: Date)] = [:]
    private let artworkCache: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.totalCostLimit = 8_000_000
        cache.countLimit = 120
        return cache
    }()
    private let session = AudioDownloadService.anonymousSession(seconds: 600)
    private let metadataSession = AudioDownloadService.anonymousSession(seconds: 13)
    private static func anonymousSession(seconds: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 9
        config.timeoutIntervalForResource = seconds
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }

    func withDuration(_ song: SyncedYouTubeSong) async -> SyncedYouTubeSong {
        guard song.duration == nil, YouTubeVideo.validID(song.videoID),
              let details = try? await publicVideo(song.videoID) else { return song }
        var updated = song; updated.duration = details.duration; return updated
    }

    func candidates(for song: SyncedYouTubeSong, account: NavidromeAccount?) async throws -> [DownloadAudioCandidate] {
        guard YouTubeVideo.validID(song.videoID) else { return [] }
        async let netease = attempt { try await self.netease(song) }
        async let qq = attempt { try await self.qq(song) }
        async let personal = attempt {
            guard let account else { return [] }
            return try await NavidromeClient(account: account).downloadCandidates(for: song)
        }
        let batches = await [netease, qq, personal]
        try Task.checkCancellation()
        let candidates = batches.flatMap { (try? $0.get()) ?? [] }.sorted(by: DownloadAudioCandidate.preferred)
        if candidates.isEmpty, let failure = batches.compactMap({ if case .failure(let error) = $0 { return error }; return nil }).first {
            throw failure
        }
        return candidates
    }

    struct SourceAttempt: Sendable {
        let source: DiagnosticSource
        let candidates: [DownloadAudioCandidate]
        let problem: DiagnosticProblem?
        let elapsedMs: Int
    }

    // Return as soon as one provider has playable candidates. If all its candidates fail,
    // the resolver can retry the providers that had not yet responded.
    func streamingSearch(for song: SyncedYouTubeSong, account: NavidromeAccount?,
                         excluding searched: Set<DiagnosticSource>) async throws -> [SourceAttempt] {
        let all: [DiagnosticSource] = account == nil ? [.netease, .qq] : [.netease, .qq, .navidrome]
        let pending = all.filter { !searched.contains($0) }
        guard !pending.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: SourceAttempt?.self) { group in
            defer { group.cancelAll() }
            for source in pending {
                group.addTask { await self.streamingSource(source, song: song, account: account) }
            }
            let budget = 14
            group.addTask { try await Task.sleep(for: .seconds(budget)); return nil }
            var results: [SourceAttempt] = []
            for _ in pending {
                guard let reply = try await group.next(), let attempt = reply else {
                    let completed = Set(results.map(\.source))
                    results += pending.filter { !completed.contains($0) }.map {
                        SourceAttempt(source: $0, candidates: [], problem: DiagnosticProblem(code: .timeout), elapsedMs: budget * 1000)
                    }
                    break
                }
                results.append(attempt)
                if !attempt.candidates.isEmpty { break }
            }
            try Task.checkCancellation()
            return results
        }
    }

    func streamingSource(_ source: DiagnosticSource, song: SyncedYouTubeSong, account: NavidromeAccount?) async -> SourceAttempt {
        let started = Date()
        var candidates: [DownloadAudioCandidate] = []
        var problem: DiagnosticProblem?
        do {
            guard YouTubeVideo.validID(song.videoID), let duration = song.duration, duration.isFinite, duration > 0 else {
                throw DiagnosticProblem(code: .missingDuration)
            }
            candidates = try await streamingOptions(source, song: song, duration: duration, account: account)
            if candidates.isEmpty { problem = DiagnosticProblem(code: .noMatch) }
        } catch { problem = DiagnosticProblem.classify(error) }
        return SourceAttempt(source: source, candidates: candidates, problem: problem,
                             elapsedMs: max(0, Int(Date().timeIntervalSince(started) * 1000)))
    }

    private func streamingOptions(_ source: DiagnosticSource, song: SyncedYouTubeSong, duration: Double,
                                  account: NavidromeAccount?) async throws -> [DownloadAudioCandidate] {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--youtube-slow-source-fixture") {
            if source == .qq { try await Task.sleep(for: .seconds(45)); return [] }
            if source == .netease, let file = Bundle.main.url(forResource: "tide", withExtension: "m4a") {
                return [DownloadAudioCandidate(url: file, title: song.title, artist: song.artist,
                    duration: duration, format: "m4a", bitrate: 128_000, source: "測試音源")]
            }
        }
        #endif
        switch source {
        case .netease: return try await netease(song, streaming: true)
        case .qq: return try await qq(song, streaming: true)
        case .navidrome:
            guard let account else { throw DiagnosticProblem(code: .signedOut) }
            return try await NavidromeClient(account: account).downloadCandidates(for: song)
        default: throw DiagnosticProblem(code: .unavailable)
        }
    }

    private func attempt(_ work: @Sendable () async throws -> [DownloadAudioCandidate]) async -> Result<[DownloadAudioCandidate], Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    private func query(_ song: SyncedYouTubeSong) -> String {
        let metadata = YouTubeCaptionDecoders.metadata(id: song.videoID, title: song.title, artist: song.artist, duration: song.duration ?? 0)
        return String((metadata.title + " " + (DownloadSongMatch.artistNames(metadata.artist).first ?? "")).prefix(120))
    }

    private func netease(_ song: SyncedYouTubeSong, streaming: Bool = false) async throws -> [DownloadAudioCandidate] {
        let data = try await metadata(URL(string: "https://music.163.com/api/cloudsearch/pc")!, provider: "netease",
            form: [.init(name: "s", value: query(song)), .init(name: "type", value: "1"), .init(name: "limit", value: "12")])
        let recordings = try DownloadSourceDecoders.search(data, for: song).prefix(2)
        if streaming, !recordings.isEmpty {
            let ids = recordings.map { String($0.id) }.joined(separator: ",")
            let response = try await metadata(URL(string: "https://music.163.com/api/song/enhance/player/url/v1")!, provider: "netease",
                form: [.init(name: "ids", value: "[\(ids)]"), .init(name: "level", value: "standard"), .init(name: "encodeType", value: "mp3")])
            let available = try recordings.compactMap { try DownloadSourceDecoders.audio(response, recording: $0) }
            guard !available.isEmpty else { throw DiagnosticProblem(code: .unavailable) }
            return available
        }
        var result: [DownloadAudioCandidate] = []
        for recording in recordings {
            async let high = attempt { try await self.neteaseAudio(recording, level: "hires") }
            async let lossless = attempt { try await self.neteaseAudio(recording, level: "lossless") }
            async let standard = attempt { try await self.neteaseAudio(recording, level: "exhigh") }
            let replies = await [high, lossless, standard]
            try Task.checkCancellation()
            let found = replies.flatMap { (try? $0.get()) ?? [] }
            if found.isEmpty, let error = replies.compactMap({ if case .failure(let error) = $0 { return error }; return nil }).first {
                if result.isEmpty { throw error }
            }
            var seen = Set<URL>()
            result += found.sorted(by: DownloadAudioCandidate.preferred).filter { seen.insert($0.url).inserted }
        }
        return result
    }

    private func neteaseAudio(_ recording: DownloadSourceDecoders.Song, level: String) async throws -> [DownloadAudioCandidate] {
        let audio = try await metadata(URL(string: "https://music.163.com/api/song/enhance/player/url/v1")!, provider: "netease",
            form: [.init(name: "ids", value: "[\(recording.id)]"), .init(name: "level", value: level), .init(name: "encodeType", value: "flac")])
        return try DownloadSourceDecoders.audio(audio, recording: recording).map { [$0] } ?? []
    }

    private func qq(_ song: SyncedYouTubeSong, streaming: Bool = false) async throws -> [DownloadAudioCandidate] {
        var search = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")!
        search.queryItems = [.init(name: "w", value: query(song)), .init(name: "format", value: "json"),
                             .init(name: "p", value: "1"), .init(name: "n", value: "8")]
        search.percentEncodedQuery = search.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let data = try await metadata(search.url!, provider: "qq")
        let matched = try DownloadSourceDecoders.qqSearch(data, for: song).prefix(2)
        var results: [DownloadAudioCandidate] = []
        for recording in matched {
            try Task.checkCancellation()
            let names = DownloadSourceDecoders.qqFormats.filter { !streaming || $0.bitrate > 0 }
                .map { $0.prefix + recording.mediaID + "." + $0.format }
            let body: [String: Any] = ["comm": ["uin": 0, "format": "json", "ct": 24, "cv": 0],
                "req_0": ["module": "vkey.GetVkeyServer", "method": "CgiGetVkey", "param": [
                    "guid": String(UInt64.random(in: 1_000_000_000...9_999_999_999)), "songmid": names.map { _ in recording.mid },
                    "songtype": names.map { _ in 0 }, "filename": names, "uin": "0", "loginflag": 1, "platform": "20"]]]
            var endpoint = URLComponents(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!
            endpoint.queryItems = [.init(name: "format", value: "json"),
                .init(name: "data", value: String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self))]
            let response = try await metadata(endpoint.url!, provider: "qq")
            results += try DownloadSourceDecoders.qqAudio(response, recording: recording)
        }
        if streaming && !matched.isEmpty && results.isEmpty { throw DiagnosticProblem(code: .unavailable) }
        return results
    }

    func youtube(_ song: SyncedYouTubeSong, streaming: Bool = false) async throws -> [DownloadAudioCandidate] {
        #if canImport(YouTubeKit)
        let details = try await publicVideo(song.videoID)
        guard song.duration == nil || DownloadSongMatch.sameDuration(song.duration, details.duration) else {
            throw PlatformError.message("YouTube 影片的長度與清單中的歌曲不符。")
        }
        let video = YouTube(videoID: song.videoID, useOAuth: false, allowOAuthCache: false, methods: [.local])
        guard !(try await video.ageRestricted) else { throw PlatformError.message("YouTube 需要年齡驗證。") }
        let streams = try await video.streams.filter { $0.includesAudioTrack && !$0.includesVideoTrack && $0.fileExtension == .m4a }
        let recording = YouTubeCaptionDecoders.metadata(id: song.videoID, title: details.title, artist: details.artist, duration: details.duration)
        let playable = streams.filter { Self.publicMediaURL($0.url, provider: "youtube") }
            .map { stream in
                (stream, DownloadAudioCandidate(url: stream.url, title: recording.title, artist: recording.artist,
                    duration: details.duration, format: "m4a", bitrate: stream.averageBitrate ?? stream.bitrate ?? 0,
                    source: "YouTube", recording: recording))
            }.sorted { streaming ? DownloadAudioCandidate.preferredForStreaming($0.1, $1.1)
                                  : DownloadAudioCandidate.preferred($0.1, $1.1) }
        guard !playable.isEmpty else { throw DiagnosticProblem(code: .unavailable) }
        // A delayed first rendition must not hold up an already available rendition.
        let now = Date()
        let ready = streaming ? playable.filter { $0.0.availableAt <= now } : []
        if !ready.isEmpty { return ready.prefix(2).map { $0.1 } }
        guard let first = playable.first else { throw DiagnosticProblem(code: .unavailable) }
        try await first.0.waitUntilAvailable()
        try Task.checkCancellation()
        return playable.prefix(streaming ? 2 : 3).map { $0.1 }
        #else
        throw PlatformError.message("目前建置未包含 YouTube 音訊來源。")
        #endif
    }

    func translatedVideo(_ id: String) async throws -> URL {
        #if canImport(YouTubeKit)
        let details = try await publicVideo(id)
        guard details.duration <= 600 else { throw SubtitleReadError("video-too-long") }
        let video = YouTube(videoID: id, useOAuth: false, allowOAuthCache: false, methods: [.local])
        guard !(try await video.ageRestricted) else { throw SubtitleReadError("verification-required") }
        let candidates = try await video.streams.filter { $0.includesVideoTrack && $0.fileExtension == .mp4
            && Self.publicMediaURL($0.url, provider: "youtube") }
        // 720p retains readable CJK glyphs without fetching a full-resolution 4K video.
        let preferred = candidates.filter { ($0.videoResolution ?? 0) <= 720 }
            .sorted { ($0.videoResolution ?? 0) > ($1.videoResolution ?? 0) }
        guard let stream = preferred.first else { throw SubtitleReadError("caption-read-failed") }
        try await stream.waitUntilAvailable()
        return try await download(DownloadAudioCandidate(url: stream.url, title: details.title, artist: details.artist,
            duration: details.duration, format: "mp4", bitrate: stream.bitrate ?? 0, source: "YouTube"), limit: 120_000_000)
        #else
        throw SubtitleReadError("captions-unavailable")
        #endif
    }

    func publicVideo(_ id: String) async throws -> (title: String, artist: String, duration: Double) {
        guard YouTubeVideo.validID(id) else { throw SubtitleReadError("invalid-response") }
        if let cached = videoMetadata[id], cached.expires > Date() { return (cached.title, cached.artist, cached.duration) }
        var url = URLComponents(string: "https://www.youtube.com/watch")!
        url.queryItems = [.init(name: "v", value: id), .init(name: "hl", value: "zh-TW")]
        let bytes = try await metadata(url.url!, provider: "youtube", maximum: 8_000_000)
        guard let page = String(data: bytes, encoding: .utf8) else { throw SubtitleReadError("invalid-response") }
        let root = try YouTubeCaptionDecoders.playerResponse(page, videoID: id)
        guard (root["playabilityStatus"] as? [String: Any])?["status"] as? String == "OK",
              let item = root["videoDetails"] as? [String: Any],
              item["isLiveContent"] as? Bool != true,
              let title = item["title"] as? String, let artist = item["author"] as? String else {
            throw SubtitleReadError("verification-required")
        }
        let duration = SubtitleSourceDecoders.number(item["lengthSeconds"])
        guard duration > 0, duration <= 5400 else { throw SubtitleReadError("invalid-response") }
        if videoMetadata.count >= 32, let oldest = videoMetadata.min(by: { $0.value.expires < $1.value.expires }) {
            videoMetadata.removeValue(forKey: oldest.key)
        }
        videoMetadata[id] = (title, artist, duration, Date().addingTimeInterval(300))
        return (title, artist, duration)
    }

    func download(_ candidate: DownloadAudioCandidate, limit: Int = 500_000_000) async throws -> URL {
        try Task.checkCancellation()
        guard let parts = URLComponents(url: candidate.url, resolvingAgainstBaseURL: false),
              DownloadSongMatch.safeAudioURL(candidate.url.absoluteString) != nil,
              ["flac", "alac", "wav", "aiff", "aif", "mp3", "m4a", "aac", "mp4"].contains(candidate.format),
              (candidate.expectedBytes ?? 0) <= limit else { throw PlatformError.message("音源連結或檔案格式無效。") }
        let policy = AudioDownloadGuard(origin: candidate.url, limit: limit)
        var request = URLRequest(url: candidate.url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if candidate.source == "網易雲" { request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer") }
        if candidate.source == "QQ 音樂" { request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer") }
        let (temporary, response) = try await session.download(for: request, delegate: policy)
        do {
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw DiagnosticProblem(code: .invalidResponse) }
            guard http.statusCode == 200 else {
                throw DiagnosticProblem.mediaHTTP(http.statusCode)
            }
            guard http.value(forHTTPHeaderField: "Content-Range") == nil,
                  let final = response.url, final.scheme == "https", final.host == parts.host, final.port == parts.port else {
                throw PlatformError.message("來源未傳回完整音檔，已略過。")
            }
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let mime = response.mimeType?.lowercased() ?? ""
            guard size >= 1024, size <= limit, !mime.hasPrefix("text/"), !mime.contains("json"), !mime.contains("xml"),
                  response.expectedContentLength <= 0 || response.expectedContentLength == Int64(size),
                  candidate.expectedBytes == nil || candidate.expectedBytes == size else {
                throw PlatformError.message("下載內容不完整或不是有效音訊，已略過。")
            }
            let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + candidate.format)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }

    static func publicMediaURL(_ url: URL, provider: String) -> Bool {
        guard let host = url.host?.lowercased(), DownloadSongMatch.safeAudioURL(url.absoluteString) != nil,
              url.port == nil || url.port == 443 else { return false }
        let domain = provider == "qq" ? "qqmusic.qq.com" : provider == "netease" ? "music.126.net" : "googlevideo.com"
        return host == domain || host.hasSuffix("." + domain)
    }

    // Record only the response status. Do not read the audio body or retry a rejected request.
    func streamingHTTPProblem(at url: URL) async throws -> DiagnosticProblem? {
        guard Self.publicMediaURL(url, provider: "youtube") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await metadataSession.bytes(for: request, delegate: AudioDownloadGuard(origin: url, limit: 1))
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (400...599).contains(http.statusCode) else { return nil }
        return DiagnosticProblem.mediaHTTP(http.statusCode)
    }

    func artwork(at url: URL) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let value = url.absoluteString
        guard YouTubeArtwork.thumbnailURL(value) != nil || YouTubeArtwork.portraitURL(value) != nil else { return nil }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--youtube-sync-fixture"),
           url == YouTubeArtwork.defaultThumbnail(for: "M7lc1UVf-VE") {
            return Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFElEQVR4nGNM37OWARtgwio6aCUAbbEB4B0QKzMAAAAASUVORK5CYII=")
        }
        #endif
        if let cached = artworkCache.object(forKey: url as NSURL) { return cached as Data }
        guard let bytes = try? await metadata(url, provider: "artwork", maximum: 600_000),
              !Task.isCancelled else { return nil }
        artworkCache.setObject(bytes as NSData, forKey: url as NSURL, cost: bytes.count)
        return bytes
    }

    private func metadata(_ url: URL, provider: String, form: [URLQueryItem]? = nil, maximum: Int = 2_000_000) async throws -> Data {
        try Task.checkCancellation()
        guard Date() >= (blockedUntil[provider] ?? .distantPast) else { throw SubtitleReadError("rate-limited") }
        var request = URLRequest(url: url, timeoutInterval: 11)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        if provider == "netease" { request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer") }
        if provider == "qq" { request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer") }
        if let form {
            var parts = URLComponents(); parts.queryItems = form
            request.httpMethod = "POST"; request.httpBody = Data((parts.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (bytes, response) = try await metadataSession.bytes(for: request, delegate: AudioDownloadGuard(origin: url, limit: maximum))
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw SubtitleReadError("network") }
        if let delay = AudioRetryPolicy.delay(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After")) {
            blockedUntil[provider] = Date().addingTimeInterval(delay)
            throw DiagnosticProblem(code: .rateLimit, httpStatus: http.statusCode)
        }
        if http.statusCode == 403 || http.statusCode == 451 { throw DiagnosticProblem(code: .region, httpStatus: http.statusCode) }
        guard http.statusCode == 200 else { throw DiagnosticProblem(code: .unavailable, httpStatus: http.statusCode) }
        guard response.expectedContentLength <= Int64(maximum) else { throw DiagnosticProblem(code: .invalidResponse) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximum else { throw SubtitleReadError("invalid-response") }
            data.append(byte)
        }
        return data
    }
}

private final class AudioDownloadGuard: NSObject, URLSessionDownloadDelegate, Sendable {
    let origin: URL
    let limit: Int
    init(origin: URL, limit: Int) { self.origin = origin; self.limit = limit }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Int64(limit) || totalBytesExpectedToWrite > Int64(limit) { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.host == origin.host, url.port == origin.port,
              url.user == nil, url.password == nil, url.fragment == nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}
