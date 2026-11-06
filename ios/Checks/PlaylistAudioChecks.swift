import Foundation

enum PlaylistAudioChecks {
    static func run() throws {
        precondition(YouTubePlaylistChoice.liked.collection == .liked)
        precondition(YouTubePlaylistChoice(id: "PL_valid-123", title: "a").valid)
        precondition(!YouTubePlaylistChoice(id: "../other-account", title: "a").valid)
        let choice = YouTubePlaylistChoice(id: "PL_saved", title: "最後選取的清單")
        let entry = LibraryEntry(id: "row-1", title: "Ref:rain (Official Music Video)", subtitle: "Aimer - Topic",
            url: URL(string: "https://music.youtube.com/watch?v=abcdefghijk")!, duration: 290)
        let cache = YouTubePlaylistCache(choice: choice, entries: [entry, LibraryEntry(id: "row-2", title: entry.title,
            subtitle: entry.subtitle, url: entry.url, duration: entry.duration)])
        let restored = try JSONDecoder().decode(YouTubePlaylistCache.self, from: JSONEncoder().encode(cache))
        precondition(restored.choice == choice && restored.entries.map(\.id) == ["row-1", "row-2"])
        precondition(restored.entries.map(PlaylistAudioRules.videoID) == ["abcdefghijk", "abcdefghijk"])
        precondition(PlaylistAudioRules.duration("PT4M50S") == 290)
        precondition(PlaylistAudioRules.duration("PT1H2M3.5S") == 3723.5)
        precondition(PlaylistAudioRules.duration("PT") == nil && PlaylistAudioRules.duration("not-duration") == nil)
        let detailsURL = try PlatformLibrary.videoDetailsURL(["abcdefghijk"])
        precondition(detailsURL.host == "www.googleapis.com")
        precondition((try? PlatformLibrary.videoDetailsURL(["https://evil.example"])) == nil)
        precondition((try? PlatformLibrary.videoDetailsURL(Array(repeating: "abcdefghijk", count: 51))) == nil)
        let request = SubtitleSong(id: "abcdefghijk", source: "ytm", title: "Ref:rain", artist: "Aimer", durationMs: 290000)
        let song = SubtitleSong(id: "123", source: "netease", title: "Ref:rain", artist: "Aimer", durationMs: 290000)
        precondition(PlaylistAudioRules.matches(song, requested: request))
        precondition(PlaylistAudioRules.artistKey("Aimer - Topic") == PlaylistAudioRules.artistKey("Aimer"))
        precondition(PlaylistAudioRules.titleKey("Ref:rain (Official Music Video)") == PlaylistAudioRules.titleKey("Ref:rain"))
        for (title, artist, time) in [("Ref:rain live", "Aimer", 290000.0), ("Ref:rain", "another singer", 290000.0),
                                      ("Ref:rain remix", "Aimer", 290000.0), ("Ref:rain", "Aimer", 30000.0)] {
            precondition(!PlaylistAudioRules.matches(SubtitleSong(id: "x", source: "qq", title: title,
                artist: artist, durationMs: time), requested: request))
        }
        precondition(PlaylistAudioRules.validAudioURL(URL(string: "https://m1.music.126.net/audio.mp3")!, provider: "netease"))
        for value in ["http://m1.music.126.net/audio.mp3", "https://music.126.net.evil.example/file",
                      "https://name:password@m1.music.126.net/file", "https://m1.music.126.net:8443/file"] {
            precondition(!PlaylistAudioRules.validAudioURL(URL(string: value)!, provider: "netease"))
        }
        let json: [String: Any] = ["code": 200, "data": [
            ["id": 123, "code": 200, "url": "https://m1.music.126.net/standard.mp3", "type": "mp3", "br": 128000],
            ["id": 123, "code": 200, "url": "https://m1.music.126.net/best.flac", "type": "flac", "br": 999000, "level": "hires"],
            ["id": 123, "code": 200, "url": "https://m1.music.126.net/trial.mp3", "type": "mp3", "br": 320000, "freeTrialInfo": ["start": 0, "end": 30]],
            ["id": 999, "code": 200, "url": "https://m1.music.126.net/wrong.mp3", "type": "mp3"],
            ["id": 123, "code": 403, "url": "https://m1.music.126.net/blocked.mp3", "type": "mp3"],
            ["id": 123, "code": 200, "url": "https://evil.example/audio.flac", "type": "flac"]]]
        let found = try PlaylistAudioRules.neteaseAudio(JSONSerialization.data(withJSONObject: json), song: song)
        precondition(found.count == 2 && found.sorted(by: PlaylistAudioRules.better).first?.fileExtension == "flac")
        let qq: [String: Any] = ["code": 0, "req_0": ["code": 0, "data": [
            "sip": ["https://dl.stream.qqmusic.qq.com/"],
            "midurlinfo": [
                ["filename": "M800MEDIA.mp3", "purl": "M800MEDIA.mp3?vkey=test", "result": 0, "ekey": ""],
                ["filename": "F000MEDIA.flac", "purl": "F000MEDIA.flac?vkey=test", "result": 0, "ekey": ""],
                ["filename": "RS01MEDIA.flac", "purl": "RS01MEDIA.flac?vkey=test", "result": 0, "ekey": "encrypted"],
                ["filename": "C400MEDIA.m4a", "purl": "https://evil.example/f.m4a", "result": 0, "ekey": ""]]]]]
        let qqSources = try PlaylistAudioRules.qqAudio(JSONSerialization.data(withJSONObject: qq), song: song, mediaID: "MEDIA")
        precondition(qqSources.count == 2 && qqSources.sorted(by: PlaylistAudioRules.better).first?.qualityRank == 60)
        let filename = PlaylistAudioRules.safeFilename(title: String(repeating: "歌曲/", count: 1000), artist: "..\u{0}",
                                                       id: "12345678", ext: "flac")
        precondition(PlaylistAudioRules.validBasename(filename) && filename.utf8.count < 255)
        precondition(!PlaylistAudioRules.validBasename("../audio.mp3") && !PlaylistAudioRules.validBasename(".."))
        let lines = [LyricLine(startTime: 0, endTime: 5, fullText: "頭髮", translation: "hair",
            words: [LyricWord(text: "頭", startTime: 0, endTime: 2), LyricWord(text: "髮", startTime: 2, endTime: 5)])]
        let fia = try LyricTimeline(folia: PlaylistAudioRules.fia(lines))
        precondition(fia.lines == lines)
        print("PASS: playlist persistence and duplicate order, duration evidence, quality priority, trial/DRM rejection and safe files")
    }
}
