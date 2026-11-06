import Foundation
import Observation
import WebKit

@MainActor @Observable
final class SubtitleController: NSObject, WKNavigationDelegate {
    var preferences: SubtitlePreferences { didSet {
        if oldValue.sourceKey != preferences.sourceKey {
            cancelRequests(); accountKey = UUID().uuidString; sourceStatus.removeAll()
        }
        save(); configureEngine()
    } }
    private(set) var timeline = LyricTimeline(lines: [])
    private(set) var revision = UUID()
    private(set) var reportText = "目前沒有歌曲。"
    private(set) var reportJSON = Data("{}".utf8)
    private(set) var sourceStatus: [String: String] = [:]
    private(set) var engineError: String?
    var notice: String?
    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var input: SubtitleInput?
    @ObservationIgnored private var raw = LyricTimeline(lines: [])
    @ObservationIgnored private var token = UUID().uuidString
    @ObservationIgnored private var accountKey = UUID().uuidString
    @ObservationIgnored private var library: LocalLibrary?
    @ObservationIgnored private var account: NavidromeAccount?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var candidates: [String: Candidate] = [:]
    @ObservationIgnored private var candidateOrder: [String] = []
    @ObservationIgnored private var fixture = false
    @ObservationIgnored private var engineReportText = "目前沒有歌曲。"
    @ObservationIgnored private var engineReport: [String: Any] = [:]
    private enum Candidate { case local(Track), navidrome(Track), record(SubtitleRecord) }

