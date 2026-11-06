import Foundation

enum SubtitleSourceChecks {
    static func run() throws {
        let old = try JSONDecoder().decode(SubtitlePreferences.self, from: Data(#"{"enabled":false,"target":"t","convertOriginal":false,"neteaseAPI":"https://example.com/music"}"#.utf8))
        precondition(!old.enabled && !old.convertOriginal && old.target == "t")
        precondition(old.searchNetease && old.searchQQ && old.searchYouTube)
        let roundTrip = try JSONDecoder().decode(SubtitlePreferences.self, from: JSONEncoder().encode(old))
        precondition(roundTrip == old)
        let netease = try SubtitleSourceDecoders.neteaseSearch(Data(#"{"code":200,"result":{"songs":[{"id":42,"name":"Test","ar":[{"name":"Artist"}],"dt":60000}]}}"#.utf8))
        precondition(netease.first?.song.id == "42" && netease.first?.song.durationMs == 60000)
        let words = try SubtitleSourceDecoders.neteaseLyrics(Data(#"{"code":200,"lrc":{"lyric":"[00:01]Blue sky\n[00:06]Still here"},"tlyric":{"lyric":"[00:01.10]蓝色天空\n[00:08]錯位"},"romalrc":{"lyric":"[00:01]blu skai"}}"#.utf8))
        precondition(words[0].fullText == "Blue sky" && words[0].translation == "蓝色天空" && words[0].romanization == "blu skai")
        precondition(words[1].translation == nil)
        let qq = try SubtitleSourceDecoders.qqSearch(Data(#"{"code":0,"data":{"song":{"list":[{"songid":7,"songname":"A &amp; B","singer":[{"name":"歌手 (かしゅ)"}],"interval":60}]}}}"#.utf8))
        precondition(qq[0].song.title == "A & B" && qq[0].song.artist == "歌手" && qq[0].song.durationMs == 60000)
        let payload: [String: Any] = ["code": 0, "request": ["code": 0, "data": ["crypt": 0, "qrc": 0,
            "lyric": Data("[00:01]Blue sky".utf8).base64EncodedString(), "trans": Data("[00:01]蓝色天空".utf8).base64EncodedString()]]]
        let qqLines = try SubtitleSourceDecoders.qqLyrics(JSONSerialization.data(withJSONObject: payload))
        precondition(qqLines.first?.translation == "蓝色天空")
        for code in [301, 401, 429, 2001, 500] {
            do { try SubtitleSourceDecoders.check(code, success: 0); preconditionFailure("Provider refusal became success") }
            catch let error as SubtitleReadError {
                precondition(error.code == ([301, 401].contains(code) ? "not-signed-in" : [429, 2001].contains(code) ? "rate-limited" : "unavailable"))
            }
        }
        precondition(SubtitleSourceDecoders.entities("&#x98A8; &amp; &#38642;") == "風 & 雲")
        let search = #"var ytInitialData = {"estimatedResults":"1","contents":[{"videoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"【中日字幕】Artist - Song (Live)"}]},"ownerText":{"runs":[{"text":"Translator"}]},"lengthText":{"simpleText":"3:45"}}}]};"#
        let video = try YouTubeCaptionDecoders.search(search)[0].song
        precondition(video.id == "abcdefghijk" && video.title == "Song (Live)" && video.artist == "Artist" && video.durationMs == 225000)
        let official = YouTubeCaptionDecoders.metadata(id: "abcdefghijk", title: "米津玄師 Kenshi Yonezu - Lemon", artist: "米津玄師", duration: 256)
        precondition(official.artist == "米津玄師" && official.title == "Lemon")
        let escaped = #"window["ytInitialData"]={"text":"quoted \" } text","estimatedResults":"0"};"#
        let empty = try YouTubeCaptionDecoders.search(escaped)
        precondition(empty.isEmpty)
        let watch = #"var ytInitialPlayerResponse = {"playabilityStatus":{"status":"OK"},"videoDetails":{"videoId":"abcdefghijk"},"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[{"languageCode":"zh-Hant","baseUrl":"https://www.youtube.com/api/timedtext?v=abcdefghijk&lang=zh-Hant"},{"languageCode":"zh","kind":"asr","baseUrl":"https://www.youtube.com/api/timedtext?v=abcdefghijk&lang=zh&kind=asr"},{"languageCode":"en","baseUrl":"https://www.youtube.com/api/timedtext?v=abcdefghijk&lang=en"},{"languageCode":"zh","baseUrl":"https://evil.example/api/timedtext"},{"languageCode":"zh","baseUrl":"https://www.youtube.com/api/timedtext?v=abcdefghijk&tlang=zh"}]}}};"#
        let tracks = try YouTubeCaptionDecoders.tracks(watch, videoID: "abcdefghijk")
        precondition(tracks.count == 3 && tracks[0].chinese && !tracks[0].automatic && tracks[1].automatic)
        precondition(tracks.allSatisfy { $0.url.query?.contains("fmt=json3") == true })
        for raw in ["http://www.youtube.com/api/timedtext", "https://youtube.com.evil.example/api/timedtext",
                    "https://www.youtube.com@evil.example/api/timedtext", "https://www.youtube.com/watch"] {
            precondition(!YouTubeCaptionDecoders.allowedCaptionURL(URL(string: raw)))
        }
        let original = try YouTubeCaptionDecoders.cues(Data(#"{"events":[{"tStartMs":1000,"dDurationMs":4000,"segs":[{"utf8":"Blue "},{"utf8":"sky"}]},{"tStartMs":6000,"dDurationMs":4000,"segs":[{"utf8":"Still here"}]}]}"#.utf8))
        precondition(original[0].fullText == "Blue sky" && original[0].endTime == 5)
        let chinese = try YouTubeCaptionDecoders.cues(Data(#"{"events":[{"tStartMs":1000,"dDurationMs":4000,"segs":[{"utf8":"藍色天空"}]},{"tStartMs":6100,"dDurationMs":4000,"segs":[{"utf8":"還在這裡"}]}]}"#.utf8))
        let combined = YouTubeCaptionDecoders.bilingual(chinese: chinese, original: original)
        precondition(combined.map(\.translation) == ["藍色天空", "還在這裡"] && combined[1].startTime == 6)
        precondition(YouTubeCaptionDecoders.bilingual(chinese: chinese, original: nil) == chinese)
        let sameVideo = YouTubeCaptionDecoders.bilingual(chinese: chinese, original: nil, sameVideoBaseline: original)
        precondition(sameVideo[0].fullText == "Blue sky" && sameVideo[0].translation == "藍色天空")
        let offsetChinese = chinese.map { LyricLine(startTime: $0.startTime + 3, endTime: $0.endTime + 3, fullText: $0.fullText) }
        precondition(YouTubeCaptionDecoders.bilingual(chinese: offsetChinese, original: nil, sameVideoBaseline: original) == offsetChinese)
        do { _ = try YouTubeCaptionDecoders.tracks(watch, videoID: "otherID1234"); preconditionFailure("Wrong video response accepted") }
        catch is SubtitleReadError {}
        do { _ = try YouTubeCaptionDecoders.embeddedObject("unusual traffic /sorry/", name: "ytInitialData"); preconditionFailure("Challenge became no results") }
        catch let error as SubtitleReadError { precondition(error.code == "verification-required") }
        print("PASS: subtitle source migration, NetEase / QQ translations, YouTube manual tracks, pairing, refusal and URL checks")
    }
}
