import Foundation

enum LibraryPlatform: String, CaseIterable, Identifiable, Codable {
    case spotify, youtube
    var id: String { rawValue }
    var title: String { self == .spotify ? "Spotify" : "YouTube Music" }
    var libraryURL: URL {
        URL(string: self == .spotify ? "https://open.spotify.com/collection/playlists" : "https://music.youtube.com/library")!
    }
    var authorizeURL: URL {
        URL(string: self == .spotify ? "https://accounts.spotify.com/authorize" : "https://accounts.google.com/o/oauth2/v2/auth")!
    }
    var tokenURL: URL {
        URL(string: self == .spotify ? "https://accounts.spotify.com/api/token" : "https://oauth2.googleapis.com/token")!
    }
    var scope: String {
        self == .spotify ? "playlist-read-private playlist-read-collaborative user-library-read" : "https://www.googleapis.com/auth/youtube.readonly"
    }

    func redirect(clientID: String) throws -> URL {
        if self == .spotify {
            guard clientID.range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil else {
                throw PlatformError.message("請填入 Spotify 開發者應用程式的 Client ID。")
            }
            return URL(string: "folia-spotify://callback")!
        }
        guard clientID.range(of: "^[A-Za-z0-9_-]+\\.apps\\.googleusercontent\\.com$", options: .regularExpression) != nil else {
            throw PlatformError.message("請填入 Google 的 iOS OAuth Client ID，結尾為 .apps.googleusercontent.com。")
        }
        let reversed = clientID.split(separator: ".").reversed().joined(separator: ".")
        return URL(string: reversed + ":/oauth2redirect")!
    }
}

enum PlatformError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// Public application identifiers are supplied by the maintainer at build time.
// A re-signed app must still match the Google iOS client's registered bundle ID.
struct GoogleClientConfiguration {
    enum Issue: Equatable { case missing, invalidClient, bundleMismatch, missingCallback }
    let clientID: String
    let issue: Issue?
    var isReady: Bool { issue == nil }
    var userMessage: String? {
        switch issue {
        case .none: return nil
        case .bundleMismatch:
            return "這個安裝版本的 Google 登入設定不相符，請向 App 提供者索取相容版本。"
        default:
            return "這個版本尚未啟用 Google 登入，請向 App 提供者索取已設定的版本。"
        }
    }

    init(clientID: String?, registeredBundleID: String?, bundleID: String?, schemes: [String]) {
        let normalized = (clientID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientID = normalized
        guard !normalized.isEmpty else { issue = .missing; return }
        guard let redirect = try? LibraryPlatform.youtube.redirect(clientID: normalized),
              let scheme = redirect.scheme else { issue = .invalidClient; return }
        guard let registeredBundleID, !registeredBundleID.isEmpty, registeredBundleID == bundleID else {
            issue = .bundleMismatch; return
        }
        guard schemes.contains(scheme) else { issue = .missingCallback; return }
        issue = nil
    }

    func acceptsCredential(clientID: String) -> Bool { isReady && self.clientID == clientID }
}

enum LibraryCollection: Equatable {
    case playlists, liked, playlist(String)
}

struct LibraryEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let url: URL
    var duration: Double? = nil
    var channelID: String? = nil
}

struct LibraryPage {
    let entries: [LibraryEntry]
    let next: String?
}

