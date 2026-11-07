import CryptoKit
import Foundation
import Observation
import Security

// HTTPS Subsonic transport. Server credentials are stored only in the Keychain.
struct NavidromeAccount: Codable, Equatable, Sendable {
    let server: URL
    let username: String
    let password: String

    init(server: String, username: String, password: String) throws {
        let input = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = URLComponents(string: input), address.scheme?.lowercased() == "https",
              let url = address.url, let host = address.host, !host.isEmpty,
              address.user == nil, address.password == nil, address.query == nil, address.fragment == nil,
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            throw NavidromeError.invalidAccount
        }
        self.server = url
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
    }

    func endpoint(_ name: String, parameters: [URLQueryItem] = []) throws -> URL {
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // Subsonic 1.16.1 mandates md5(password + salt) as its protocol token.
        let token = Insecure.MD5.hash(data: Data((password + salt).utf8))
            .map { String(format: "%02x", Int($0)) }.joined()
        var parts = URLComponents(url: server.appending(path: "rest").appending(path: name), resolvingAgainstBaseURL: false)
        parts?.queryItems = [
            .init(name: "u", value: username), .init(name: "t", value: token), .init(name: "s", value: salt),
            .init(name: "v", value: "1.16.1"), .init(name: "c", value: "Folia iOS"), .init(name: "f", value: "json")
        ] + parameters
        if let query = parts?.percentEncodedQuery {
            parts?.percentEncodedQuery = query.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = parts?.url else { throw NavidromeError.invalidAccount }
        return url
    }
}

enum NavidromeError: LocalizedError {
    case invalidAccount, requestFailed, serverError(Int?), keychain

    var errorDescription: String? {
        switch self {
        case .invalidAccount: return "請填寫有效的 HTTPS 伺服器網址、帳號與密碼。"
        case .requestFailed: return "連不上 Navidrome，請檢查伺服器網址與連線。"
        case .serverError(40), .serverError(41): return "Navidrome 帳號或密碼不正確。"
        case .serverError: return "Navidrome 拒絕了這次請求。"
        case .keychain: return "無法讀寫 iPhone 的鑰匙圈。"
        }
    }
}

struct NavidromeClient: Sendable {
    let account: NavidromeAccount

    private struct Envelope: Decodable {
        let response: Response
        enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
    }

    private struct Response: Decodable {
        let status: String
        let error: ServerError?
        let searchResult3: Search?
        let lyricsList: NavidromeLyrics?
        let lyrics: LegacyLyrics?
    }

