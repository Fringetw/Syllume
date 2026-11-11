import Foundation

// A small opt-in availability probe; prints counts only, never lyric text or signed caption URLs.
enum SubtitleSourceProbe {
    static func run() async {
        for (title, artist, length) in [("JANE DOE", "Kenshi Yonezu、Hikaru Utada", 236.0), ("Lemon", "Kenshi Yonezu", 256.0)] {
            do {
                let record = try await PlaybackLookup.within(.seconds(12)) {
                    try await OnlineLyrics.shared.exact(title: title, artist: artist, duration: length)
                }
                if let record, let text = record.syncedLyrics {
                    print("SOURCE PROBE LRCLIB \(title): exactMetadata=true, durationDelta=\(abs(length - record.duration)), timedLines=\(LyricTimeline(lrc: text).lines.count)")
                } else { print("SOURCE PROBE LRCLIB \(title): no verifiable match") }
            } catch {
                print("SOURCE PROBE LRCLIB \(title): unavailable (\(DiagnosticProblem.classify(error).code.rawValue))")
            }
        }
        do {
            let lines = try await SubtitleNetwork.shared.youtubeLyrics(id: "RCXjG2tsojs")
            print("SOURCE PROBE JANE DOE translated upload: timedLines=\(lines.count), bilingualLines=\(lines.filter { !($0.translation ?? "").isEmpty }.count)")
        } catch {
            let code = (error as? SubtitleReadError)?.code ?? "network"
            print("SOURCE PROBE JANE DOE translated upload: unavailable (\(code)); \((error as? SubtitleReadError)?.detail ?? "no structural details")")
        }
        for provider in ["netease", "qq", "ytm"] {
            do {
                let playing = provider == "ytm" ? SubtitleSong(id: "SX_ViT4Ra7k", source: "ytm", title: "Lemon", artist: "米津玄師", durationMs: 275000) : nil
                let found = try await SubtitleNetwork.shared.search("Lemon 米津玄師", provider: provider, netease: "", current: playing)
                guard let candidate = found.first else { print("SOURCE PROBE \(provider): no candidates"); continue }
                print("SOURCE PROBE \(provider): search completed, candidates=\(found.count)")
                let lines = try await SubtitleNetwork.shared.lyrics(candidate, netease: "", original: [])
                print("SOURCE PROBE \(provider): candidates=\(found.count), timedLines=\(lines.count), translatedLines=\(lines.filter { !($0.translation ?? "").isEmpty }.count)")
            } catch {
                let code = (error as? SubtitleReadError)?.code ?? "network"
                print("SOURCE PROBE \(provider): unavailable (\(code)); \((error as? SubtitleReadError)?.detail ?? "no structural details"); this probe does not certify regional availability")
            }
        }
    }
}