    override init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--subtitle-reset") {
            UserDefaults.standard.removeObject(forKey: "Folia.BuiltInTraditionalLyrics.v1")
        }
        #endif
        if let data = UserDefaults.standard.data(forKey: "Folia.BuiltInTraditionalLyrics.v1"),
           let saved = try? JSONDecoder().decode(SubtitlePreferences.self, from: data) { preferences = saved }
        else { preferences = SubtitlePreferences() }
        super.init()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(SubtitleMessageHandler(self), name: "subtitles")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.isInspectable = false
        webView = view
        if let file = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "FoliaSubtitles") {
            view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        } else { engineError = "內建字幕引擎遺失，請更新安裝版本。" }
        #if DEBUG
        fixture = ProcessInfo.processInfo.arguments.contains("--subtitle-fixture")
        #endif
    }

    func sources(library: LocalLibrary, account: NavidromeAccount?) {
        self.library = library
        if self.account != account {
            cancelRequests(); self.account = account; accountKey = UUID().uuidString
        }
        configureEngine()
    }

    func load(_ next: SubtitleInput?, timeline rawTimeline: LyricTimeline) {
        guard input != next else { return }
        let sameSong = input?.song.id == next?.song.id && input?.song.source == next?.song.source
        let previousRaw = raw.lines
        if input?.song.id != next?.song.id || input?.song.source != next?.song.source { cancelRequests() }
        if !sameSong { sourceStatus.removeAll() }
        input = next; raw = rawTimeline; token = UUID().uuidString
        #if DEBUG
        if fixture, next?.song.source == "demo" {
            raw = LyricTimeline(lines: [LyricLine(startTime: 0, endTime: 30, fullText: "头发发现", translation: "风里的回声",
                words: [LyricWord(text: "头发", startTime: 0, endTime: 15), LyricWord(text: "发现", startTime: 15, endTime: 30)])])
        }
        #endif
        if !sameSong || previousRaw != raw.lines { apply(raw) }
        reportText = next == nil ? "目前沒有歌曲。" : next?.loading == true ? "正在載入原字幕。" : "正在準備字幕檢查。"
        reportJSON = Data("{}".utf8); engineReport = [:]; engineReportText = reportText
        sendInput()
    }

    func command(_ name: String) {
        guard ["retry", "restore", "status"].contains(name) else { return }
        call("window.FoliaSubtitles.command(name)", ["name": name])
    }

    private func save() {
        if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "Folia.BuiltInTraditionalLyrics.v1") }
    }
    private func configureEngine() {
        guard ready else { return }
        if !preferences.active { cancelRequests(); apply(raw); reportJSON = Data("{}".utf8) }
        var providers: [[String: Any]] = [
            ["providerId": "netease", "displayName": "網易雲", "configured": preferences.searchNetease, "supports": ["search": true, "lyrics": true]],
            ["providerId": "qq", "displayName": "QQ 音樂", "configured": preferences.searchQQ, "supports": ["search": true, "lyrics": true]],
            ["providerId": "ytm", "displayName": "YouTube 人工中文字幕", "configured": preferences.searchYouTube, "supports": ["search": true, "lyrics": true]],
            ["providerId": "local", "displayName": "本機歌詞", "configured": library != nil, "supports": ["search": true, "lyrics": true]],
            ["providerId": "navidrome", "displayName": "Navidrome", "configured": account != nil, "supports": ["search": true, "lyrics": true]],
            ["providerId": "lrclib", "displayName": "LRCLIB", "configured": !fixture, "supports": ["search": true, "lyrics": true]],
        ]
        if fixture { providers = [] }
        call("window.FoliaSubtitles.configure(settings, providers, account)",
             ["settings": object(preferences) ?? [:], "providers": providers, "account": accountKey])
    }
    private func sendInput() {
        guard ready else { return }
        guard let input, !input.loading else { call("window.FoliaSubtitles.load(null)", [:]); return }
        let song = matchingSong(input.song)
        call("window.FoliaSubtitles.load(input)", ["input": ["token": token, "song": object(song) ?? [:],
            "duration": input.song.durationMs / 1000, "lines": object(raw.lines) ?? []]])
    }
    private func call(_ script: String, _ args: [String: Any]) {
        webView?.callAsyncJavaScript(script, arguments: args, in: nil, in: .page) { [weak self] result in
            if case .failure = result { self?.engineError = "內建字幕引擎未回應，暫時顯示原字幕。" }
        }
    }
    private func object<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView === webView,
              message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" { ready = true; engineError = nil; configureEngine(); sendInput(); return }
        if type == "cancel", let id = body["id"] as? String { tasks.removeValue(forKey: id)?.cancel(); return }
        if type == "request" { request(body); return }
        if type == "toast", let text = body["text"] as? String { notice = text; return }
        guard body["token"] as? String == token else { return }
        if !preferences.active {
            apply(raw); reportText = "內建模組已停用；顯示原字幕。"; reportJSON = Data("{}".utf8)
            return
        }
        if type == "display", let lines = body["lines"], JSONSerialization.isValidJSONObject(lines),
           let data = try? JSONSerialization.data(withJSONObject: lines), data.count <= 16_000_000,
           let decoded = try? JSONDecoder().decode([LyricLine].self, from: data), decoded.count <= 20_000 {
            apply(LyricTimeline(lines: decoded))
        } else if type == "report" {
            engineReportText = body["text"] as? String ?? "目前沒有報告。"
            engineReport = body["value"] as? [String: Any] ?? [:]
            updateReport()
        }
    }

    private func matchingSong(_ song: SubtitleSong) -> SubtitleSong {
        song.source == "ytm" ? YouTubeCaptionDecoders.metadata(id: song.id, title: song.title,
            artist: song.artist, duration: song.durationMs / 1000) : song
    }
    private func updateReport() {
        let states = sourceStatus.keys.sorted().map { "\($0)：\(sourceStatus[$0] ?? "")" }
        reportText = engineReportText + (states.isEmpty ? "" : "\n\n平台讀取狀態\n" + states.joined(separator: "\n"))
        var report = engineReport
        report["iosSources"] = sourceStatus
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { reportJSON = data }
    }

    private func cancelRequests() {
        for task in tasks.values { task.cancel() }; tasks.removeAll()
        candidates.removeAll(); candidateOrder.removeAll()
    }
    private func apply(_ next: LyricTimeline) {
        guard timeline.lines != next.lines else { return }
        timeline = next; revision = UUID()
    }
    private func register(_ song: SubtitleSong, _ value: Candidate) -> [String: Any] {
        let ref = UUID().uuidString; candidates[ref] = value; candidateOrder.append(ref)
        while candidateOrder.count > 192 { candidates.removeValue(forKey: candidateOrder.removeFirst()) }
        var result = object(song) as? [String: Any] ?? [:]; result["ref"] = ref
        return result
    }

    private func request(_ body: [String: Any]) {
        guard preferences.active, let id = body["id"] as? String, tasks[id] == nil,
              tasks.count < 4, let method = body["method"] as? String,
              let params = body["params"] as? [String: Any], let provider = params["providerId"] as? String else { return }
        let requestAccount = accountKey
        let requestSong = input?.song
        let requestPreferences = preferences
        let currentSong = input.map { matchingSong($0.song) }
        let originalLines = raw.lines
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            var value: [String: Any] = [:]
            var failure: [String: Any]?
            do {
                if method == "search", let query = params["query"] as? String, !query.isEmpty, query.count <= 400 {
                    var songs: [[String: Any]] = []
                    if provider == "local", let library {
                        let terms = query.split(whereSeparator: \.isWhitespace)
                        let tracks = library.tracks.filter { track in track.lyricFile != nil && terms.allSatisfy {
                            (track.title + " " + (track.artist ?? "")).localizedStandardContains(String($0))
                        } }.prefix(8)
                        songs = tracks.map { register(SubtitleSong(id: $0.id, source: provider, title: $0.title,
                            artist: $0.artist ?? "", durationMs: ($0.duration ?? 0) * 1000), .local($0)) }
                    } else if provider == "navidrome", let account {
                        let tracks = try await NavidromeClient(account: account).search(query, limit: 8)
                        try Task.checkCancellation()
                        songs = tracks.prefix(8).map { register(SubtitleSong(id: $0.id, source: provider, title: $0.title,
                            artist: $0.artist ?? "", durationMs: ($0.duration ?? 0) * 1000), .navidrome($0)) }
                    } else if ["lrclib", "netease", "qq", "ytm"].contains(provider) {
                        let records = try await SubtitleNetwork.shared.search(query, provider: provider,
                            netease: requestPreferences.neteaseAPI, current: currentSong)
                        try Task.checkCancellation()
                        songs = records.map { register($0.song, .record($0)) }
                    } else { throw SubtitleReadError("unsupported") }
                    value = ["items": songs]
                    if input?.song.id == requestSong?.id && input?.song.source == requestSong?.source, requestAccount == accountKey {
                        sourceStatus[provider] = "找到 \(songs.count) 個候選；由插件核對歌曲版本。"
                    }
                } else if method == "lyrics", let ref = params["ref"] as? String, let candidate = candidates[ref] {
                    let lines: [LyricLine]
                    switch candidate {
                    case .local(let track): lines = try await library?.lyrics(for: track)?.lines ?? []
                    case .navidrome(let track):
                        guard let account else { throw SubtitleReadError("not-signed-in") }
                        lines = try await NavidromeClient(account: account).subtitleLyrics(for: track)?.lines ?? []
                    case .record(let record):
                        guard record.song.source == provider else { throw SubtitleReadError("invalid-response") }
                        lines = try await SubtitleNetwork.shared.lyrics(record, netease: requestPreferences.neteaseAPI, original: originalLines)
                    }
                    value = ["lines": object(lines) ?? []]
                    if input?.song.id == requestSong?.id && input?.song.source == requestSong?.source, requestAccount == accountKey {
                        sourceStatus[provider] = "已讀取 \(lines.count) 行同步字幕；是否套用以插件診斷為準。"
                    }
                } else { throw SubtitleReadError("invalid-response") }
            } catch {
                var code = Task.isCancelled ? "aborted" : (error as? SubtitleReadError)?.code ?? "network"
                if let error = error as? NavidromeError {
                    switch error {
                    case .serverError(40), .serverError(41): code = "not-signed-in"
                    default: break
                    }
                }
                failure = ["code": code, "message": code]
                if !Task.isCancelled, input?.song.id == requestSong?.id && input?.song.source == requestSong?.source, requestAccount == accountKey {
                    sourceStatus[provider] = SubtitleReadError(code).explanation
                }
            }
            guard !Task.isCancelled, requestAccount == accountKey, input?.song.id == requestSong?.id && input?.song.source == requestSong?.source else { tasks.removeValue(forKey: id); return }
            tasks.removeValue(forKey: id)
            updateReport()
            call("window.FoliaSubtitles.resolve(id, result, error)", ["id": id, "result": value, "error": failure.map { $0 as Any } ?? NSNull()])
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false; cancelRequests(); apply(raw)
        engineError = "字幕引擎已停止，暫時顯示原字幕；重新開啟 App 可恢復。"
    }
}

@MainActor private final class SubtitleMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: SubtitleController?
    init(_ owner: SubtitleController) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receive(message) }
}
