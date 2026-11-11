import Foundation

enum DiagnosticArea: String, CaseIterable, Codable, Identifiable, Sendable {
    case google, captions, audio, animation, device

    var id: String { rawValue }
    var title: String {
        switch self {
        case .google: "Google 帳號與歌單"
        case .captions: "YouTube 中文字幕"
        case .audio: "音源、播放與下載"
        case .animation: "商籟與繪光"
        case .device: "裝置效能與穩定性"
        }
    }
}

enum DiagnosticState: String, Codable, Sendable {
    case passed, failed, partial, unverifiable

    var title: String {
        switch self {
        case .passed: "通過"
        case .failed: "失敗"
        case .partial: "部分通過"
        case .unverifiable: "無法驗證"
        }
    }
}

enum DiagnosticEvidence: String, Codable, Sendable {
    case liveNetwork, bundledSample, userMedia, simulatedInput, observedPlayback, operatingSystem

    var title: String {
        switch self {
        case .liveNetwork: "真實網路"
        case .bundledSample: "內建測試音檔"
        case .userMedia: "使用者音檔"
        case .simulatedInput: "模擬資料"
        case .observedPlayback: "實際操作紀錄"
        case .operatingSystem: "裝置／系統"
        }
    }
}

enum DiagnosticCode: String, Codable, Sendable {
    case configuration, signedOut, reauthorize, permission, quota, rateLimit, offline, timeout, transport
    case verification, region, unavailable, noMatch, missingDuration, invalidResponse, invalidMedia, cancelled
    case noData, authorizationRequired, providerAuthorizationRequired, appBusy, appBackgrounded, engine, timeline, systemUnavailable

    var title: String {
        switch self {
        case .configuration: "登入設定有誤"
        case .signedOut: "尚未登入"
        case .reauthorize: "授權已失效，請重新登入"
        case .permission: "權限不足"
        case .quota: "API 配額已用完"
        case .rateLimit: "來源限制請求頻率"
        case .offline: "目前沒有網路"
        case .timeout: "連線或處理逾時"
        case .transport: "網路或連線錯誤"
        case .verification: "平台要求驗證"
        case .region: "來源受地區或存取限制"
        case .unavailable: "來源目前無法提供資料"
        case .noMatch: "找不到符合歌曲版本的音源"
        case .missingDuration: "無法核對原曲時長"
        case .invalidResponse: "來源回應格式無效"
        case .invalidMedia: "音訊格式、內容或時長不符"
        case .cancelled: "已取消"
        case .noData: "目前沒有足夠資料"
        case .authorizationRequired: "需要使用者授權"
        case .providerAuthorizationRequired: "需要平台授權第三方音源"
        case .appBusy: "主播放器正在播放"
        case .appBackgrounded: "App 已切到背景"
        case .engine: "動畫或字幕引擎錯誤"
        case .timeline: "時間軸驗證失敗"
        case .systemUnavailable: "系統尚未提供數據"
        }
    }
}

enum DiagnosticMediaIssue: String, Codable, Sendable {
    case missingAudioTrack, unexpectedVideoTrack, notPlayable, durationUnavailable, durationMismatch
}

// Store a bounded classification instead of NSError.userInfo or the server response.
struct DiagnosticProblem: Error, LocalizedError, Codable, Equatable, Sendable {
    let code: DiagnosticCode
    var httpStatus: Int? = nil
    var nativeCode: Int? = nil
    var mediaIssue: DiagnosticMediaIssue? = nil

