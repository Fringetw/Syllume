import Foundation
import Observation

// One visible embedded player owns the YouTube clock; old-page messages cannot advance a new song.
@MainActor @Observable
final class YouTubePlayback {
    private(set) var queue: [YouTubeVideo] = []
    private(set) var index = 0
    private(set) var session = UUID()
    private(set) var wantsPlayback = false
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var timeline = LyricTimeline(lines: [])
    private(set) var timelineRevision = UUID()
    private(set) var lyricsLoading = false
    private(set) var lyricsSource: String?
    private(set) var error: String?
    private(set) var seekTime = 0.0
    private(set) var seekRevision = UUID()
    private(set) var visible = false
    @ObservationIgnored private var lyricTask: Task<Void, Never>?
    @ObservationIgnored private var attemptedMatch: String?
    @ObservationIgnored private var matchAttempts = 0
    @ObservationIgnored private var pendingPlayback: Bool?
    @ObservationIgnored private var pendingSeek: (time: Double, date: Date)?
    @ObservationIgnored private let manualLyricRoot: URL?
    @ObservationIgnored private let lookup: @Sendable (String, String, Double) async throws -> LyricSearchRecord?
    var current: YouTubeVideo? { queue.indices.contains(index) ? queue[index] : nil }
    var canAdvance: Bool { index + 1 < queue.count }

    init(lyricDirectory: URL? = nil,
         lookup: @escaping @Sendable (String, String, Double) async throws -> LyricSearchRecord? = {
             try await OnlineLyrics.shared.exact(title: $0, artist: $1, duration: $2)
         }) {
        manualLyricRoot = lyricDirectory; self.lookup = lookup
    }

    func play(_ videos: [YouTubeVideo], selected: YouTubeVideo) {
        guard videos.allSatisfy({ YouTubeVideo.validID($0.id) }) else { return }
        guard let index = videos.firstIndex(of: selected) else { return }
        queue = videos; self.index = index; load()
    }

    func stop() {
        pause(); lyricTask?.cancel(); session = UUID(); queue = []; index = 0
        timeline = LyricTimeline(lines: []); timelineRevision = UUID()
    }

    func setVisible(_ value: Bool) { visible = value; if !value { pause() } }
    func prepareToPlay() { guard current != nil else { return }; wantsPlayback = true; pendingPlayback = true }
    func retry() { guard current != nil else { return }; load() }
    func toggle() { wantsPlayback ? pause() : resume() }
    func resume() { guard current != nil, visible else { return }; error = nil; wantsPlayback = true; pendingPlayback = true }
    func pause() { wantsPlayback = false; isPlaying = false; isBuffering = false; pendingPlayback = false }
    func autoplayBlocked() { pause(); pendingPlayback = nil; error = "請點上方 YouTube 播放器的播放鍵，開始播放。" }
    func next() { guard canAdvance else { return }; index += 1; load() }
    func previous() { if position > 3 || index == 0 { seek(to: 0) } else { index -= 1; load() } }
    func seek(to time: Double) {
        guard time.isFinite, duration > 0 else { return }
        seekTime = min(duration, max(0, time)); position = seekTime; seekRevision = UUID()
        pendingSeek = (seekTime, Date())
    }

    func receive(_ snapshot: YouTubeSnapshot) {
        guard let track = current, snapshot.belongs(to: session, videoID: track.id) else { return }
        guard visible else { pause(); return }
        if let seek = pendingSeek, abs(snapshot.time - seek.time) > 1.5, Date().timeIntervalSince(seek.date) < 2 {
            // A sample queued before the seek must not pull the lyric clock backwards.
        } else { position = snapshot.time; pendingSeek = nil }
        duration = snapshot.duration
        let stalePlay = pendingPlayback == false && snapshot.state == 1
        let stalePause = pendingPlayback == true && snapshot.state == 2
        if !stalePlay && !stalePause {
            isPlaying = snapshot.state == 1; isBuffering = wantsPlayback && snapshot.state == 3
            if snapshot.state == 1 { wantsPlayback = true; pendingPlayback = nil }
            if snapshot.state == 2 { wantsPlayback = false; pendingPlayback = nil }
        }
        if let title = snapshot.title, !title.isEmpty, title != queue[index].title { queue[index].title = title }
        if let author = snapshot.author, !author.isEmpty, author != queue[index].artist { queue[index].artist = author }
        if snapshot.state == 0, pendingSeek == nil { if wantsPlayback && canAdvance { next() } else { pause() }; return }
        if attemptedMatch != "manual", matchAttempts < 4, duration > 0, let track = current {
            let signature = [track.title, track.artist, String(Int(duration.rounded()))].joined(separator: "|")
            if signature != attemptedMatch {
                attemptedMatch = signature
                if lyricsSource == "LRCLIB" { timeline = LyricTimeline(lines: []); timelineRevision = UUID(); lyricsSource = nil }
                matchLyrics()
            }
        }
    }

