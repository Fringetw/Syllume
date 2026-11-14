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
        var duplicateA = a, duplicateB = a
        duplicateA.queueID = "first-row"; duplicateB.queueID = "second-row"
        model.play([duplicateA, duplicateB], selected: duplicateB)
        precondition(model.index == 1 && !model.canAdvance)
        model.play([a, b], selected: a); model.setVisible(true)
        precondition(model.seekRevision == nil, "Loading a new video must not issue a seek before playback")
        let session = model.session
        func sample(_ state: Int, _ time: Double, _ otherSession: UUID? = nil, _ otherID: String? = nil,
                    command: Int? = nil, seek: UUID? = nil) -> YouTubeSnapshot {
            YouTubeSnapshot(session: (otherSession ?? session).uuidString, videoID: otherID ?? id, state: state,
                            time: time, duration: 60, title: nil, author: nil,
                            commandRevision: command ?? model.playbackRevision, seekRevision: seek)
        }
        model.receive(sample(1, 3)); precondition(model.isPlaying && model.position == 3)
        let oldCommand = model.playbackRevision
        model.pause(); model.receive(sample(1, 3.1, command: oldCommand))
        precondition(!model.wantsPlayback && !model.isPlaying && model.position == 3)
        model.receive(sample(1, 3.2))
        precondition(model.position == 3, "An unacknowledged pause cannot advance the lyric clock")
        model.receive(sample(2, 3.1)); model.receive(sample(1, 3.2))
        precondition(model.wantsPlayback && model.isPlaying)
        model.receive(sample(2, 3.3, command: oldCommand))
        precondition(model.isPlaying, "An old pause cannot undo a newer resume")
        model.autoplayBlocked(revision: oldCommand)
        precondition(model.isPlaying && model.failure == nil, "A stale blocked event cannot pause the current command")
        model.seek(to: 40)
        let firstSeek = model.seekRevision
        model.receive(sample(1, 39.9))
        precondition(model.position == 40 && model.isSeeking, "Even a nearby snapshot must acknowledge the active seek")
        model.seek(to: 41)
        let latestSeek = model.seekRevision
        model.receive(sample(1, 40, seek: firstSeek))
        model.receive(sample(3, 41.1, seek: latestSeek))
        precondition(model.position == 41 && model.isSeeking, "An older command and a buffering snapshot cannot finish the seek")
        model.receive(sample(1, 41.1, seek: latestSeek))
        precondition(model.position == 41.1 && !model.isSeeking)
        model.setVisible(false); model.receive(sample(1, 42, seek: latestSeek)); precondition(!model.isPlaying && !model.wantsPlayback)
        model.setVisible(true); model.prepareToPlay(); model.next()
        model.receive(sample(0, 60)); precondition(model.current?.id == b.id)
        model.receive(sample(1, .infinity, model.session, b.id)); precondition(model.position == 0)
        model.receive(sample(1, 0, model.session, b.id)); precondition(model.isPlaying)
        model.pause(); model.receive(sample(0, 60, model.session, b.id)); precondition(!model.wantsPlayback)
        model.resume()
        model.autoplayBlocked(revision: model.playbackRevision)
        precondition(model.didBlockAutoplay && !model.wantsPlayback && model.failure?.code == .playbackInteractionRequired)
        model.receive(sample(1, 0.2, model.session, b.id))
        precondition(model.isPlaying && !model.didBlockAutoplay && model.failure == nil)
        let status = try JSONDecoder().decode(YouTubeVideoDetails.Status.self, from: Data(#"{"embeddable":true,"madeForKids":false}"#.utf8))
        precondition(status.allowsEmbeddedPlayback)
        precondition(!YouTubeVideoDetails.Status(embeddable: false, madeForKids: false).allowsEmbeddedPlayback)
        precondition(!YouTubeVideoDetails.Status(embeddable: true, madeForKids: true).allowsEmbeddedPlayback)
        precondition(!YouTubeVideoDetails.Status(embeddable: true, madeForKids: nil).allowsEmbeddedPlayback)
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