    var errorDescription: String? { code.title }
    var detail: String {
        [code.title + " [\(code.rawValue)]", mediaIssue?.rawValue,
         httpStatus.map { "HTTP \($0)" }, nativeCode.map { "原生錯誤 \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    static func afterExhaustingAudioSources(_ problems: [Self]) -> Self {
        problems.first { $0.code != .noMatch && $0.code != .providerAuthorizationRequired }
            ?? problems.first { $0.code != .noMatch }
            ?? problems.first
            ?? Self(code: .noMatch)
    }

    static func classify(_ error: Error, fallback: DiagnosticCode = .transport) -> Self {
        if let problem = error as? Self { return problem }
        if error is CancellationError { return Self(code: .cancelled) }
        if let platform = error as? PlatformError, case .timeout = platform { return Self(code: .timeout) }
        if let error = error as? SubtitleReadError {
            let code: DiagnosticCode
            switch error.code {
            case "not-signed-in": code = .signedOut
            case "rate-limited": code = .rateLimit
            case "verification-required": code = .verification
            case "region-restricted": code = .region
            case "invalid-response": code = .invalidResponse
            case "empty", "unavailable", "captions-unavailable", "caption-read-failed", "video-unavailable": code = .unavailable
            default: code = fallback
            }
            return Self(code: code)
        }
        return classifyNative(error as NSError, fallback: fallback, depth: 0)
    }

    private static func classifyNative(_ native: NSError, fallback: DiagnosticCode, depth: Int) -> Self {
        if native.domain == NSURLErrorDomain {
            let code: DiagnosticCode
            switch native.code {
            case NSURLErrorCancelled: code = .cancelled
            case NSURLErrorTimedOut: code = .timeout
            case NSURLErrorNotConnectedToInternet: code = .offline
            default: code = .transport
            }
            return Self(code: code, nativeCode: native.code)
        }
        if ["AVFoundationErrorDomain", "CoreMediaErrorDomain", "NSOSStatusErrorDomain"].contains(native.domain) {
            if depth < 3, let underlying = native.userInfo[NSUnderlyingErrorKey] as? Error {
                let cause = classifyNative(underlying as NSError, fallback: fallback, depth: depth + 1)
                if cause.code != fallback { return cause }
            }
            return Self(code: fallback, nativeCode: native.code)
        }
        return Self(code: fallback)
    }

    static func mediaHTTP(_ status: Int) -> Self {
        let code: DiagnosticCode = switch status {
        case 401, 403: .permission
        case 416: .invalidResponse
        case 429: .rateLimit
        case 451: .region
        case 500...599: .transport
        default: .unavailable
        }
        return Self(code: code, httpStatus: status)
    }

    static func googleHTTP(_ status: Int, body: Data) -> Self {
        let payload = body.count <= 64_000 ? (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] : nil
        let envelope = payload?["error"] as? [String: Any]
        let details = envelope?["errors"] as? [[String: Any]] ?? []
        let reasons = Set(details.compactMap { $0["reason"] as? String })
        let tokenError = payload?["error"] as? String
        let code: DiagnosticCode
        if !reasons.isDisjoint(with: ["quotaExceeded", "dailyLimitExceeded", "dailyLimitExceededUnreg"]) { code = .quota }
        else if status == 429 || !reasons.isDisjoint(with: ["rateLimitExceeded", "userRateLimitExceeded"]) { code = .rateLimit }
        else if tokenError == "invalid_grant" || status == 401 { code = .reauthorize }
        else if tokenError == "invalid_client" || !reasons.isDisjoint(with: ["accessNotConfigured", "keyInvalid"]) { code = .configuration }
        else if status == 403 || tokenError == "invalid_scope" { code = .permission }
        else if status == 404 || status == 410 { code = .unavailable }
        else { code = status >= 500 ? .transport : .invalidResponse }
        return Self(code: code, httpStatus: status)
    }
}

struct DiagnosticCheck: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let state: DiagnosticState
    let evidence: DiagnosticEvidence
    let elapsedMs: Int
    let problem: DiagnosticProblem?
    let note: String?
    let metrics: [String: Double]
    // Logical stack locations are compiled-in names. They cannot contain URLs or credentials.
    let checkpoints: [String]
    var timeLabel: String { elapsedMs > 0 ? "\(elapsedMs) ms" : state == .unverifiable ? "—" : "<1 ms" }

    init(_ id: String, _ title: String, _ state: DiagnosticState, _ evidence: DiagnosticEvidence,
         since start: Date = Date(), problem: DiagnosticProblem? = nil, note: String? = nil,
         metrics: [String: Double] = [:]) {
        self.id = id; self.title = title; self.state = state; self.evidence = evidence
        elapsedMs = max(0, Int(Date().timeIntervalSince(start) * 1000))
        self.problem = problem; self.note = note; self.metrics = metrics.filter { $0.value.isFinite }
        checkpoints = problem == nil ? [] : ["Folia.Diagnostics", id]
    }
}

struct DiagnosticResult: Codable, Equatable, Identifiable, Sendable {
    let area: DiagnosticArea
    let checks: [DiagnosticCheck]
    let elapsedMs: Int
    let state: DiagnosticState
    var id: String { area.id }
    var measuredMs: Int { max(elapsedMs, checks.map(\.elapsedMs).max() ?? 0) }
    var timeLabel: String { measuredMs > 0 ? "\(measuredMs) ms" : state == .unverifiable ? "—" : "<1 ms" }

    init(area: DiagnosticArea, checks: [DiagnosticCheck], since start: Date) {
        self.area = area; self.checks = checks
        elapsedMs = max(0, Int(Date().timeIntervalSince(start) * 1000), checks.map(\.elapsedMs).max() ?? 0)
        if checks.contains(where: { $0.state == .failed }) { state = .failed }
        else if checks.allSatisfy({ $0.state == .unverifiable }) { state = .unverifiable }
        else if checks.contains(where: { $0.state != .passed }) { state = .partial }
        else { state = .passed }
    }
}

enum DiagnosticEventKind: String, Codable, Sendable {
    case lookupStarted, durationRead, durationUnavailable, providerMatched, providerUnavailable
    case assetRejected, playbackStarted, playbackPaused, playbackStalled, playbackFailed, videoFallbackRequested, seek, audioInterruption
    case artworkLoaded, artworkUnavailable, lyricsLoaded, lyricsUnavailable
    case foreground, background, playerOpened, playerClosed, immersiveOn, immersiveOff, stageReady, stageError
}

enum DiagnosticSource: String, Codable, Sendable {
    case local, navidrome, netease, qq, youtube, sonnet, lumiere