    func failed(_ code: Int, session: String) {
        guard self.session.uuidString == session else { return }
        pause()
        switch code {
        case 101, 150: error = "這支影片不允許嵌入播放，請選擇其他版本。"
        case 100: error = "這支影片已移除、設為私人或無法提供播放。"
        case 153: error = "YouTube 無法辨識此安裝版本的播放來源。"
        default: error = "YouTube 播放未完成。請檢查網路後重試。"
        }
    }

    func useLyrics(_ record: LyricSearchRecord) {
        guard let text = record.syncedLyrics else { return }
        lyricTask?.cancel(); lyricsLoading = false; attemptedMatch = "manual"
        timeline = LyricTimeline(lrc: text); timelineRevision = UUID(); lyricsSource = "LRCLIB · \(record.trackName) / \(record.artistName)"
    }

    func attachLyrics(_ url: URL) throws {
        guard let current else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: url)
        guard data.count <= 8_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let ext = url.pathExtension.lowercased()
        let parsed = try parseLyrics(data, ext: ext)
        guard !parsed.lines.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let directory = try lyricDirectory()
        try data.write(to: directory.appendingPathComponent(current.id + "." + ext), options: .atomic)
        let other = directory.appendingPathComponent(current.id + (ext == "fia" ? ".lrc" : ".fia"))
        if FileManager.default.fileExists(atPath: other.path) { try FileManager.default.removeItem(at: other) }
        lyricTask?.cancel(); lyricsLoading = false; attemptedMatch = "manual"; timeline = parsed; timelineRevision = UUID(); lyricsSource = "手動附加歌詞"
    }

    private func load() {
        lyricTask?.cancel(); session = UUID(); error = nil; position = 0; duration = 0
        isPlaying = false; isBuffering = true; wantsPlayback = true; attemptedMatch = nil
        matchAttempts = 0
        pendingPlayback = true; pendingSeek = nil
        timeline = LyricTimeline(lines: []); timelineRevision = UUID(); lyricsSource = nil; lyricsLoading = false
        guard let track = current, let directory = try? lyricDirectory() else { return }
        for ext in ["fia", "lrc"] {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(track.id + "." + ext)),
               let parsed = try? parseLyrics(data, ext: ext), !parsed.lines.isEmpty {
                timeline = parsed; timelineRevision = UUID(); lyricsSource = "手動附加歌詞"; attemptedMatch = "manual"; return
            }
        }
    }

    private func matchLyrics() {
        lyricTask?.cancel()
        guard let track = current else { return }
        let request = session
        let artist = track.artist.replacingOccurrences(of: " - Topic", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = duration
        let lookup = lookup
        lyricsLoading = true
        lyricTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            self?.matchAttempts += 1
            let record = try? await lookup(track.title, artist, duration)
            guard let self, self.session == request, !Task.isCancelled else { return }
            lyricsLoading = false
            if let record { timeline = LyricTimeline(lrc: record.syncedLyrics ?? ""); timelineRevision = UUID(); lyricsSource = "LRCLIB" }
        }
    }

    private func lyricDirectory() throws -> URL {
        let root: URL
        if let manualLyricRoot { root = manualLyricRoot }
        else {
            root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Folia/YouTubeLyrics", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func parseLyrics(_ data: Data, ext: String) throws -> LyricTimeline {
        if ext == "fia" { return try LyricTimeline(folia: data) }
        guard ext == "lrc", let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return LyricTimeline(lrc: text)
    }
}
