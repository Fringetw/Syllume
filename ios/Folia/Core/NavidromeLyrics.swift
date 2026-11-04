import Foundation

// Maps the OpenSubsonic songLyrics contract used by Folia to the native timeline.
struct NavidromeLyrics: Decodable {
    let structuredLyrics: [Track]

    struct Track: Decodable {
        let kind: String?
        let offset: Double?
        let synced: Bool?
        let line: [Line]?
        let cueLine: [CueLine]?
        let agents: [Agent]?

        struct Agent: Decodable {
            let id: String
            let role: String?
        }

        struct Line: Decodable {
            let start: Double?
            let value: String
        }

        struct CueLine: Decodable {
            let index: Int
            let start: Double?
            let end: Double?
            let value: String
            let agentId: String?
            let cue: [Cue]?
        }

        struct Cue: Decodable {
            let start: Double?
            let end: Double?
            let value: String
        }

        // A positive OpenSubsonic offset makes lyrics appear sooner.
        func seconds(_ time: Double) -> Double { (time - (offset ?? 0)) / 1000 }
    }

    func timeline() -> LyricTimeline {
        let tracks = structuredLyrics.filter {
            $0.synced != false && ($0.line?.contains { $0.start != nil } == true || $0.cueLine?.isEmpty == false)
        }
        guard let main = tracks.first(where: { $0.kind == "main" })
            ?? tracks.first(where: { $0.kind == nil }) else { return LyricTimeline(lines: []) }
        let translations = tracks.first { $0.kind == "translation" }
        let pronunciations = tracks.first { $0.kind == "pronunciation" }
        let regular = main.line ?? []
        let cues = Dictionary(grouping: main.cueLine ?? [], by: \.index)
        let mainAgents = Set(main.agents?.filter { $0.role == "main" }.map(\.id) ?? [])
        let indices = Set(regular.indices).union(cues.keys.filter { $0 >= 0 }).sorted()
        let entries = indices.compactMap { index -> LyricLine? in
            let options = cues[index] ?? []
            let cue = options.first { $0.agentId.map(mainAgents.contains) == true } ?? options.first
            let line = regular.indices.contains(index) ? regular[index] : nil
            guard let start = (cue?.start ?? line?.start ?? cue?.cue?.first?.start).map(main.seconds),
                  let text = cue?.value ?? line?.value, !text.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            let lineEnd = cue?.end.map(main.seconds)
            let timedCues = (cue?.cue ?? []).filter { $0.start != nil }
            let words = timedCues.enumerated().compactMap { index, word -> LyricWord? in
                guard let wordStart = word.start.map(main.seconds), !word.value.isEmpty else { return nil }
                let next = index + 1 < timedCues.count ? timedCues[index + 1].start.map(main.seconds) : nil
                let end = word.end.map(main.seconds) ?? next ?? lineEnd ?? (wordStart + 1.5)
                return LyricWord(text: word.value, startTime: wordStart, endTime: max(wordStart, end))
            }
            return LyricLine(startTime: start, endTime: max(start, lineEnd ?? start), fullText: text,
                             translation: Self.alternate(in: translations, at: start),
                             romanization: Self.alternate(in: pronunciations, at: start), words: words)
        }
        return LyricTimeline(lines: LyricTimeline.finish(entries))
    }

    private static func alternate(in track: Track?, at time: Double) -> String? {
        guard let track else { return nil }
        return track.line?.first { line in
            line.start.map { abs(track.seconds($0) - time) <= 0.15 } == true
        }?.value
    }
}