    private struct ServerError: Decodable { let code: Int? }
    private struct Search: Decodable { let song: [Song]? }
    private struct LegacyLyrics: Decodable { let value: String? }
    private struct Song: Decodable {
        let id: String
        let title: String
        let artist: String?
        let album: String?
        let duration: Double?
        let coverArt: String?
        let suffix: String?
        let bitRate: Int?
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration)
    }()

    func ping() async throws { _ = try await request("ping") }

    func search(_ query: String, limit: Int = 100) async throws -> [Track] {
        let response = try await request("search3", parameters: [
            .init(name: "query", value: query), .init(name: "artistCount", value: "0"),
            .init(name: "albumCount", value: "0"), .init(name: "songCount", value: String(max(1, min(100, limit))))
        ])
        return (response.searchResult3?.song ?? []).map {
            Track(id: $0.id, source: .navidrome, title: $0.title, artist: $0.artist, album: $0.album,
                  duration: $0.duration, coverID: $0.coverArt)
        }
    }

    func stream(for track: Track) throws -> URL {
        try account.endpoint("stream", parameters: [.init(name: "id", value: track.id)])
    }

    func downloadCandidates(for song: SyncedYouTubeSong) async throws -> [DownloadAudioCandidate] {
        let response = try await request("search3", parameters: [
            .init(name: "query", value: song.title), .init(name: "artistCount", value: "0"),
            .init(name: "albumCount", value: "0"), .init(name: "songCount", value: "50")
        ])
        return try (response.searchResult3?.song ?? []).compactMap { recording in
            guard DownloadSongMatch.matches(song, title: recording.title, artists: [recording.artist ?? ""], duration: recording.duration),
                  let format = recording.suffix?.lowercased(), ["flac", "alac", "wav", "aiff", "aif", "mp3", "m4a", "aac"].contains(format) else { return nil }
            return DownloadAudioCandidate(url: try account.endpoint("download", parameters: [.init(name: "id", value: recording.id)]),
                title: recording.title, artist: recording.artist ?? "", duration: recording.duration ?? 0,
                format: format, bitrate: (recording.bitRate ?? 0) * 1000, source: "Navidrome")
        }
    }

    func artwork(for track: Track) async -> Data? {
        guard let cover = track.coverID, let url = try? account.endpoint("getCoverArt", parameters: [
            .init(name: "id", value: cover), .init(name: "size", value: "600")
        ]) else { return nil }
        return try? await Self.readResponse(from: url)
    }

    func lyrics(for track: Track) async -> LyricTimeline? {
        try? await subtitleLyrics(for: track)
    }

    func subtitleLyrics(for track: Track) async throws -> LyricTimeline? {
        var modernFailure: Error?
        do {
            let modern = try await request("getLyricsBySongId", parameters: [
            .init(name: "id", value: track.id), .init(name: "enhanced", value: "true")
            ])
            if let timeline = modern.lyricsList?.timeline(), !timeline.lines.isEmpty { return timeline }
        } catch { modernFailure = error }
        try Task.checkCancellation()
        guard let artist = track.artist else {
            if let modernFailure { throw modernFailure }; return nil
        }
        let legacy = try await request("getLyrics", parameters: [
                .init(name: "artist", value: artist), .init(name: "title", value: track.title)
              ])
        guard let value = legacy.lyrics?.value else {
            if let modernFailure { throw modernFailure }; return nil
        }
        let timeline = LyricTimeline(lrc: value)
        return timeline.lines.isEmpty ? nil : timeline
    }

    private func request(_ name: String, parameters: [URLQueryItem] = []) async throws -> Response {
        let url = try account.endpoint(name, parameters: parameters)
        let data = try await Self.readResponse(from: url)
        let payload = try JSONDecoder().decode(Envelope.self, from: data).response
        guard payload.status == "ok" else { throw NavidromeError.serverError(payload.error?.code) }
        return payload
    }

    // Bound metadata and cover downloads even for servers that omit Content-Length.
    private static func readResponse(from url: URL) async throws -> Data {
        let limit = 8_000_000
        let (bytes, response) = try await session.bytes(from: url)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.expectedContentLength <= Int64(limit) else { throw NavidromeError.requestFailed }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < limit else { throw NavidromeError.requestFailed }
            data.append(byte)
        }
        return data
    }
}

@MainActor @Observable
final class NavidromeConnection {
    private(set) var account: NavidromeAccount?
    private(set) var storageError: String?
    private let key: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: Bundle.main.bundleIdentifier ?? "FoliaNative",
        kSecAttrAccount as String: "Navidrome"
    ]

    init() {
        var result: CFTypeRef?
        var query = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            account = try? JSONDecoder().decode(NavidromeAccount.self, from: data)
            if account == nil { storageError = NavidromeError.keychain.localizedDescription }
        } else if status != errSecItemNotFound {
            storageError = NavidromeError.keychain.localizedDescription
        }
    }

    func connect(server: String, username: String, password: String) async throws {
        let candidate = try NavidromeAccount(server: server, username: username, password: password)
        try await NavidromeClient(account: candidate).ping()
        try Task.checkCancellation()
        let encoded = try JSONEncoder().encode(candidate)
        let update = [kSecValueData as String: encoded]
        var status = SecItemUpdate(key as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = key
            attributes[kSecValueData as String] = encoded
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NavidromeError.keychain }
        account = candidate
        storageError = nil
    }

    func disconnect() throws {
        let status = SecItemDelete(key as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NavidromeError.keychain }
        account = nil
        storageError = nil
    }
}
