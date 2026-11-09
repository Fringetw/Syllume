import Foundation

// Native timeline for Folia .fia documents and timed LRC files.
struct LyricWord: Codable, Equatable, Sendable {
    let text: String
    let startTime: Double
    let endTime: Double
    var extra: [String: LyricJSON] = [:]
}

struct LyricLine: Codable, Equatable, Sendable {
    let startTime: Double
    var endTime: Double
    let fullText: String
    var translation: String? = nil
    var romanization: String? = nil
    var words: [LyricWord] = []
    var extra: [String: LyricJSON] = [:]
}

struct LyricTimeline: Sendable {
    let lines: [LyricLine]

    private struct FoliaDocument: Decodable {
        let format: String
        let version: Int
        let lyrics: Payload

        struct Payload: Decodable {
            let lines: [LyricLine]
            let isWordByWord: Bool?
        }
    }

    init(lines: [LyricLine]) {
        self.lines = lines.filter {
            $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime >= $0.startTime
        }.map { line in
            var line = line
            if line.extra["backgroundVocals"] == nil, let legacy = line.extra["backgroundVocal"] {
                line.extra["backgroundVocals"] = .array([legacy])
            }
            line.words = Self.alignWords(line.words, to: line.fullText)
            return line
        }.sorted { $0.startTime < $1.startTime }
    }

    init(lrc: String) {
        let lineStamp = #/\[(\d{1,4}):([0-5]?\d)(?:[.:](\d{1,3}))?\]/#
        let wordStamp = #/<(\d{1,4}):([0-5]?\d)(?:[.:](\d{1,3}))?>/#
        let offsetTag = #/\[offset:\s*([+-]?\d+)\s*\]/#
        let offset = lrc.firstMatch(of: offsetTag).flatMap { Double($0.1) } ?? 0
        var entries: [LyricLine] = []
        var wordBudget = 120_000
        for source in lrc.replacingOccurrences(of: "\u{FEFF}", with: "").split(whereSeparator: \.isNewline) {
            guard source.utf8.count <= 64_000 else { continue }
            var remaining = source.trimmingCharacters(in: .whitespaces)[...]
            var stamps: [Double] = []
            var seen = Set<Double>()
            while let match = remaining.prefixMatch(of: lineStamp) {
                let stamp = Self.seconds(match.1, match.2, match.3) - offset / 1000
                if seen.insert(stamp).inserted { stamps.append(stamp) }
                remaining = remaining[match.range.upperBound...]
            }
            guard let first = stamps.first, entries.count + stamps.count <= 20_000 else { continue }
            let text = remaining.trimmingCharacters(in: .whitespaces)
            let tags = text.matches(of: wordStamp)
            let plain = text.replacing(wordStamp, with: "").trimmingCharacters(in: .whitespaces)
            guard !plain.isEmpty else { continue }
            var rawWords = tags.enumerated().compactMap { index, tag -> LyricWord? in
                let next = index + 1 < tags.count ? tags[index + 1] : nil
                let fragment = String(text[tag.range.upperBound..<(next?.range.lowerBound ?? text.endIndex)])
                guard !fragment.isEmpty else { return nil }
                let start = Self.seconds(tag.1, tag.2, tag.3) - offset / 1000
                let end = next.map { Self.seconds($0.1, $0.2, $0.3) - offset / 1000 } ?? (start + 1.5)
                return LyricWord(text: fragment, startTime: start, endTime: max(start, end))
            }
            if let tag = tags.first, tag.range.lowerBound > text.startIndex {
                let prefix = String(text[..<tag.range.lowerBound])
                let end = Self.seconds(tag.1, tag.2, tag.3) - offset / 1000
                rawWords.insert(LyricWord(text: prefix, startTime: first, endTime: max(first, end)), at: 0)
            }
            // One Enhanced LRC row can repeat its entire word list at many timestamps.
            guard rawWords.count <= wordBudget / stamps.count else { continue }
            wordBudget -= rawWords.count * stamps.count
            for stamp in stamps {
                let words = rawWords.map { LyricWord(text: $0.text, startTime: $0.startTime + stamp - first, endTime: $0.endTime + stamp - first) }
                entries.append(LyricLine(startTime: stamp, endTime: stamp, fullText: plain, words: words))
            }
        }
        self.init(lines: Self.finish(entries))
    }

