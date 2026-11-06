@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

struct InspectedPlaylistAudio: Sendable {
    let duration: Double
    let quality: String
    let rank: Int

    static func inspect(_ url: URL, source: DownloadableAudio) async throws -> Self {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable), (try await asset.loadTracks(withMediaType: .video)).isEmpty,
              let audio = try await asset.loadTracks(withMediaType: .audio).first else { throw PlaylistAudioError.invalidFile }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              abs(duration - source.song.durationMs / 1000) <= min(8, max(2, source.song.durationMs / 1000 * 0.02)) else {
            throw PlaylistAudioError.incomplete
        }
        guard let description = try await audio.load(.formatDescriptions).first,
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { throw PlaylistAudioError.invalidFile }
        let format = pointer.pointee
        let lossless = [kAudioFormatFLAC, kAudioFormatAppleLossless, kAudioFormatLinearPCM].contains(format.mFormatID)
        if source.fileExtension == "flac", format.mFormatID != kAudioFormatFLAC { throw PlaylistAudioError.invalidFile }
        if source.fileExtension == "mp3", format.mFormatID != kAudioFormatMPEGLayer3 { throw PlaylistAudioError.invalidFile }
        let rate = (try? await audio.load(.estimatedDataRate)) ?? 0
        let highResolution = lossless && (format.mSampleRate > 48000 || format.mBitsPerChannel > 16)
        let rank = lossless ? (highResolution ? 80 : 60) : rate >= 256000 ? 40 : rate >= 160000 ? 30 : rate > 0 ? 20 : source.qualityRank
        var labels = [source.fileExtension.uppercased()]
        if lossless, format.mSampleRate.isFinite, format.mSampleRate > 0 {
            if format.mBitsPerChannel > 0 { labels.append("\(format.mBitsPerChannel) bit") }
            labels.append(String(format: "%g kHz", format.mSampleRate / 1000))
        } else if rate.isFinite, rate > 0 { labels.append("\(Int((rate / 1000).rounded())) kbps") }
        return Self(duration: duration, quality: labels.joined(separator: " · "), rank: rank)
    }
}

// Each one-shot transfer owns its session and exactly one continuation; cancellation cannot import a late file.
final class PlaylistAudioTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let source: DownloadableAudio
    private let wifiOnly: Bool
    private let progress: @Sendable (Int?) -> Void
    private let allowedURL: @Sendable (URL) -> Bool
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var file: URL?
    private var cancelled = false
    private var started = false
    private var lastProgress = Date.distantPast
    private var checkedBytes: Int64 = 0

    init(source: DownloadableAudio, wifiOnly: Bool, allowedURL: (@Sendable (URL) -> Bool)? = nil,
         progress: @escaping @Sendable (Int?) -> Void) {
        self.source = source; self.wifiOnly = wifiOnly; self.progress = progress
        self.allowedURL = allowedURL ?? { PlaylistAudioRules.validAudioURL($0, provider: source.provider) }
    }

    func run() async throws -> URL {
        guard allowedURL(source.url) else { throw PlaylistAudioError.invalidFile }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { pending in
                lock.lock()
                guard !cancelled, !started else { lock.unlock(); pending.resume(throwing: CancellationError()); return }
                started = true
                continuation = pending
                let config = URLSessionConfiguration.ephemeral
                config.httpShouldSetCookies = false; config.httpCookieStorage = nil
                config.allowsCellularAccess = !wifiOnly
                config.allowsExpensiveNetworkAccess = !wifiOnly
                config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: source.url)
                request.setValue(source.provider == "qq" ? "https://y.qq.com/" : "https://music.163.com/", forHTTPHeaderField: "Referer")
                let download = session.downloadTask(with: request)
                task = download
                lock.unlock()
                download.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let pending = continuation
        guard pending != nil else { lock.unlock(); return }
        continuation = nil
        let session = session, stored = file
        self.session = nil; task = nil; file = nil
        lock.unlock()
        if case .failure = result, let stored { try? FileManager.default.removeItem(at: stored) }
        session?.invalidateAndCancel()
        pending?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > PlaylistAudioRules.maximumBytes || totalBytesExpectedToWrite > PlaylistAudioRules.maximumBytes {
            finish(.failure(PlaylistAudioError.oversized)); return
        }
        if totalBytesWritten - checkedBytes >= 5_000_000 {
            checkedBytes = totalBytesWritten
            if let available = try? FileManager.default.temporaryDirectory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               available < 100_000_000 {
                finish(.failure(PlaylistAudioError.storage)); return
            }
        }
        if Date().timeIntervalSince(lastProgress) >= 0.5 {
            lastProgress = Date()
            progress(totalBytesExpectedToWrite > 0 ? Int(min(99, totalBytesWritten * 100 / totalBytesExpectedToWrite)) : nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse else {
            finish(.failure(PlaylistAudioError.noAudio)); return
        }
        if response.statusCode == 429 || response.statusCode == 503 { finish(.failure(PlaylistAudioError.rateLimited)); return }
        guard (200..<300).contains(response.statusCode) else { finish(.failure(PlaylistAudioError.noAudio)); return }
        let mime = response.mimeType?.lowercased() ?? ""
        guard !mime.hasPrefix("text/"), !mime.contains("json"), !mime.contains("xml") else {
            finish(.failure(PlaylistAudioError.invalidFile)); return
        }
        do {
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, Int64(size) <= PlaylistAudioRules.maximumBytes else { throw PlaylistAudioError.oversized }
            let target = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + source.fileExtension)
            try FileManager.default.moveItem(at: location, to: target)
            lock.lock()
            guard continuation != nil, !cancelled else {
                lock.unlock(); try? FileManager.default.removeItem(at: target); return
            }
            file = target
            lock.unlock()
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock(); let saved = file; lock.unlock()
        if let saved { finish(.success(saved)) } else { finish(.failure(PlaylistAudioError.invalidFile)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, allowedURL(url) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}
