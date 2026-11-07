import Foundation

// Public music metadata and original Navidrome downloads are independent of Google OAuth.
actor AudioDownloadService {
    private var blockedUntil = Date.distantPast
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 600
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    func candidates(for song: SyncedYouTubeSong, account: NavidromeAccount?) async throws -> [DownloadAudioCandidate] {
        var candidates: [DownloadAudioCandidate] = []
        var failure: Error?
        if let account {
            do { candidates += try await NavidromeClient(account: account).downloadCandidates(for: song) }
            catch is CancellationError { throw CancellationError() }
            catch { failure = error }
        }
        do {
            let data = try await metadata(path: "cloudsearch/pc", parameters: [
                .init(name: "s", value: DownloadSongMatch.searchTitle(song.title) + " " + song.artist.replacingOccurrences(of: " - Topic", with: "")),
                .init(name: "type", value: "1"), .init(name: "limit", value: "12"), .init(name: "offset", value: "0")
            ])
            for recording in try DownloadSourceDecoders.search(data, for: song).prefix(3) {
                for level in ["hires", "lossless", "exhigh", "standard"] {
                    try Task.checkCancellation()
                    let audio = try await metadata(path: "song/enhance/player/url/v1", parameters: [
                        .init(name: "ids", value: "[\(recording.id)]"), .init(name: "level", value: level),
                        .init(name: "encodeType", value: "flac")
                    ])
                    if let candidate = try DownloadSourceDecoders.audio(audio, recording: recording) {
                        candidates.append(candidate); break
                    }
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { failure = error }
        if candidates.isEmpty, let failure { throw failure }
        return candidates.sorted(by: DownloadAudioCandidate.preferred)
    }

    func download(_ candidate: DownloadAudioCandidate) async throws -> URL {
        try Task.checkCancellation()
        guard DownloadSongMatch.safeAudioURL(candidate.url.absoluteString) != nil else {
            throw PlatformError.message("音源未提供安全的下載連結。")
        }
        let policy = AudioDownloadGuard(host: candidate.url.host ?? "")
        let (temporary, response) = try await session.download(from: candidate.url, delegate: policy)
        do {
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let final = response.url, final.scheme == "https", final.host == candidate.url.host,
                  (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= AudioDownloadGuard.limit else {
                throw PlatformError.message("音源下載失敗，或檔案超過 500 MB。")
            }
            // A media extension is needed by AVFoundation when the CDN's temporary file has none.
            let destination = temporary.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + "." + candidate.format)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }

    private func metadata(path: String, parameters: [URLQueryItem]) async throws -> Data {
        try Task.checkCancellation()
        guard Date() >= blockedUntil else { throw PlatformError.message("音源服務暫時限制請求，請稍後重新同步。") }
        var form = URLComponents(); form.queryItems = parameters
        var request = URLRequest(url: URL(string: "https://music.163.com/api/" + path)!)
        request.httpMethod = "POST"
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request, delegate: AudioDownloadGuard(host: "music.163.com"))
        defer { bytes.task.cancel() }
        if let http = response as? HTTPURLResponse,
           let delay = AudioRetryPolicy.delay(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After")) {
            blockedUntil = Date().addingTimeInterval(delay)
            throw PlatformError.message("音源服務暫時限制請求，請稍後重新同步。")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.expectedContentLength <= 2_000_000 else {
            throw PlatformError.message("音源服務暫時無法回應，請稍後重新同步。")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_000_000 else { throw PlatformError.message("音源搜尋回應過大。") }
            data.append(byte)
        }
        return data
    }
}

private final class AudioDownloadGuard: NSObject, URLSessionDownloadDelegate, Sendable {
    static let limit = 500_000_000
    let host: String
    init(host: String) { self.host = host }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.limit || totalBytesExpectedToWrite > Self.limit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.host == host,
              url.user == nil, url.password == nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}