    init(folia data: Data) throws {
        let document = try JSONDecoder().decode(FoliaDocument.self, from: data)
        guard document.format == "folia-lyricdata", document.version == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // The exporter stores a device-specific offset as metadata. The original timeline is portable.
        self.init(lines: document.lyrics.lines.map { line in
            var line = line
            if document.lyrics.isWordByWord == false { line.words = [] }
            return line
        })
    }

    // Preserve duplicate-time translations and infer line-level duration from neighboring entries.
    static func finish(_ entries: [LyricLine]) -> [LyricLine] {
        var sorted: [LyricLine] = []
        for entry in entries.sorted(by: { $0.startTime < $1.startTime }) {
            if let previous = sorted.last, previous.startTime == entry.startTime {
                guard previous.fullText != entry.fullText, previous.translation != entry.fullText else { continue }
                if previous.translation == nil { sorted[sorted.count - 1].translation = entry.fullText }
                else if previous.romanization == nil { sorted[sorted.count - 1].romanization = entry.fullText }
            } else {
                sorted.append(entry)
            }
        }
        return sorted.enumerated().map { index, line in
            var line = line
            if line.endTime <= line.startTime {
                let next = index + 1 < sorted.count ? sorted[index + 1].startTime : line.startTime + 5
                let readableEnd = line.startTime + max(5, Double(line.fullText.count) * 0.5 + 2)
                line.endTime = min(next, max(readableEnd, line.words.last?.endTime ?? readableEnd))
            }
            return line
        }
    }

    // Like Folia's Enhanced LRC exporter, attach punctuation and gaps to the nearest timed word.
    private static func alignWords(_ words: [LyricWord], to fullText: String) -> [LyricWord] {
        guard !words.isEmpty, words.map(\.text).joined() != fullText else { return words }
        var matched: [(LyricWord, Range<String.Index>)] = []
        var cursor = fullText.startIndex
        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let range = fullText.range(of: text, range: cursor..<fullText.endIndex) else {
                return []
            }
            matched.append((word, range))
            cursor = range.upperBound
        }
        return matched.enumerated().map { index, pair in
            let start = index == 0 ? fullText.startIndex : pair.1.lowerBound
            let end = index + 1 < matched.count ? matched[index + 1].1.lowerBound : fullText.endIndex
            return LyricWord(text: String(fullText[start..<end]), startTime: pair.0.startTime, endTime: pair.0.endTime, extra: pair.0.extra)
        }
    }

    /// Keep usable lines when a provider adds a bad tail timestamp, zero-length line, or invalid words.
    func prepared(for duration: Double) -> LyricTimeline {
        let end = duration.isFinite && duration > 0 ? min(duration, 5400) : 5400
        let rows = lines.filter { !$0.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && $0.startTime >= -1 && $0.startTime < end }
        return LyricTimeline(lines: rows.enumerated().compactMap { index, row in
            let start = max(0, row.startTime)
            let next = index + 1 < rows.count ? rows[index + 1].startTime : min(end, start + 8)
            let stop = min(end, row.endTime > start ? row.endTime : max(start + 0.2, next))
            guard stop > start else { return nil }
            var words = row.words.filter { $0.startTime.isFinite && $0.endTime.isFinite
                && $0.endTime > $0.startTime && $0.startTime >= start - 0.25 && $0.endTime <= stop + 0.25 }
            if words.count != row.words.count { words = [] }
            return LyricLine(startTime: start, endTime: stop, fullText: row.fullText, translation: row.translation,
                romanization: row.romanization, words: words, extra: row.extra)
        })
    }

    func activeIndex(at time: Double) -> Int? {
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].startTime <= time { low = mid + 1 } else { high = mid }
        }
        guard low > 0, time < lines[low - 1].endTime else { return nil }
        return low - 1
    }

    private static func seconds(_ minutes: Substring, _ seconds: Substring, _ fraction: Substring?) -> Double {
        let decimal = fraction.flatMap { Double("0." + $0) } ?? 0
        return (Double(minutes) ?? 0) * 60 + (Double(seconds) ?? 0) + decimal
    }
}


enum LyricTimingOffset {
    static func adjusted(_ current: Double, by delta: Double) -> Double {
        guard delta.isFinite else { return current }
        return min(15, max(-15, ((current + delta) * 10).rounded() / 10))
    }

    static func displayed(position: Double, offset: Double) -> Double { max(0, position + offset) }
}
