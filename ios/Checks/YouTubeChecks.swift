import Foundation

// Exercise real transport state against delayed page messages without contacting a video or lyric service.
enum YouTubeChecks {
    @MainActor static func run() throws {
        let id = "M7lc1UVf-VE"
        for link in ["https://youtu.be/\(id)?t=3", "https://music.youtube.com/watch?v=\(id)", "https://www.youtube.com/shorts/\(id)"] {
            precondition(YouTubeVideo.identifier(from: link) == id)
        }
        for link in ["https://youtube.com.evil.example/watch?v=\(id)", "https://youtube.com@evil.example/watch?v=\(id)",
                     "file:///watch?v=\(id)", "https://youtube.com/watch?v=\(id)&v=\(id)", "https://youtu.be/short",
                     "https://youtube.com/playlist?list=PL123"] {
            precondition(YouTubeVideo.identifier(from: link) == nil)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = YouTubePlayback(lyricDirectory: root) { _, _, _ in nil }
        let a = YouTubeVideo(id: id, title: "A", artist: "Artist")
        let b = YouTubeVideo(id: "dQw4w9WgXcQ", title: "B", artist: "Artist")
        model.play([a, b], selected: a); model.setVisible(true)
        let session = model.session
        func sample(_ state: Int, _ time: Double, _ otherSession: UUID? = nil, _ otherID: String? = nil) -> YouTubeSnapshot {
            YouTubeSnapshot(session: (otherSession ?? session).uuidString, videoID: otherID ?? id, state: state, time: time, duration: 60, title: nil, author: nil)
        }
        model.receive(sample(1, 3)); precondition(model.isPlaying && model.position == 3)
        model.pause(); model.receive(sample(1, 3.1))
        precondition(!model.wantsPlayback && !model.isPlaying)
        model.receive(sample(2, 3.1)); model.receive(sample(1, 3.2))
        precondition(model.wantsPlayback && model.isPlaying)
        model.seek(to: 40); model.receive(sample(1, 3.3)); precondition(model.position == 40)
        model.receive(sample(1, 40.1)); precondition(model.position == 40.1)
        model.setVisible(false); model.receive(sample(1, 41)); precondition(!model.isPlaying && !model.wantsPlayback)
        model.setVisible(true); model.prepareToPlay(); model.next()
        model.receive(sample(0, 60)); precondition(model.current?.id == b.id)
        model.receive(sample(1, .infinity, model.session, b.id)); precondition(model.position == 0)
        model.receive(sample(1, 0, model.session, b.id)); precondition(model.isPlaying)
        model.pause(); model.receive(sample(0, 60, model.session, b.id)); precondition(!model.wantsPlayback)
        let record = LyricSearchRecord(id: 1, trackName: "A", artistName: "Artist", albumName: "", duration: 60,
                                     syncedLyrics: "[00:01]Hello")
        precondition(record.matches(title: "A", artist: "Artist", duration: 61))
        precondition(!record.matches(title: "B", artist: "Artist", duration: 60))
        precondition(!record.matches(title: "A", artist: "Artist", duration: 70))
        let lyricFile = root.appendingPathComponent("source.lrc")
        try Data("[00:01]Hello".utf8).write(to: lyricFile)
        try model.attachLyrics(lyricFile)
        precondition(model.timeline.lines.first?.fullText == "Hello")
        model.stop(); model.play([b], selected: b)
        precondition(model.timeline.lines.first?.fullText == "Hello")
        print("PASS: YouTube link validation, stale sessions, pause/seek ordering, hidden playback, queue and lyric matching")
    }
}