// Only API metadata is read. Links retain the source platform's playback destination.
enum PlatformLibrary {
    static func endpoint(platform: LibraryPlatform, collection: LibraryCollection, cursor: String?) throws -> URL {
        var parts: URLComponents
        if platform == .spotify {
            let path: String
            switch collection {
            case .playlists: path = "me/playlists"
            case .liked: path = "me/tracks"
            case .playlist(let id):
                guard validID(id) else { throw PlatformError.message("歌單識別碼無效。") }
                path = "playlists/\(id)/items"
            }
            parts = URLComponents(string: "https://api.spotify.com/v1/" + path)!
            guard let offset = Int(cursor ?? "0"), offset >= 0 else { throw PlatformError.message("歌單分頁無效。") }
            parts.queryItems = [.init(name: "limit", value: "20"), .init(name: "offset", value: String(offset))]
        } else {
            let path: String
            var parameters = [URLQueryItem(name: "maxResults", value: "50")]
            let fields: String
            switch collection {
            case .playlists:
                path = "playlists"
                fields = "nextPageToken,items(id,snippet(title,channelTitle))"
                parameters += [.init(name: "part", value: "snippet"), .init(name: "mine", value: "true")]
            case .liked:
                path = "videos"
                fields = "nextPageToken,items(id,snippet(title,channelTitle,channelId),contentDetails(duration))"
                parameters += [.init(name: "part", value: "snippet,contentDetails"), .init(name: "myRating", value: "like")]
            case .playlist(let id):
                guard validID(id) else { throw PlatformError.message("歌單識別碼無效。") }
                path = "playlistItems"
                fields = "nextPageToken,items(id,snippet(title,channelTitle,videoOwnerChannelTitle,videoOwnerChannelId,resourceId(videoId)))"
                parameters += [.init(name: "part", value: "snippet"), .init(name: "playlistId", value: id)]
            }
            parameters.append(.init(name: "fields", value: fields))
            if let cursor { parameters.append(.init(name: "pageToken", value: cursor)) }
            parts = URLComponents(string: "https://www.googleapis.com/youtube/v3/" + path)!
            parts.queryItems = parameters
        }
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw PlatformError.message("無法建立曲庫請求。") }
        return url
    }

    static func decode(_ data: Data, platform: LibraryPlatform, collection: LibraryCollection) throws -> LibraryPage {
        if platform == .spotify {
            let page = try JSONDecoder().decode(SpotifyPage.self, from: data)
            let entries = page.items.enumerated().compactMap { index, row -> LibraryEntry? in
                guard let row else { return nil }
                let item = collection == .playlists ? row : row.item ?? row.track
                guard let item, let id = item.id, validID(id), let title = item.name else { return nil }
                let kind = collection == .playlists ? "playlist" : "track"
                guard kind == "playlist" || item.type == nil || item.type == "track" else { return nil }
                let subtitle = collection == .playlists ? item.owner?.display_name ?? "" : item.artists?.compactMap(\.name).joined(separator: "、") ?? ""
                let rowID = collection == .playlists ? id : "\((page.offset ?? 0) + index)-\(id)"
                return LibraryEntry(id: rowID, title: title, subtitle: subtitle,
                                    url: URL(string: "https://open.spotify.com/\(kind)/\(id)")!)
            }
            // Extract a cursor, never follow an untrusted next URL with an access token.
            let next = page.next.flatMap { URLComponents(string: $0) }
            let offset = next?.queryItems?.first(where: { $0.name == "offset" })?.value
            let validNext = next?.scheme == "https" && next?.host == "api.spotify.com"
                && offset.flatMap(Int.init).map { $0 >= 0 } == true
            return LibraryPage(entries: entries, next: validNext ? offset : nil)
        }
        let page = try JSONDecoder().decode(YouTubePage.self, from: data)
        let entries = page.items.compactMap { item -> LibraryEntry? in
            guard let snippet = item.snippet else { return nil }
            let id = collection == .playlists || collection == .liked ? item.id : snippet.resourceId?.videoId
            guard let id, validID(id), let title = snippet.title,
                  title != "Private video", title != "Deleted video" else { return nil }
            let path = collection == .playlists ? "playlist?list=\(id)" : "watch?v=\(id)"
            let rowID = collection == .playlists || collection == .liked ? id : item.id ?? id
            return LibraryEntry(id: rowID, title: title, subtitle: snippet.videoOwnerChannelTitle ?? snippet.channelTitle ?? "",
                                url: URL(string: "https://music.youtube.com/" + path)!, duration: isoDuration(item.contentDetails?.duration),
                                channelID: snippet.videoOwnerChannelId ?? (collection == .liked ? snippet.channelId : nil))
        }
        return LibraryPage(entries: entries, next: page.nextPageToken)
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 200 && id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    static func isoDuration(_ text: String?) -> Double? {
        guard let text, let pattern = try? NSRegularExpression(pattern: "^PT(?:(\\d+)H)?(?:(\\d+)M)?(?:(\\d+(?:\\.\\d+)?)S)?$"),
              let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let factors = [3600.0, 60.0, 1.0]
        var result = 0.0
        for i in 1...3 {
            if let range = Range(match.range(at: i), in: text), let value = Double(text[range]) { result += value * factors[i - 1] }
        }
        return result.isFinite && result > 0 ? result : nil
    }

    private struct SpotifyPage: Decodable {
        let items: [SpotifyItem?]
        let next: String?
        let offset: Int?
    }
    private final class SpotifyItem: Decodable {
        let id: String?
        let name: String?
        let type: String?
        let owner: Artist?
        let artists: [Artist]?
        let item: SpotifyItem?
        let track: SpotifyItem?
        struct Artist: Decodable { let name: String?; let display_name: String? }
    }
    private struct YouTubePage: Decodable {
        let items: [Item]
        let nextPageToken: String?
        struct Item: Decodable {
            let id: String?
            let snippet: Snippet?
            let contentDetails: Details?
        }
        struct Details: Decodable { let duration: String? }
        struct Snippet: Decodable {
            let title: String?
            let channelTitle: String?
            let videoOwnerChannelTitle: String?
            let channelId: String?
            let videoOwnerChannelId: String?
            let resourceId: Resource?
        }
        struct Resource: Decodable { let videoId: String? }
    }
}

enum OAuthCallback {
    static func code(from url: URL, expected: URL, state: String) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == expected.scheme, parts.host == expected.host, parts.path == expected.path, parts.port == expected.port,
              parts.user == nil, parts.password == nil, parts.fragment == nil else {
            throw PlatformError.message("登入回應網址不符，請重新連接。")
        }
        let items = parts.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, states[0].value == state else { throw PlatformError.message("登入驗證已失效，請重新連接。") }
        guard !items.contains(where: { $0.name == "error" }) else { throw PlatformError.message("登入或曲庫存取授權未完成。") }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes[0].value, !code.isEmpty else { throw PlatformError.message("登入回應缺少授權碼。") }
        return code
    }
}