    var title: String {
        switch self {
        case .local: "本機"
        case .navidrome: "Navidrome"
        case .netease: "網易雲"
        case .qq: "QQ 音樂"
        case .youtube: "YouTube"
        case .sonnet: "商籟"
        case .lumiere: "繪光"
        }
    }
}

struct DiagnosticEvent: Codable, Equatable, Sendable {
    let at: Date
    let kind: DiagnosticEventKind
    var source: DiagnosticSource? = nil
    var problem: DiagnosticProblem? = nil
    var elapsedMs: Int? = nil
}

enum DiagnosticNetwork: String, Codable, Sendable { case wifi, cellular, wired, other, offline, unknown }
enum DiagnosticEnvironment: String, Codable, Sendable { case iphone, simulator, ciFixture }

struct DiagnosticSystemTrace: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case crash, hang }
    let kind: Kind
    let foliaOffsets: [UInt64]

    static func foliaOffsets(_ data: Data) -> [UInt64] {
        guard data.count <= 1_000_000, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var offsets: [UInt64] = []
        func visit(_ value: [String: Any], depth: Int) {
            guard depth < 32, offsets.count < 24 else { return }
            if let binary = value["binaryName"] as? String, ["Syllume", "Folia"].contains(binary), let offset = value["offsetIntoBinaryTextSegment"] as? UInt64,
               offset < (1 << 34) {
                offsets.append(offset)
            }
            for key in ["callStacks", "callStackRootFrames", "subFrames"] {
                for next in (value[key] as? [[String: Any]] ?? []).prefix(64) { visit(next, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return offsets
    }
}

struct DiagnosticReport: Codable, Identifiable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let appVersion: String
    let build: String
    let operatingSystem: String
    let deviceModel: String
    let environment: DiagnosticEnvironment
    let startedAt: Date
    let endedAt: Date
    let connection: DiagnosticNetwork
    let stopReason: DiagnosticCode?
    let requestedAreas: [DiagnosticArea]
    let results: [DiagnosticResult]
    let events: [DiagnosticEvent]
    let systemTraces: [DiagnosticSystemTrace]
    let reproduction: [String]
    let notCovered: [String]

    var retryAreas: Set<DiagnosticArea> {
        Set(requestedAreas).subtracting(results.filter { $0.state == .passed }.map(\.area))
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    var text: String {
        let date = ISO8601DateFormatter()
        let header = ["Syllume Diagnostics · \(appVersion)（build \(build)）", "\(deviceModel) · iOS \(operatingSystem) · \(environment.rawValue)",
                      "\(date.string(from: startedAt)) → \(date.string(from: endedAt)) · \(connection.rawValue)"]
        let sections = results.flatMap { result in
            ["", "\(result.area.title)　\(result.state.title)　\(result.timeLabel)"] + result.checks.flatMap { check in
                var lines = ["• \(check.title) [\(check.id)]｜\(check.state.title)｜\(check.evidence.title)｜\(check.timeLabel)"]
                if let problem = check.problem { lines.append("  \(problem.detail)") }
                if !check.checkpoints.isEmpty { lines.append("  \(check.checkpoints.joined(separator: " → "))") }
                if let note = check.note { lines.append("  \(note)") }
                for key in check.metrics.keys.sorted() { if let value = check.metrics[key] { lines.append("  \(key) = \(value.formatted(.number.precision(.fractionLength(0...3))))") } }
                return lines
            }
        }
        let trace = events.map { event in
            [date.string(from: event.at), event.kind.rawValue, event.source?.rawValue, event.problem?.code.rawValue,
             event.problem?.mediaIssue?.rawValue, event.problem?.httpStatus.map { "HTTP \($0)" },
             event.problem?.nativeCode.map { "native \($0)" },
             event.elapsedMs.map { "\($0)ms" }].compactMap { $0 }.joined(separator: " · ")
        }
        let stacks = systemTraces.map { "\($0.kind.rawValue) · Syllume offsets " + $0.foliaOffsets.map(String.init).joined(separator: ", ") }
        var lines = header
        if let stopReason { lines.append("中止原因　\(stopReason.title)") }
        lines += sections
        lines += ["", "重現步驟"] + reproduction
        lines += ["", "尚未涵蓋"] + notCovered
        lines += ["", "事件紀錄"] + trace + stacks
        return lines.joined(separator: "\n")
    }
}
