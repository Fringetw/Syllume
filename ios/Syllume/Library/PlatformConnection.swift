import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import UIKit

@MainActor @Observable
final class PlatformConnection {
    let platform: LibraryPlatform
    let googleConfiguration: GoogleClientConfiguration
    private(set) var clientID: String
    private(set) var sessionID = UUID()
    private(set) var libraryID: String?
    private(set) var connecting = false
    private(set) var storageError: String?
    var connected: Bool { credential != nil }

    private var credential: Credential?
    @ObservationIgnored private let authorizer = PlatformAuthorization()
    @ObservationIgnored private var refreshTask: Task<Credential, Error>?
    @ObservationIgnored private let session: URLSession

    private struct Credential: Codable {
        let clientID: String
        let accessToken: String
        let refreshToken: String?
        let expires: Date
        var libraryID: String?
    }
    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
        let scope: String?
    }

    init(_ platform: LibraryPlatform) {
        self.platform = platform
        let info = Bundle.main.infoDictionary ?? [:]
        let urlTypes = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let embeddedGoogle = GoogleClientConfiguration(
            clientID: info["FoliaGoogleClientID"] as? String,
            registeredBundleID: info["FoliaGoogleBundleID"] as? String,
            bundleID: Bundle.main.bundleIdentifier,
            schemes: urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] })
        googleConfiguration = embeddedGoogle
        clientID = platform == .youtube ? embeddedGoogle.clientID
            : UserDefaults.standard.string(forKey: "Folia.ClientID." + platform.rawValue) ?? ""
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = platform == .youtube ? 10 : 25
        if platform == .youtube { configuration.timeoutIntervalForResource = 18 }
        session = URLSession(configuration: configuration)
        do {
            if let data = try readCredential() {
                var saved = try JSONDecoder().decode(Credential.self, from: data)
                if platform == .spotify || googleConfiguration.acceptsCredential(clientID: saved.clientID) {
                    if saved.libraryID == nil { saved.libraryID = UUID().uuidString; try writeCredential(saved) }
                    credential = saved
                    libraryID = saved.libraryID
                    if platform == .spotify { clientID = saved.clientID }
                }
            }
        } catch { storageError = "無法讀取曲庫登入資料，請重新連接。" }
        #if DEBUG
        if platform == .youtube, ProcessInfo.processInfo.arguments.contains("--youtube-sync-fixture") {
            let id = "021A0A60-4BED-4416-8784-A4C7416A4A11"
            credential = Credential(clientID: "debug", accessToken: "debug", refreshToken: nil, expires: .distantFuture, libraryID: id)
            libraryID = id
        }
        if platform == .spotify, ProcessInfo.processInfo.arguments.contains("--spotify-handoff-fixture") {
            credential = Credential(clientID: "debug", accessToken: "debug", refreshToken: nil, expires: .distantFuture, libraryID: nil)
        }
        #endif
    }

    func connect(clientID input: String) async throws {
        guard !connecting else { return }
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if platform == .youtube {
            guard googleConfiguration.isReady, candidate == googleConfiguration.clientID else {
                throw PlatformError.message(googleConfiguration.userMessage ?? "Google 登入設定無法使用。")
            }
        }
        let redirect = try platform.redirect(clientID: candidate)
        connecting = true
        defer { connecting = false }
        let revision = sessionID
        let verifier = try randomString()
        let state = try randomString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        var url = URLComponents(url: platform.authorizeURL, resolvingAgainstBaseURL: false)!
        url.queryItems = [
            .init(name: "client_id", value: candidate), .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: platform.scope),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state)
        ]
        if platform == .youtube {
            url.queryItems?.append(contentsOf: [.init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")])
        }
        if platform == .spotify {
            UserDefaults.standard.set(candidate, forKey: "Folia.ClientID." + platform.rawValue)
        }
        clientID = candidate
        let callback = try await authorizer.authenticate(url: url.url!, scheme: redirect.scheme!)
        let code = try OAuthCallback.code(from: callback, expected: redirect, state: state)
        let token = try await exchange([
            .init(name: "client_id", value: candidate), .init(name: "grant_type", value: "authorization_code"),
            .init(name: "redirect_uri", value: redirect.absoluteString), .init(name: "code", value: code),
            .init(name: "code_verifier", value: verifier)
        ], clientID: candidate, previous: nil)
        try Task.checkCancellation()
        guard sessionID == revision else { throw CancellationError() }
        try writeCredential(token)
        credential = token
        libraryID = token.libraryID
        clientID = candidate
        storageError = nil
        sessionID = UUID()
    }

    func cancelLogin() { authorizer.cancel() }

    func connectGoogle() async throws {
        guard platform == .youtube else { throw PlatformError.message("這個來源不支援 Google 登入。") }
        try await connect(clientID: googleConfiguration.clientID)
    }

    func disconnect() throws {
        let status = SecItemDelete(key as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PlatformError.message("無法移除曲庫登入資料。") }
        authorizer.cancel()
        refreshTask?.cancel()
        refreshTask = nil
        credential = nil
        libraryID = nil
        storageError = nil
        sessionID = UUID()
    }

    func page(_ collection: LibraryCollection, cursor: String?) async throws -> LibraryPage {
        #if DEBUG
        if platform == .spotify, ProcessInfo.processInfo.arguments.contains("--spotify-handoff-fixture") {
            return LibraryPage(entries: [], next: nil)
        }
        if platform == .youtube, ProcessInfo.processInfo.arguments.contains("--youtube-sync-fixture") {
            if collection == .playlists {
                return LibraryPage(entries: [LibraryEntry(id: "fixture-list", title: "測試歌單", subtitle: "", url: URL(string: "https://music.youtube.com/playlist?list=fixture-list")!)], next: nil)
            }
            if ProcessInfo.processInfo.arguments.contains("--syllume-recording-regression") {
                let missingDuration = ProcessInfo.processInfo.arguments.contains("--youtube-missing-duration-fixture")
                return LibraryPage(entries: [
                    LibraryEntry(id: "recording-jane", title: "JANE DOE", subtitle: "Kenshi Yonezu - Topic",
                        url: URL(string: "https://music.youtube.com/watch?v=6AR6Oc0-4NQ")!, duration: missingDuration ? nil : 236),
                    LibraryEntry(id: "recording-lemon", title: "Lemon", subtitle: "Kenshi Yonezu - Topic",
                        url: URL(string: "https://music.youtube.com/watch?v=3NNhrqHZqlI")!, duration: 256)
                ], next: nil)
            }
            let slow = ProcessInfo.processInfo.arguments.contains("--youtube-slow-source-fixture")
            if slow, cursor != nil {
                try await Task.sleep(for: .seconds(90))
                return LibraryPage(entries: [], next: nil)
            }
            return LibraryPage(entries: [LibraryEntry(id: "fixture-row", title: "潮汐之間", subtitle: "Syllume 示範音軌",
                url: URL(string: "https://music.youtube.com/watch?v=M7lc1UVf-VE")!, duration: 30)], next: slow ? "fixture-next" : nil)
        }
        #endif
        let revision = sessionID
        let url = try PlatformLibrary.endpoint(platform: platform, collection: collection, cursor: cursor)
        var token = try await accessToken()
        var result = try await request(url: url, token: token)
        if result.1.statusCode == 401 {
            token = try await accessToken(refresh: true)
            result = try await request(url: url, token: token)
        }
        try Task.checkCancellation()
        guard sessionID == revision else { throw CancellationError() }
        if platform == .youtube, !(200..<300).contains(result.1.statusCode) {
            throw DiagnosticProblem.googleHTTP(result.1.statusCode, body: result.0)
        }
        switch result.1.statusCode {
        case 200..<300:
            do { return try PlatformLibrary.decode(result.0, platform: platform, collection: collection) }
            catch { throw PlatformError.message("平台回傳的曲庫格式無法辨識，請稍後再試。") }
        case 401: throw PlatformError.message("登入已失效，請中斷連線後重新登入。")
        case 403:
            let message = platform == .spotify
                ? "Spotify 拒絕存取。請確認開發者帳號的 Premium、測試使用者名單與讀取權限；開發模式只能讀取自己擁有或協作歌單的內容。"
                : "Google 暫時拒絕曲庫存取。請稍後重試，或聯絡 App 提供者確認這個帳號能使用此版本。"
            throw PlatformError.message(message)
        case 404: throw PlatformError.message("這份歌單已無法取得，可改在原平台查看。")
        case 429: throw PlatformError.message("平台請求次數已達上限，請稍後再載入。")
        default: throw PlatformError.message("平台暫時無法提供曲庫，請稍後重試。")
        }
    }

    // Fetch label credits only for the selected song, keeping bulk playlist requests small.
    func playlistSongWithMetadata(_ song: SyncedYouTubeSong) async -> SyncedYouTubeSong {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--youtube-sync-fixture") {
            var result = song
            if song.videoID == "6AR6Oc0-4NQ" { result.creditedArtist = "Kenshi Yonezu、Hikaru Utada" }
            return result
        }
        #endif
        guard connected, YouTubeVideo.validID(song.videoID),
              song.duration == nil || (song.creditedArtist == nil && song.artist.hasSuffix(" - Topic")) else { return song }
        let id = song.videoID
        let details = try? await PlaybackLookup.within(.seconds(3)) { try await self.videoDetails([id], includeMetadata: true).first }
        return details?.enrich(song) ?? song
    }

    func videoDurations(_ ids: [String]) async throws -> [String: Double] {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--youtube-sync-fixture") { return [:] }
        #endif
        let details = try await videoDetails(ids, includeMetadata: false)
        return Dictionary(details.compactMap { item in item.duration.map { (item.id, $0) } },
                          uniquingKeysWith: { first, _ in first })
    }

    func videoDetails(_ ids: [String], includeMetadata: Bool) async throws -> [YouTubeVideoDetails] {
        guard platform == .youtube, !ids.isEmpty, ids.count <= 50, ids.allSatisfy(YouTubeVideo.validID) else { return [] }
        let revision = sessionID
        var parts = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        let detail = includeMetadata ? ",snippet(title,channelTitle,description),status(embeddable)" : ""
        parts.queryItems = [.init(name: "part", value: includeMetadata ? "contentDetails,snippet,status" : "contentDetails"),
            .init(name: "id", value: ids.joined(separator: ",")),
            .init(name: "fields", value: "items(id,contentDetails(duration)\(detail))")]
        var token = try await accessToken()
        var result = try await request(url: parts.url!, token: token)
        if result.1.statusCode == 401 {
            token = try await accessToken(refresh: true)
            result = try await request(url: parts.url!, token: token)
        }
        try Task.checkCancellation()
        guard sessionID == revision else { throw CancellationError() }
        guard (200..<300).contains(result.1.statusCode) else { throw DiagnosticProblem.googleHTTP(result.1.statusCode, body: result.0) }
        struct Page: Decodable { let items: [YouTubeVideoDetails] }
        let page = try JSONDecoder().decode(Page.self, from: result.0)
        return page.items.filter { ids.contains($0.id) }
    }

    func channelPortraits(_ ids: [String]) async throws -> [String: (name: String, url: URL)] {
        guard platform == .youtube, !ids.isEmpty, ids.count <= 50,
              ids.allSatisfy({ $0.range(of: #"^UC[A-Za-z0-9_-]{22}$"#, options: .regularExpression) != nil }) else { return [:] }
        let revision = sessionID
        var parts = URLComponents(string: "https://www.googleapis.com/youtube/v3/channels")!
        parts.queryItems = [.init(name: "part", value: "snippet"), .init(name: "id", value: ids.joined(separator: ",")),
            .init(name: "fields", value: "items(id,snippet(title,thumbnails(default,medium)))")]
        let (data, response) = try await request(url: parts.url!, token: try await accessToken())
        guard sessionID == revision, !Task.isCancelled else { throw CancellationError() }
        guard (200..<300).contains(response.statusCode) else { return [:] }
        struct Page: Decodable {
            struct Channel: Decodable {
                struct Snippet: Decodable {
                    struct Image: Decodable { let url: String }
                    let title: String; let thumbnails: [String: Image]
                }
                let id: String; let snippet: Snippet
            }
            let items: [Channel]?
        }
        var result: [String: (name: String, url: URL)] = [:]
        for channel in try JSONDecoder().decode(Page.self, from: data).items ?? [] where ids.contains(channel.id) {
            let pictures = channel.snippet.thumbnails
            if let url = ["medium", "default"].lazy.compactMap({ pictures[$0]?.url }).compactMap(YouTubeArtwork.portraitURL).first {
                result[channel.id] = (channel.snippet.title, url)
            }
        }
        return result
    }

    func verifyGoogleRefresh() async throws {
        guard platform == .youtube, connected else { throw DiagnosticProblem(code: .signedOut) }
        _ = try await accessToken(refresh: true)
        _ = try await page(.liked, cursor: nil)
    }

    private func accessToken(refresh: Bool = false) async throws -> String {
        guard let credential else { throw DiagnosticProblem(code: .signedOut) }
        if !refresh && credential.expires.timeIntervalSinceNow > 60 { return credential.accessToken }
        let revision = sessionID
        if let refreshTask {
            let updated = try await refreshTask.value
            guard sessionID == revision else { throw CancellationError() }
            return updated.accessToken
        }
        guard let refreshToken = credential.refreshToken else { throw DiagnosticProblem(code: .reauthorize) }
        let task = Task {
            let updated = try await exchange([
                .init(name: "client_id", value: credential.clientID), .init(name: "grant_type", value: "refresh_token"),
                .init(name: "refresh_token", value: refreshToken)
            ], clientID: credential.clientID, previous: credential)
            guard sessionID == revision else { throw CancellationError() }
            try writeCredential(updated)
            self.credential = updated
            return updated
        }
        refreshTask = task
        defer { if sessionID == revision { refreshTask = nil } }
        let updated = try await task.value
        guard sessionID == revision else { throw CancellationError() }
        return updated.accessToken
    }

    private func exchange(_ parameters: [URLQueryItem], clientID: String, previous: Credential?) async throws -> Credential {
        var form = URLComponents()
        form.queryItems = parameters
        var request = URLRequest(url: platform.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await session.data(for: request)
        if platform == .youtube, let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DiagnosticProblem.googleHTTP(http.statusCode, body: data)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 1_000_000,
              let token = try? JSONDecoder().decode(TokenResponse.self, from: data), !token.access_token.isEmpty,
              token.expires_in.isFinite, token.expires_in > 0 else {
            throw PlatformError.message(platform == .youtube
                ? "Google 登入未完成。請稍後重試，若持續發生請聯絡 App 提供者。"
                : "無法取得登入授權。請檢查 Client ID、回呼網址和開發者測試帳號設定，再重新連接。")
        }
        if let scope = token.scope {
            let granted = Set(scope.split(separator: " ").map(String.init))
            guard Set(platform.scope.split(separator: " ").map(String.init)).isSubset(of: granted) else {
                throw PlatformError.message("尚未授權讀取完整歌單與收藏，請重新登入並允許要求的唯讀權限。")
            }
        }
        return Credential(clientID: clientID, accessToken: token.access_token,
                          refreshToken: token.refresh_token ?? previous?.refreshToken,
                          expires: Date().addingTimeInterval(token.expires_in), libraryID: previous?.libraryID ?? UUID().uuidString)
    }

    private func request(url: URL, token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 8_000_000 else {
            throw PlatformError.message("曲庫回應過大或無效。")
        }
        return (data, http)
    }

    private var key: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "FoliaNative") + ".OnlineLibrary",
         kSecAttrAccount as String: platform.rawValue]
    }

    private func readCredential() throws -> Data? {
        var query = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PlatformError.message("無法讀取登入資料。") }
        return data
    }

    private func writeCredential(_ credential: Credential) throws {
        let data = try JSONEncoder().encode(credential)
        var status = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = key
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PlatformError.message("無法儲存曲庫登入資料。") }
    }

    private func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PlatformError.message("無法建立安全登入，請重試。")
        }
        return Data(bytes).base64URLEncoded
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private final class PlatformAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var revision = UUID()
    private var window: UIWindow?

    func authenticate(url: URL, scheme: String) async throws -> URL {
        guard session == nil else { throw PlatformError.message("已有登入視窗開啟。") }
        window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        guard window != nil else { throw PlatformError.message("請回到 Syllume 畫面後再登入。") }
        let id = UUID()
        revision = id
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let callback: ASWebAuthenticationSession.CompletionHandler = { [weak self] result, error in
                    Task { @MainActor in
                        guard let self, self.revision == id else { return }
                        if let result { self.finish(.success(result)) }
                        else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                            self.finish(.failure(CancellationError()))
                        } else { self.finish(.failure(PlatformError.message("登入視窗未能完成，請重新連接。"))) }
                    }
                }
                if #available(iOS 17.4, *) {
                    session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme), completionHandler: callback)
                } else {
                    session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme, completionHandler: callback)
                }
                session?.presentationContextProvider = self
                if session?.start() != true { finish(.failure(PlatformError.message("無法開啟登入視窗。"))) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in if self?.revision == id { self?.cancel() } }
        }
    }

    func cancel() {
        let previous = session
        finish(.failure(CancellationError()))
        previous?.cancel()
    }

    private func finish(_ result: Result<URL, Error>) {
        let pending = continuation
        continuation = nil
        session = nil
        window = nil
        revision = UUID()
        pending?.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window ?? UIWindow() }
}
