import Foundation
import ImageIO

// Artwork has its own anonymous transport and cache. A failed image request
// must not block other songs, catalogue lookup, or audio playback.
actor YouTubeArtworkStore {
    static let shared = YouTubeArtworkStore()

    private let session: URLSession
    private let cache: URLCache
    private var inFlight: [URL: Task<Data?, Never>] = [:]
    private static let maximumBytes = 600_000
    private static let maximumAge: TimeInterval = 7 * 24 * 3600

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 7
        session = URLSession(configuration: configuration, delegate: ArtworkRedirectGuard(), delegateQueue: nil)

        var folder = "SyllumeArtwork"
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--youtube-sync-fixture") { folder += "-Fixture" }
        #endif
        let directory = URL.cachesDirectory.appending(path: folder, directoryHint: .isDirectory)
        cache = URLCache(memoryCapacity: 4_000_000, diskCapacity: 32_000_000, directory: directory)
        #if DEBUG
        if arguments.contains("--youtube-sync-fixture"), arguments.contains("--youtube-artwork-reset") {
            cache.removeAllCachedResponses()
        }
        #endif
    }

    func cover(for videoID: String, candidates: [URL]? = nil) async -> Data? {
        let fallbacks = YouTubeArtwork.thumbnails(for: videoID)
        guard let key = fallbacks.first else { return nil }
        return await load(candidates ?? fallbacks, cacheKey: key)
    }

    func portrait(at url: URL) async -> Data? {
        guard YouTubeArtwork.portraitURL(url.absoluteString) != nil else { return nil }
        return await load([url], cacheKey: url)
    }

    private func load(_ urls: [URL], cacheKey: URL) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let request = URLRequest(url: cacheKey)
        if let cached = cache.cachedResponse(for: request) {
            if let storedAt = cached.userInfo?["storedAt"] as? Date,
               Date().timeIntervalSince(storedAt) < Self.maximumAge {
                return cached.data
            }
            cache.removeCachedResponse(for: request)
        }
        if let pending = inFlight[cacheKey] { return await pending.value }

        let task = Task<Data?, Never>(priority: .utility) {
            for url in urls where YouTubeArtwork.allows(url) {
                guard let response = await fetch(url) else { continue }
                if response.canCache,
                   let cachedResponse = HTTPURLResponse(url: cacheKey, statusCode: 200, httpVersion: nil,
                                                        headerFields: ["Content-Type": response.mimeType]) {
                    cache.storeCachedResponse(CachedURLResponse(response: cachedResponse, data: response.data,
                        userInfo: ["storedAt": Date()], storagePolicy: .allowed), for: request)
                }
                return response.data
            }
            return nil
        }
        inFlight[cacheKey] = task
        defer { inFlight[cacheKey] = nil }
        return await task.value
    }

    private struct ImageResponse {
        let data: Data
        let mimeType: String
        let canCache: Bool
    }

    private func fetch(_ url: URL) async -> ImageResponse? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--youtube-sync-fixture") {
            // The first two renditions are unavailable. Tests can relaunch with
            // every rendition offline to exercise the disk cache independently.
            guard !arguments.contains("--youtube-artwork-offline"), url.path == "/vi/M7lc1UVf-VE/default.jpg",
                  let fixture = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFElEQVR4nGNM37OWARtgwio6aCUAbbEB4B0QKzMAAAAASUVORK5CYII=") else { return nil }
            return ImageResponse(data: fixture, mimeType: "image/png", canCache: true)
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
            guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetStatusAtIndex(image, 0) == .statusComplete,
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
                  (1...2048).contains(width), (1...2048).contains(height) else { return nil }
            let directives = (http.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased()
            return ImageResponse(data: data, mimeType: mime,
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
