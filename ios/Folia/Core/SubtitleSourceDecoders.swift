import Foundation

// Read-only platform responses. Nothing here translates, invents timing or changes song identity.
enum SubtitleSourceDecoders {
    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 8_000_000, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SubtitleReadError("invalid-response")
        }
        return value
    }
    static func number(_ value: Any?) -> Double {
        let value = (value as? NSNumber)?.doubleValue ?? Double(value as? String ?? "") ?? 0
        return value.isFinite && value >= 0 ? value : 0
    }
    static func identifier(_ value: Any?) -> String { (value as? String) ?? (value as? NSNumber)?.stringValue ?? "" }
    static func check(_ value: Any?, success: Int) throws {
        guard let value else { return }
        guard let code = value as? Int ?? Int(value as? String ?? "") else { throw SubtitleReadError("invalid-response") }
        if code == 301 || code == 401 { throw SubtitleReadError("not-signed-in") }
        if code == 429 || code == 2001 { throw SubtitleReadError("rate-limited") }
        if code != success { throw SubtitleReadError("unavailable") }
    }
    static func neteaseSearch(_ data: Data) throws -> [SubtitleRecord] {
        let root = try object(data)
        try check(root["code"], success: 200)
        guard let result = root["result"] as? [String: Any] else { throw SubtitleReadError("invalid-response") }
        if result["songs"] == nil, number(result["songCount"]) == 0 { return [] }
        guard let songs = result["songs"] as? [[String: Any]] else { throw SubtitleReadError("invalid-response") }
        return songs.prefix(8).compactMap { song in
            let id = identifier(song["id"])
            guard !id.isEmpty, id.allSatisfy(\.isNumber), let title = song["name"] as? String else { return nil }
            let artists = (song["artists"] ?? song["ar"]) as? [[String: Any]] ?? []
            let duration = number(song["duration"] ?? song["dt"])
            guard duration <= 3_600_000 else { return nil }
            return SubtitleRecord(song: SubtitleSong(id: id, source: "netease", title: title,
                artist: artists.compactMap { $0["name"] as? String }.joined(separator: " / "),
                durationMs: duration))
        }
    }
    static func neteaseLyrics(_ data: Data) throws -> [LyricLine] {
        let root = try object(data)
        try check(root["code"], success: 200)
        let text = { (key: String) in (root[key] as? [String: Any])?["lyric"] as? String ?? "" }
        return bilingual(original: text("lrc"), translation: text("tlyric"), romanization: text("romalrc"))
    }
    static func qqSearch(_ data: Data) throws -> [SubtitleRecord] {
        let root = try object(data)
        try check(root["code"], success: 0)
        guard let data = root["data"] as? [String: Any], let song = data["song"] as? [String: Any],
              let list = song["list"] as? [[String: Any]] else { throw SubtitleReadError("invalid-response") }
        return list.prefix(8).compactMap { item in
            let id = identifier(item["songid"])
            guard !id.isEmpty, id.allSatisfy(\.isNumber), let title = item["songname"] as? String else { return nil }
            let artists = (item["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.map {
                // QQ appends a kana reading to Japanese names; it is an alias, not a second performer.
                $0.replacingOccurrences(of: #"\s*[（(][\p{Hiragana}\p{Katakana}ー\s]+[）)]\s*$"#, with: "", options: .regularExpression)
            }
            let duration = number(item["interval"])
            guard duration <= 3600 else { return nil }
            return SubtitleRecord(song: SubtitleSong(id: id, source: "qq", title: entities(title),
                artist: artists.map(entities).joined(separator: " / "), durationMs: duration * 1000))
        }
    }
    static func qqLyrics(_ data: Data) throws -> [LyricLine] {
        let root = try object(data)
        try check(root["code"], success: 0)
        guard let response = root["request"] as? [String: Any], let body = response["data"] as? [String: Any] else {
            throw SubtitleReadError("invalid-response")
        }
        try check(response["code"], success: 0)
        // crypt=0 and qrc=0 ask for the platform's own Base64 LRC and translation, not encrypted QRC.
        guard number(body["crypt"]) == 0, number(body["qrc"]) == 0 else { throw SubtitleReadError("invalid-response") }
        func text(_ key: String) -> String {
            guard let encoded = body[key] as? String else { return "" }
            if encoded.hasPrefix("[") { return entities(encoded) }
            guard let data = Data(base64Encoded: encoded), let text = String(data: data, encoding: .utf8) else { return "" }
            return entities(text)
        }
        return bilingual(original: text("lyric"), translation: text("trans"), romanization: text("roma"))
    }
    static func bilingual(original: String, translation: String, romanization: String = "") -> [LyricLine] {
        let original = LyricTimeline(lrc: original).lines
        let translated = LyricTimeline(lrc: translation).lines
        let romanized = LyricTimeline(lrc: romanization).lines
        return attach(original, translations: translated, romanizations: romanized)
    }
    static func attach(_ original: [LyricLine], translations: [LyricLine], romanizations: [LyricLine] = []) -> [LyricLine] {
        // Sorted timestamps and binary search avoid quadratic work on hostile / oversized responses.
        func at(_ lines: [LyricLine], time: Double) -> String? {
            var low = 0, high = lines.count
            while low < high {
                let mid = (low + high) / 2
                if lines[mid].startTime < time - 0.15 { low = mid + 1 } else { high = mid }
            }
            let matches = lines.dropFirst(low).prefix(while: { $0.startTime <= time + 0.15 })
            // Ambiguous overlapping rows are left unmerged.
            return matches.count == 1 ? matches.first?.fullText : nil
        }
        return original.map { line in
            var line = line
            if let text = at(translations, time: line.startTime) { line.translation = text }
            if let text = at(romanizations, time: line.startTime) { line.romanization = text }
            return line
        }
    }
    static func entities(_ text: String) -> String {
        let pattern = #"&(?:#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let entity = String(result[range])
            let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " "]
            var replacement = named[entity]
            if entity.hasPrefix("&#") {
                let hex = entity.hasPrefix("&#x")
                let digits = entity.dropFirst(hex ? 3 : 2).dropLast()
                if let n = UInt32(digits, radix: hex ? 16 : 10), let scalar = UnicodeScalar(n) { replacement = String(scalar) }
            }
            if let replacement { result.replaceSubrange(range, with: replacement) }
        }
        return result
    }
}
