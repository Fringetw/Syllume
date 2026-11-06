import Foundation

struct SubtitlePreferences: Codable, Equatable, Sendable {
    var active = true
    var enabled = true
    var target = "tw"
    var convertOriginal = true
    var convertTranslation = true
    var protectJapanese = true
    var autoSelectChinese = true
    var fallbackOnFailure = true
    var searchDepth = "standard"
    var reportVisible = true
    var neteaseAPI = ""
    var searchNetease = true
    var searchQQ = true
    var searchYouTube = true

    init() {}
    // New source switches must not discard preferences saved by 0.3.1.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? active
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? target
        convertOriginal = try c.decodeIfPresent(Bool.self, forKey: .convertOriginal) ?? convertOriginal
        convertTranslation = try c.decodeIfPresent(Bool.self, forKey: .convertTranslation) ?? convertTranslation
        protectJapanese = try c.decodeIfPresent(Bool.self, forKey: .protectJapanese) ?? protectJapanese
        autoSelectChinese = try c.decodeIfPresent(Bool.self, forKey: .autoSelectChinese) ?? autoSelectChinese
        fallbackOnFailure = try c.decodeIfPresent(Bool.self, forKey: .fallbackOnFailure) ?? fallbackOnFailure
        searchDepth = try c.decodeIfPresent(String.self, forKey: .searchDepth) ?? searchDepth
        reportVisible = try c.decodeIfPresent(Bool.self, forKey: .reportVisible) ?? reportVisible
        neteaseAPI = try c.decodeIfPresent(String.self, forKey: .neteaseAPI) ?? neteaseAPI
        searchNetease = try c.decodeIfPresent(Bool.self, forKey: .searchNetease) ?? searchNetease
        searchQQ = try c.decodeIfPresent(Bool.self, forKey: .searchQQ) ?? searchQQ
        searchYouTube = try c.decodeIfPresent(Bool.self, forKey: .searchYouTube) ?? searchYouTube
    }

    var sourceKey: String { "\(searchNetease)|\(searchQQ)|\(searchYouTube)|\(neteaseAPI)" }
}

struct SubtitleSong: Codable, Equatable, Sendable {
    let id: String
    let source: String
    let title: String
    let artist: String
    let durationMs: Double
    var ref: String? = nil
}

struct SubtitleInput: Equatable {
    let song: SubtitleSong
    let revision: UUID
    let loading: Bool
}

struct SubtitleReadError: Error, Sendable {
    let code: String
    init(_ code: String) { self.code = code }
    var explanation: String {
        switch code {
        case "rate-limited": "來源暫時限制請求，請稍後再試。"
        case "not-signed-in": "來源要求登入，目前不讀取需要帳號的字幕。"
        case "region-restricted": "來源拒絕存取或受地區限制。"
        case "captions-unavailable": "影片沒有可讀取的人工中文字幕軌；畫面內的字幕無法直接取用。"
        case "verification-required": "YouTube 要求驗證或同意，暫時無法讀取公開字幕。"
        case "caption-read-failed": "YouTube 列出字幕軌，但本次未提供內容，可能需驗證或受存取限制。"
        case "empty": "來源沒有提供可用的同步字幕。"
        case "invalid-response": "來源回覆格式已改變或資料不完整。"
        default: "來源暫時無法連線，未更動原字幕。"
        }
    }
}

struct SubtitleRecord: Sendable {
    let song: SubtitleSong
    var lines: [LyricLine]? = nil
}
