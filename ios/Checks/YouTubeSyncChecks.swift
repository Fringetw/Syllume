import Foundation

enum YouTubeSyncChecks {
    static func run() throws {
        precondition(PlatformLibrary.isoDuration("PT1H2M3S") == 3723)
        precondition(PlatformLibrary.isoDuration("PT4M0.5S") == 240.5)
        precondition(PlatformLibrary.isoDuration("PT") == nil)
        let song = SyncedYouTubeSong(LibraryEntry(id: "row-1", title: "米津玄師 - LOSER (Official Music Video)",
            subtitle: "米津玄師", url: URL(string: "https://music.youtube.com/watch?v=M7lc1UVf-VE")!, duration: 244))!
        precondition(DownloadSongMatch.matches(song, title: "LOSER", artists: ["米津玄師"], duration: 243.8))
        precondition(!DownloadSongMatch.matches(song, title: "LOSER", artists: ["翻唱者"], duration: 244))
        precondition(!DownloadSongMatch.matches(song, title: "LOSER (Live)", artists: ["米津玄師"], duration: 244))
        precondition(!DownloadSongMatch.matches(song, title: "LOSER", artists: ["米津玄師"], duration: 30))
        precondition(!DownloadSongMatch.matches(song, title: "LOSER", artists: ["米津玄師"], duration: nil))
        precondition(DownloadSongMatch.safeAudioURL("http://example.com/song.mp3") == nil)
        precondition(DownloadSongMatch.safeAudioURL("https://user:pass@example.com/song.mp3") == nil)

        let recording = try DownloadSourceDecoders.search(Data(#"{"code":200,"result":{"songs":[{"id":1,"name":"LOSER","ar":[{"name":"米津玄師"}],"dt":244000},{"id":2,"name":"LOSER (Remix)","ar":[{"name":"米津玄師"}],"dt":244000}]}}"#.utf8), for: song)
        precondition(recording.count == 1 && recording[0].id == 1)
        let full = #"{"code":200,"data":[{"id":1,"code":200,"url":"http://m7.music.126.net/song.flac","type":"flac","br":900000,"time":244000,"freeTrialInfo":null}]}"#
        let audio = try DownloadSourceDecoders.audio(Data(full.utf8), recording: recording[0])!
        precondition(audio.lossless && audio.url.scheme == "https")
        let preview = full.replacingOccurrences(of: "\"freeTrialInfo\":null", with: "\"freeTrialInfo\":{\"start\":0,\"end\":30}")
        let rejectedPreview = try DownloadSourceDecoders.audio(Data(preview.utf8), recording: recording[0])
        precondition(rejectedPreview == nil)
        let short = try DownloadSourceDecoders.audio(Data(full.replacingOccurrences(of: "244000", with: "30000").utf8), recording: recording[0])
        precondition(short == nil)
        let impostor = try DownloadSourceDecoders.audio(Data(full.replacingOccurrences(of: "m7.music.126.net", with: "m7.music.126.net.example.com").utf8), recording: recording[0])
        precondition(impostor == nil)
        let mp3 = DownloadAudioCandidate(url: audio.url, title: "LOSER", artist: "米津玄師", duration: 244,
            format: "mp3", bitrate: 320000, source: "測試")
        precondition(DownloadAudioCandidate.preferred(audio, mp3))
        precondition(!DownloadAudioCandidate.preferred(mp3, audio))

        var snapshot = YouTubeSyncSnapshot()
        snapshot.choice = .liked; snapshot.songs = [song]
        snapshot.bindings[song.videoID] = YouTubeAudioBinding(trackID: "local-id", quality: "FLAC")
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(YouTubeSyncSnapshot.self, from: data)
        precondition(decoded == snapshot && decoded.choice?.collection == .liked)
        precondition(!String(decoding: data, as: UTF8.self).contains("music.126.net"))
        print("PASS: playlist persistence, version/artist/duration matching, lossless priority, preview and CDN rejection")
    }
}
