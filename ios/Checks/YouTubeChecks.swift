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
        let model = YouTubePlayback(lyricDirectory: root, lookup: { _, _, _ in nil })
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
        let seekStart = ContinuousClock().now
        model.seek(to: 41, now: seekStart)
        let latestSeek = model.seekRevision
        model.receive(sample(1, 40, seek: firstSeek))
        model.receive(sample(3, 41.1, seek: latestSeek))
        precondition(model.position == 41 && model.isSeeking, "An older command and a buffering snapshot cannot finish the seek")
        model.receive(sample(3, 3.2, seek: latestSeek), now: seekStart.advanced(by: .seconds(5)))
        precondition(model.position == 41 && model.isSeeking, "Long buffering must not return the playhead to its previous position")
        model.receive(sample(0, 60, seek: latestSeek), now: seekStart.advanced(by: .seconds(5)))
        precondition(model.current?.id == a.id && model.isSeeking, "A stale end must not advance the queue after seeking away from the end")
        model.receive(sample(1, 41.1, seek: latestSeek), now: seekStart.advanced(by: .seconds(6)))
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
        checkTransportWatchdog(a, b, directory: root)
        checkCoarseTransportSamples(a, directory: root)
        print("PASS: YouTube link validation, stale sessions, pause/seek ordering, playback watchdog, queue and lyric matching")
    }

    @MainActor private static func checkTransportWatchdog(_ a: YouTubeVideo, _ b: YouTubeVideo, directory: URL) {
        var updates = 0
        let player = YouTubePlayback(lyricDirectory: directory, automaticallyMatchesLyrics: false,
                                     onTransportWatchdogChange: { updates += 1 })
        player.play([a, b], selected: a)
        player.setVisible(true)
        let base = ContinuousClock().now
        let firstSession = player.session
        func frame(_ state: Int, _ time: Double, _ after: Duration, seek: UUID? = nil) {
            guard let video = player.current else { preconditionFailure("Test video is missing") }
            player.receive(YouTubeSnapshot(session: player.session.uuidString, videoID: video.id, state: state,
                                           time: time, duration: 60, title: nil, author: nil,
                                           commandRevision: player.playbackRevision, seekRevision: seek),
                           now: base + after)
        }

        frame(1, 0, .zero)
        frame(1, 0.5, .milliseconds(500))
        player.checkTransportWatchdog(session: firstSession, now: base + .seconds(4))
        precondition(player.isBuffering && !player.isPlaying && player.wantsPlayback && updates == 1,
                     "A silent bridge should stop claiming playback before its recovery deadline")
        frame(1, 0.5, .seconds(5))
        precondition(player.isBuffering && !player.isPlaying, "An unchanged playing snapshot cannot clear a stall")
        frame(1, 1.0, .seconds(7))
        precondition(player.isPlaying && !player.isBuffering, "Actual progress should recover a short stall")
        player.checkTransportWatchdog(session: firstSession, now: base + .seconds(24))
        precondition(player.failure == nil && player.wantsPlayback, "Recovery must refresh the clock deadline")
        player.checkTransportWatchdog(session: firstSession, now: base + .seconds(26))
        precondition(player.failure == DiagnosticProblem(code: .timeout, nativeCode: -3) && !player.wantsPlayback,
                     "Only a prolonged stall after valid progress should report the stopped clock")

        player.next()
        let nextSession = player.session
        player.checkTransportWatchdog(session: firstSession, now: base + .seconds(60))
        precondition(player.current?.id == b.id && player.wantsPlayback && player.failure == nil,
                     "An old watchdog must not interrupt the next song")
        player.checkTransportWatchdog(session: nextSession, now: base + .seconds(24))
        precondition(player.failure == nil && player.wantsPlayback,
                     "The first media frame retains its bounded startup grace")
        player.checkTransportWatchdog(session: nextSession, now: base + .seconds(26))
        precondition(player.failure == DiagnosticProblem(code: .timeout, nativeCode: -2),
                     "Waiting for the first media frame has its own diagnostic")
        player.retry()
        let secondSession = player.session
        player.pause()
        frame(2, 2, .seconds(27))
        player.seek(to: 50, now: base + .seconds(28))
        let frozenSeek = player.seekRevision
        frame(2, 2, .seconds(33), seek: frozenSeek)
        precondition(player.isSeeking && player.position == 50, "Acknowledging the command without a new position cannot settle a seek")
        player.checkTransportWatchdog(session: secondSession, now: base + .seconds(41))
        precondition(player.failure == DiagnosticProblem(code: .timeout, nativeCode: -4)
                     && !player.isSeeking && !player.isPlaying && !player.wantsPlayback && player.position == 2,
                     "A timed-out pause seek must restore its last confirmed position")
        frame(2, 50, .seconds(42), seek: frozenSeek)
        precondition(player.position == 2, "A late acknowledgment must not reopen a timed-out seek")
        player.seek(to: 48, now: base + .seconds(43))
        player.seek(to: 47, now: base + .seconds(46))
        player.checkTransportWatchdog(session: secondSession, now: base + .seconds(56))
        precondition(player.isSeeking && player.failure == nil, "The older deadline must not time out the newer seek")
        frame(2, 46.5, .seconds(57), seek: player.seekRevision)
        precondition(!player.isSeeking && !player.wantsPlayback && player.position == 46.5 && player.failure == nil)

        player.seek(to: 55, now: base + .seconds(58))
        let beforeHide = updates
        player.setVisible(false)
        player.checkTransportWatchdog(session: secondSession, now: base + .seconds(90))
        precondition(updates == beforeHide && !player.isSeeking && player.failure == nil,
                     "Leaving the visible surface must cancel an unresolved seek")
        player.stop()
    }

    @MainActor private static func checkCoarseTransportSamples(_ video: YouTubeVideo, directory: URL) {
        for startsWithFineSample in [false, true] {
            let player = YouTubePlayback(lyricDirectory: directory, automaticallyMatchesLyrics: false)
            player.play([video], selected: video)
            player.setVisible(true)
            let base = ContinuousClock().now
            let session = player.session
            func frame(_ time: Double, after elapsed: Duration) {
                player.receive(YouTubeSnapshot(session: session.uuidString, videoID: video.id, state: 1,
                                               time: time, duration: 60, title: nil, author: nil,
                                               commandRevision: player.playbackRevision), now: base + elapsed)
            }
            frame(0, after: .zero)
            let initialTime = startsWithFineSample ? 0.5 : 0
            let initialOffset: Duration = startsWithFineSample ? .milliseconds(500) : .zero
            if startsWithFineSample { frame(initialTime, after: initialOffset) }
            for step in 1...13 {
                let elapsed = Duration.seconds(step * 2) + initialOffset
                frame(Double(step * 2) + initialTime, after: elapsed)
                player.checkTransportWatchdog(session: session, now: base + elapsed)
                precondition(player.isPlaying && !player.isBuffering && player.wantsPlayback && player.failure == nil,
                             "Two-second media samples must count as real progress, including at startup")
            }

            let lastTime = 26 + initialTime
            let lastOffset = Duration.seconds(26) + initialOffset
            frame(lastTime, after: lastOffset + .seconds(4))
            precondition(player.isBuffering && !player.isPlaying,
                         "An unchanged playing sample must still expose a frozen clock")
            player.checkTransportWatchdog(session: session, now: base + lastOffset + .seconds(17))
            precondition(player.failure == nil && player.wantsPlayback)
            player.checkTransportWatchdog(session: session, now: base + lastOffset + .seconds(19))
            precondition(player.failure == DiagnosticProblem(code: .timeout, nativeCode: -3) && !player.wantsPlayback,
                         "Coarse samples must not disable the 18-second stalled-clock deadline")
            player.stop()
        }
        print("PASS: coarse YouTube media samples at startup and during playback, with frozen-clock timeout")
    }
}
