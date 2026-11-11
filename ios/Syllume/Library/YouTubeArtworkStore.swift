import CryptoKit
import Foundation
import ImageIO

struct SongArtworkSource: Hashable, Sendable {
    var file: URL?
    var videoID: String?
    var candidates: [URL] = []

    init(file: URL?, videoID: String?, candidates: [URL] = []) {
        self.file = file
        self.videoID = videoID
        self.candidates = candidates
    }

    init(file: URL?, song: SyncedYouTubeSong) {
        self.init(file: file, videoID: song.videoID, candidates: song.artworkURLs)
    }
}

// Artwork has its own anonymous transport and cache. A failed image request
// must not block other songs, catalogue lookup, or audio playback.
actor YouTubeArtworkStore {
    static let shared = YouTubeArtworkStore()

    private let session: URLSession
    private let directory: URL
    private var inFlight: [URL: Task<ImageResponse?, Never>] = [:]
    private static let maximumBytes = 600_000
    private static let maximumAge: TimeInterval = 7 * 24 * 3600
    private static let maximumDiskBytes = 32_000_000
    private static let maximumFiles = 160

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 7
        session = URLSession(configuration: configuration, delegate: ArtworkRedirectGuard(), delegateQueue: nil)

        var folder = "SyllumeCoverImages"
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--youtube-sync-fixture") { folder += "-Fixture" }
        #endif
        directory = URL.cachesDirectory.appending(path: folder, directoryHint: .isDirectory)
        #if DEBUG
        if arguments.contains("--youtube-sync-fixture"), arguments.contains("--youtube-artwork-reset") {
            try? FileManager.default.removeItem(at: directory)
        }
        #endif
    }

    func image(for source: SongArtworkSource) async -> Data? {
        if let file = source.file, file.isFileURL, let data = try? Data(contentsOf: file),
           CGImageSourceCreateWithData(data as CFData, nil) != nil { return data }
        guard let videoID = source.videoID else { return nil }
        return await cover(for: videoID, candidates: source.candidates)
    }

    private func cover(for videoID: String, candidates: [URL]) async -> Data? {
        let fallbacks = YouTubeArtwork.thumbnails(for: videoID)
        guard let key = fallbacks.first else { return nil }
        var seen = Set<URL>()
        return await load((candidates + fallbacks).filter { seen.insert($0).inserted }, cacheKey: key)
    }

    func portrait(at url: URL) async -> Data? {
        guard YouTubeArtwork.portraitURL(url.absoluteString) != nil else { return nil }
        return await load([url], cacheKey: url)
    }

    private func load(_ urls: [URL], cacheKey: URL) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let digest = SHA256.hash(data: Data(cacheKey.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined() + ".cover"
        let file = directory.appending(path: name)
        if let cached = cachedImage(at: file) { return cached }
        // Deduplicate each request, not a whole list of candidates. A row with only
        // a video ID cannot suppress a later row's working API-provided thumbnail.
        for url in urls where YouTubeArtwork.allows(url) {
            guard !Task.isCancelled else { return nil }
            if let cached = cachedImage(at: file) { return cached }
            guard let response = await fetchOnce(url) else { continue }
            if response.canCache && cachedImage(at: file) == nil { persist(response.data, at: file) }
            return response.data
        }
        return nil
    }

    private func fetchOnce(_ url: URL) async -> ImageResponse? {
        if let pending = inFlight[url] { return await pending.value }
        let task = Task(priority: .utility) { await fetch(url) }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        return await task.value
    }

    private func cachedImage(at file: URL) -> Data? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
              let size = values.fileSize, (1...Self.maximumBytes).contains(size),
              let modified = values.contentModificationDate,
              Date().timeIntervalSince(modified) < Self.maximumAge,
              let data = try? Data(contentsOf: file), Self.isImage(data) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return data
    }

    private func persist(_ data: Data, at file: URL) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            // Complete the on-disk replacement before returning the decoded cover.
            try data.write(to: file, options: .atomic)
        } catch { return }

        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                         options: .skipsHiddenFiles) else { return }
        let files: [(url: URL, date: Date, size: Int)] = urls.compactMap { url in
            guard url.pathExtension == "cover", let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, let date = values.contentModificationDate,
                  let size = values.fileSize else { return nil }
            return (url, date, size)
        }.sorted { $0.date > $1.date }
        var retainedBytes = 0
        let now = Date()
        for (index, file) in files.enumerated() {
            if index >= Self.maximumFiles || now.timeIntervalSince(file.date) >= Self.maximumAge
                || retainedBytes + file.size > Self.maximumDiskBytes {
                try? manager.removeItem(at: file.url)
            } else {
                retainedBytes += file.size
            }
        }
    }

    private struct ImageResponse: Sendable {
        let data: Data
        let canCache: Bool
    }

    private static func isImage(_ data: Data) -> Bool {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatusAtIndex(image, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else { return false }
        return (1...2048).contains(width) && (1...2048).contains(height)
    }

    private func fetch(_ url: URL) async -> ImageResponse? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--youtube-sync-fixture") {
            // The first two renditions are unavailable. Tests can relaunch with
            // every rendition offline to exercise the disk cache independently.
            let ids = arguments.contains("--syllume-recording-regression") ? ["6AR6Oc0-4NQ", "3NNhrqHZqlI"] : ["M7lc1UVf-VE"]
            guard !arguments.contains("--youtube-artwork-offline"), ids.contains(where: { url.path == "/vi/\($0)/default.jpg" }),
                  let fixture = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFElEQVR4nGNM37OWARtgwio6aCUAbbEB4B0QKzMAAAAASUVORK5CYII=") else { return nil }
            return ImageResponse(data: fixture, canCache: true)
        }
        #endif
        do {
            var request = URLRequest(url: url)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let finalURL = http.url, YouTubeArtwork.allows(finalURL),
                  let mime = http.mimeType, mime.hasPrefix("image/"),
                  http.expectedContentLength <= Int64(Self.maximumBytes) else { return nil }

            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maximumBytes else { return nil }
                data.append(byte)
            }
            guard Self.isImage(data) else { return nil }
            let directives = (http.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased()
            return ImageResponse(data: data,
                                 canCache: !directives.contains("no-store") && !directives.contains("no-cache"))
        } catch { return nil }
    }
}

private final class ArtworkRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, YouTubeArtwork.allows(url) else { completionHandler(nil); return }
        completionHandler(request)
    }
}
