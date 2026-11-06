import Foundation

struct YouTubeCaptionTrack: Sendable, Equatable {
    let url: URL
    let language: String
    let automatic: Bool
    let original: Bool
    var chinese: Bool { language.lowercased() == "zh" || language.lowercased().hasPrefix("zh-") }
}

// Public page data only; do not evaluate page scripts or manufacture machine-translated tracks.
enum YouTubeCaptionDecoders {
    static func embeddedObject(_ page: String, name: String) throws -> [String: Any] {
        guard page.utf8.count <= 8_000_000 else { throw SubtitleReadError("invalid-response") }
        for marker in [name + " =", name + "=", "[\"" + name + "\"] =", "[\"" + name + "\"]="] {
            guard let found = page.range(of: marker),
                  let start = page[found.upperBound...].firstIndex(of: "{") else { continue }
            var quoted = false, escaped = false, depth = 0, cursor = start
            while cursor < page.endIndex {
                let char = page[cursor]
                if quoted {
                    if escaped { escaped = false }
                    else if char == "\\" { escaped = true }
                    else if char == "\"" { quoted = false }
                } else if char == "\"" { quoted = true }
                else if char == "{" { depth += 1; if depth > 128 { break } }
                else if char == "}" {
                    depth -= 1
                    if depth == 0 { return try SubtitleSourceDecoders.object(Data(page[start...cursor].utf8)) }
                }
                cursor = page.index(after: cursor)
            }
        }
        if page.contains("consent.youtube.com") || page.contains("/sorry/") || page.contains("unusual traffic") {
            throw SubtitleReadError("verification-required")
        }
        throw SubtitleReadError("invalid-response")
    }
    private static func text(_ raw: Any?) -> String {
        if let raw = raw as? String { return raw }
        guard let value = raw as? [String: Any] else { return "" }
        return (value["simpleText"] as? String) ?? (value["runs"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }.joined()
    }
    static func searchURL(_ query: String) -> URL {
        var url = URLComponents(string: "https://www.youtube.com/results")!
        // Observed from YouTube's visible Subtitles/CC filter. URLComponents encodes the percent signs once more.
        url.queryItems = [.init(name: "search_query", value: query + " 中文字幕"),
            .init(name: "sp", value: "EgIoAQ%3D%3D"), .init(name: "hl", value: "zh-TW"), .init(name: "gl", value: "TW")]
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return url.url!
    }
    static func search(_ page: String) throws -> [SubtitleRecord] {
        let root = try embeddedObject(page, name: "ytInitialData")
        var songs: [SubtitleRecord] = [], seen = Set<String>(), visits = 0
        func visit(_ node: Any, depth: Int) {
            guard depth < 64, visits < 50_000, songs.count < 8 else { return }
            visits += 1
            if let dict = node as? [String: Any] {
                if let video = dict["videoRenderer"] as? [String: Any], let id = video["videoId"] as? String,
                   YouTubeVideo.validID(id), seen.insert(id).inserted {
                    let title = text(video["title"]), artist = text(video["ownerText"] ?? video["longBylineText"])
                    let parts = text(video["lengthText"]).split(separator: ":").compactMap { Double($0) }
                    let seconds = parts.reduce(0) { $0 * 60 + $1 }
                    if !title.isEmpty, !artist.isEmpty, seconds > 0, seconds <= 3600 {
                        songs.append(SubtitleRecord(song: metadata(id: id, title: title, artist: artist, duration: seconds)))
                    }
                    return
                }
                // Dictionary order is not stable; preserve the site's result order via its content arrays.
                for key in dict.keys.sorted() { if let value = dict[key] { visit(value, depth: depth + 1) } }
            } else if let list = node as? [Any] { for value in list { visit(value, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        guard !songs.isEmpty || root["estimatedResults"] as? String == "0" else { throw SubtitleReadError("invalid-response") }
        return songs
    }
    static func metadata(id: String, title: String, artist: String, duration: Double) -> SubtitleSong {
        // Only presentation labels are removed. Live/cover/remix/version markers must remain.
        let labels = #"\s*[【\[(（]\s*(?:中[日英韓]?字幕|中[日英韓]雙語字幕|中文字幕|中字|中文翻譯|中文翻译|CC字幕|official(?: music)? (?:video|audio)|lyrics?(?: video)?)\s*[】\])）]\s*"#
        let clean = title.replacingOccurrences(of: labels, with: " ", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let titleParts = clean.components(separatedBy: " - ")
        // An explicit Artist - Song credit is more useful than a translation channel's name.
        let prefixArtist = titleParts.count == 2 && !titleParts[0].isEmpty ? titleParts[0] : artist
        let uploader = artist.replacingOccurrences(of: #"\s*-\s*Topic\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let key = { (text: String) in text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber } }
        // Official titles often add a Latin alias, e.g. 米津玄師 Kenshi Yonezu - Lemon.
        // Keep the attested channel name when it is part of that artist credit.
        func scriptAlias(_ text: String) -> String? {
            let pattern = #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}ー・]{2,40}"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            guard matches.count == 1, let range = Range(matches[0].range, in: text) else { return nil }
            return String(text[range])
        }
        let latin = { (text: String) in key(text.replacingOccurrences(of: #"[^\p{Latin}]"#, with: "", options: .regularExpression)) }
        let sharedAlias = scriptAlias(prefixArtist)
        let aliasesAgree = sharedAlias != nil && sharedAlias == scriptAlias(uploader)
            && latin(prefixArtist).count >= 3 && latin(prefixArtist) == latin(uploader)
        let creditedArtist = aliasesAgree ? sharedAlias!
            : key(uploader).count >= 3 && key(prefixArtist).contains(key(uploader)) ? uploader : prefixArtist
        let creditedTitle = titleParts.count == 2 && !titleParts[1].isEmpty ? titleParts[1] : clean
        return SubtitleSong(id: id, source: "ytm", title: creditedTitle, artist: creditedArtist, durationMs: duration * 1000)
    }
    static func tracks(_ page: String, videoID: String) throws -> [YouTubeCaptionTrack] {
        let root = try embeddedObject(page, name: "ytInitialPlayerResponse")
        if let status = root["playabilityStatus"] as? [String: Any], let value = status["status"] as? String, value != "OK" {
            let reason = (status["reason"] as? String ?? "").lowercased()
            let challenge = reason.contains("bot") || reason.contains("verify") || reason.contains("驗證")
            throw SubtitleReadError(value == "LOGIN_REQUIRED" && !challenge ? "not-signed-in" : "verification-required")
        }
        guard let details = root["videoDetails"] as? [String: Any], details["videoId"] as? String == videoID else {
            throw SubtitleReadError("invalid-response")
        }
        let captions = root["captions"] as? [String: Any]
        let renderer = captions?["playerCaptionsTracklistRenderer"] as? [String: Any]
        let listed = renderer?["captionTracks"] as? [[String: Any]] ?? []
        let audio = renderer?["audioTracks"] as? [[String: Any]] ?? []
        let audioIndex = renderer?["defaultAudioTrackIndex"] as? Int ?? 0
        let defaultIndex = audio.indices.contains(audioIndex) ? audio[audioIndex]["defaultCaptionTrackIndex"] as? Int : nil
        return listed.prefix(60).enumerated().compactMap { index, track in
            guard let language = track["languageCode"] as? String, let raw = track["baseUrl"] as? String,
                  var parts = URLComponents(string: raw), allowedCaptionURL(parts.url),
                  !(parts.queryItems ?? []).contains(where: { $0.name == "tlang" }) else { return nil }
            var query = (parts.queryItems ?? []).filter { $0.name != "fmt" }
            query.append(URLQueryItem(name: "fmt", value: "json3")); parts.queryItems = query
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = parts.url else { return nil }
            return YouTubeCaptionTrack(url: url, language: language, automatic: track["kind"] as? String == "asr", original: index == defaultIndex)
        }
    }
    static func allowedCaptionURL(_ url: URL?) -> Bool {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil, parts.port == nil,
              ["www.youtube.com", "youtube.com"].contains(parts.host?.lowercased() ?? ""), parts.path == "/api/timedtext" else { return false }
        return true
    }
    static func cues(_ data: Data, chinese: Bool = false) throws -> [LyricLine] {
        let root = try SubtitleSourceDecoders.object(data)
        guard let events = root["events"] as? [[String: Any]], events.count <= 20_000 else { throw SubtitleReadError("invalid-response") }
        let lines = events.compactMap { event -> LyricLine? in
            guard let segments = event["segs"] as? [[String: Any]], segments.count <= 2000,
                  event["tStartMs"] != nil, event["dDurationMs"] != nil else { return nil }
            guard let startValue = event["tStartMs"] as? NSNumber, let lengthValue = event["dDurationMs"] as? NSNumber,
                  startValue.doubleValue.isFinite, startValue.doubleValue >= 0, lengthValue.doubleValue.isFinite else { return nil }
            let start = startValue.doubleValue / 1000
            let duration = SubtitleSourceDecoders.number(event["dDurationMs"]) / 1000
            let text = segments.compactMap { $0["utf8"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard start <= 3600, duration > 0, duration <= 120, !text.isEmpty, text.utf8.count <= 64_000,
                  !text.contains("\u{0000}") else { return nil }
            if chinese, let pair = bilingualCue(text) {
                return LyricLine(startTime: start, endTime: start + duration, fullText: pair.original, translation: pair.chinese)
            }
            return LyricLine(startTime: start, endTime: start + duration, fullText: text)
        }
        return LyricTimeline(lines: lines).lines
    }
    private static func bilingualCue(_ text: String) -> (original: String, chinese: String)? {
        let rows = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard (2...6).contains(rows.count) else { return nil }
        var originals: [String] = [], translations: [String] = []
        for row in rows {
            let kanaOrHangul = row.range(of: #"[\p{Hiragana}\p{Katakana}\p{Hangul}]"#, options: .regularExpression) != nil
            let han = row.unicodeScalars.filter { $0.properties.isIdeographic }.count
            let letters = row.unicodeScalars.filter { $0.properties.isAlphabetic }.count
            if !kanaOrHangul, han >= 2, han * 2 >= letters { translations.append(row) }
            else if kanaOrHangul || (han == 0 && row.range(of: "[A-Za-z]", options: .regularExpression) != nil) { originals.append(row) }
            else { return nil } // Two all-Han rows or ambiguous text cannot prove which one is the original.
        }
        guard !originals.isEmpty, !translations.isEmpty else { return nil }
        return (originals.joined(separator: "\n"), translations.joined(separator: "\n"))
    }
    static func bilingual(chinese: [LyricLine], original: [LyricLine]?, sameVideoBaseline: [LyricLine] = []) -> [LyricLine] {
        // Only the very same video may use its existing lyric clock without a second original track.
        // Other videos must supply their own original text for the plugin to prove a cross-video match.
        let original = original?.isEmpty == false ? original! : sameVideoBaseline
        guard !original.isEmpty else { return chinese }
        let translatedText = chinese.map { line in
            LyricLine(startTime: line.startTime, endTime: line.endTime, fullText: line.translation ?? line.fullText)
        }
        let paired = SubtitleSourceDecoders.attach(original, translations: translatedText)
        return paired.contains(where: { $0.translation != nil }) ? paired : chinese
    }
}
