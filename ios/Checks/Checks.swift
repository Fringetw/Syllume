import AVFoundation
import CoreGraphics
import CoreText
import Foundation

// Cross-platform checks run without an iPhone or a server account.
@main
struct Checks {
    @MainActor static func main() async throws {
        try PlatformChecks.run()
        try YouTubeChecks.run()
        try await YouTubeSyncChecks.run()
        try await StreamingSourceChecks.run()
        try SubtitleSourceChecks.run()
        try await DiagnosticsChecks.run()
        if ProcessInfo.processInfo.environment["FOLIA_PROBE_SUBTITLE_SOURCES"] == "1" {
            print("LIVE NETWORK PROBE: public subtitle endpoints from the CI runner; device and OAuth not covered")
            await SubtitleSourceProbe.run()
        }
        let ios = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fontName = "GenSenRounded2JP-M"
        let fontURL = ios.appending(path: "Syllume/Resources/SyllumeStage/" + fontName + ".otf")
        _ = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        let font = CTFontCreateWithName(fontName as CFString, 28, nil)
        precondition(CTFontCopyPostScriptName(font) as String == fontName)
        let characters = Array("頭髮發現風裡回聲あいうABC".utf16)
        var glyphs = Array(repeating: CGGlyph(0), count: characters.count)
        precondition(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count))
        precondition(glyphs.allSatisfy { $0 != 0 })
        print("PASS: bundled GenSenRounded JP Medium registers with Traditional Chinese, Japanese and Latin glyphs")
        let converter = NativeSubtitleConverter(bundleURL: ios.appending(path: "Syllume/Resources/SyllumeSubtitles/subtitles.js"))
        let line = LyricLine(startTime: 1, endTime: 3, fullText: "头发发现", translation: "风里的回声",
            words: [LyricWord(text: "头发", startTime: 1, endTime: 2), LyricWord(text: "发现", startTime: 2, endTime: 3)],
            extra: ["displayTranslation": .string("风里的回声"), "backgroundVocals": .array([.null])])
        var preferences = SubtitlePreferences()
        let converted = try await converter.convert([line], preferences: preferences)
        precondition(converted[0].fullText == "頭髮發現" && converted[0].translationText == "風裡的回聲")
        precondition(converted[0].words.map(\.text) == ["頭髮", "發現"] && converted[0].words.map(\.startTime) == [1, 2])
        preferences.enabled = false
        let raw = try await converter.convert([line], preferences: preferences)
        precondition(raw[0].fullText == line.fullText && raw[0].translationText == line.translationText)
        let immediate = try await PlaybackLookup.within(.seconds(1)) { 42 }
        precondition(immediate == 42)
        do {
            _ = try await PlaybackLookup.within(.milliseconds(30)) {
                try await Task.sleep(for: .seconds(10))
                return 42
            }
            preconditionFailure("A slow provider kept the playback search open")
        } catch let error as PlatformError { precondition(error.localizedDescription == "音源連線逾時。") }
        print("PASS: OpenCC without WebKit, legacy translation display, timed words, and bounded playback lookup")
        let bundled = ios.appending(path: "Syllume/Resources/tide.m4a")
        let verified = try await AudioIntegrity.inspect(bundled, expected: 30, decode: true)
        precondition(abs(verified - 30) < 0.3)
        let truncated = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: truncated) }
        let bytes = try Data(contentsOf: bundled)
        try bytes.prefix(bytes.count * 3 / 5).write(to: truncated)
        do {
            _ = try await AudioIntegrity.inspect(truncated, expected: 30, decode: true)
            preconditionFailure("Truncated audio was accepted")
        } catch {}
        print("PASS: fully decode bundled audio; reject a truncated copy")
        try await checkDownloadVerification()
        let lrc = LyricTimeline(lrc: """
            [offset:500]
            [00:04.0][00:18.00]Then
            [00:02.500]<00:02.500>Keep <00:03.00>going<00:04.00>
            [00:02.500]繼續走
            [00:02.500]keep going
            [00:08]\u{20}
            """)
        precondition(lrc.lines.map(\.startTime) == [2, 3.5, 17.5])
        precondition(lrc.lines[0].translation == "繼續走")
        precondition(lrc.lines[0].romanization == "keep going")
        precondition(lrc.lines[0].words == [
            LyricWord(text: "Keep ", startTime: 2, endTime: 2.5),
            LyricWord(text: "going", startTime: 2.5, endTime: 3.5)
        ])
        precondition(lrc.activeIndex(at: 1) == nil)
        precondition(lrc.activeIndex(at: 2) == 0)
        precondition(lrc.activeIndex(at: 3.5) == 1)
        precondition(lrc.activeIndex(at: 15) == nil)
        precondition(lrc.activeIndex(at: 19) == 2)
        precondition(lrc.activeIndex(at: 23) == nil)
        precondition(lrc.nextIndex(after: 1) == 0 && lrc.nextIndex(after: 2) == 1)
        precondition(lrc.nextIndex(after: 23) == lrc.lines.endIndex)
        let firstWord = LyricFocus(line: lrc.lines[0], position: 2.25)
        precondition(firstWord.wordIndex == 0 && firstWord.wordProgress == 0.5)
        let secondWord = LyricFocus(line: lrc.lines[0], position: 2.5)
        precondition(secondWord.wordIndex == 1 && secondWord.wordProgress == 0)
        precondition(LyricFocus(line: lrc.lines[0], position: 3.5).wordIndex == nil)
        let seekBack = LyricFocus(line: lrc.lines[0], position: 2.25)
        precondition(seekBack == firstWord && seekBack != secondWord)
        let lineOnly = lrc.lines[1]
        let fadeIn = LyricFocus(line: lineOnly, position: 3.68)
        let steady = LyricFocus(line: lineOnly, position: 4)
        let fadeOut = LyricFocus(line: lineOnly, position: lineOnly.endTime - 0.1)
        precondition([fadeIn, steady, fadeOut].allSatisfy { $0.wordIndex == nil })
        precondition(0 < fadeIn.presence && fadeIn.presence < 1 && steady.presence == 1)
        precondition(0 < fadeOut.presence && fadeOut.presence < 1)
        precondition(LyricFocus(line: lineOnly, position: lineOnly.endTime).presence == 0)
        print("PASS: lyric focus uses timed word boundaries and line-only fades")
        let prefixed = LyricTimeline(lrc: "[00:02]Go <00:03>now")
        precondition(prefixed.lines[0].words.map(\.text) == ["Go ", "now"])

        let duplicate = String(repeating: "[00:01]", count: 1_000)
            + String(repeating: "<00:01>x", count: 1_000)
        precondition(LyricTimeline(lrc: duplicate).lines.count == 1)
        let unique = (0..<700).map { "[\($0 / 60):\($0 % 60)]" }.joined()
            + String(repeating: "<00:01>x", count: 700)
        precondition(LyricTimeline(lrc: unique + "\n[00:03]After").lines.map(\.fullText) == ["After"])

        let fia = try LyricTimeline(folia: Data("""
            {"format":"folia-lyricdata","version":1,"offsetMs":500,"lyrics":{"isWordByWord":true,"lines":[
              {"startTime":2,"endTime":4,"fullText":"花","translation":"flower","romanization":"hana",
                "words":[{"text":"花","startTime":2.2,"endTime":2.8}]}
            ]}}
            """.utf8))
        precondition(fia.lines[0].startTime == 2)
        precondition(fia.lines[0].translation == "flower")
        precondition(fia.lines[0].romanization == "hana")
        precondition(fia.lines[0].words[0].startTime == 2.2)
        let enriched = Data(#"[{"startTime":0,"endTime":4,"fullText":"頭髮","words":[{"text":"頭髮","startTime":0,"endTime":4,"syllables":[{"text":"頭","startTime":0,"endTime":2,"ruby":[{"text":"tou","startTime":0,"endTime":2}]}]}],"wordSegments":["頭","髮"],"backgroundVocals":[{"text":"風","startTime":1,"endTime":2,"words":[]}],"alternateTexts":[{"role":"translation","language":"zh-Hant","text":"髮絲"}]}]"#.utf8)
        let preserved = try JSONDecoder().decode([LyricLine].self, from: enriched)
        let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preserved)) as! NSArray
        let originalObject = try JSONSerialization.jsonObject(with: enriched) as! NSArray
        precondition(roundTrip == originalObject)
        precondition(LyricTimeline(lines: preserved).lines[0].extra == preserved[0].extra)
        precondition(preserved[0].translationText == "髮絲")
        precondition((try? LyricTimeline(folia: Data(#"{"format":"folia-lyricdata","version":2,"lyrics":{"lines":[]}}"#.utf8))) == nil)

        let spacing = LyricTimeline(lines: [
            LyricLine(startTime: 0, endTime: 3, fullText: "Blue moon!", words: [
                LyricWord(text: "Blue", startTime: 0, endTime: 1),
                LyricWord(text: "moon", startTime: 1, endTime: 2)
            ])
        ])
        precondition(spacing.lines[0].words.map(\.text) == ["Blue ", "moon!"])

        let navidrome = try JSONDecoder().decode(NavidromeLyrics.self, from: Data("""
            {"structuredLyrics":[
              {"kind":"main","offset":200,"synced":true,
                "line":[{"start":1000,"value":"Blue moon"},{"start":6000,"value":"Next"}],
                "agents":[{"id":"lead","role":"main"}],
                "cueLine":[
                  {"index":0,"start":1000,"end":4000,"value":"Backing","agentId":"backing"},
                  {"index":0,"start":1000,"end":4500,"value":"Blue moon","agentId":"lead","cue":[
                    {"start":1000,"value":"Blue "},{"start":2000,"value":"moon"}
                  ]}
                ]},
              {"kind":"translation","synced":true,"line":[{"start":800,"value":"藍色月亮"}]},
              {"kind":"pronunciation","synced":true,"line":[{"start":800,"value":"blu mun"}]}
            ]}
            """.utf8)).timeline()
        precondition(navidrome.lines.map(\.fullText) == ["Blue moon", "Next"])
        precondition(navidrome.lines[0].words.map(\.startTime) == [0.8, 1.8])
        precondition(navidrome.lines[0].words.map(\.endTime) == [1.8, 4.3])
        precondition(navidrome.lines[0].translation == "藍色月亮")
        precondition(navidrome.lines[0].romanization == "blu mun")
        if case .array(let vocals)? = navidrome.lines[0].extra["backgroundVocals"],
           case .object(let vocal)? = vocals.first { precondition(vocal["text"] == .string("Backing")) }
        else { preconditionFailure("Navidrome harmony was dropped") }
        precondition(navidrome.activeIndex(at: 5) == nil)
        let demo = try String(contentsOf: ios.appending(path: "Syllume/Resources/tide.lrc"), encoding: .utf8)
        precondition(LyricTimeline(lrc: demo).lines.count == 5)
        print("PASS: LRC, Folia .fia, Navidrome timeline, and bundled demonstration lyrics")

        let project = try readPlist(ios.appending(path: "Syllume.xcodeproj/project.pbxproj"))
        let objects = project["objects"] as! [String: [String: Any]]
        let root = objects[project["rootObject"] as! String]!
        let target = objects[(root["targets"] as! [String])[0]]!
        let phases = (target["buildPhases"] as! [String]).map { objects[$0]! }
        let included: [String] = phases.flatMap { phase in
            (phase["files"] as! [String]).compactMap { buildID in
                guard let ref = objects[buildID]?["fileRef"] as? String else { return nil }
                return objects[ref]!["path"] as! String
            }
        }
        let app = ios.appending(path: "Syllume", directoryHint: .isDirectory)
        let swiftSources = (FileManager.default.enumerator(atPath: app.path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".swift") }
        precondition(!swiftSources.isEmpty)
        precondition(Set(included.filter { $0.hasSuffix(".swift") }) == Set(swiftSources))
        precondition(included.count == Set(included).count)
        precondition(included.allSatisfy { FileManager.default.fileExists(atPath: app.appending(path: $0).path) })
        precondition(Set(["Resources/tide.lrc", "Resources/tide.m4a", "Resources/Assets.xcassets", "Resources/SyllumeStage", "Resources/SyllumeYouTube"]).isSubset(of: included))
        let bridge = try String(contentsOf: app.appending(path: "Resources/SyllumeYouTube/player.js"), encoding: .utf8)
        precondition(bridge.contains("commandRevision") && bridge.contains("player.pauseVideo()"))
        let info = try readPlist(app.appending(path: "Resources/Info.plist"))
        precondition(info["CFBundleDisplayName"] as? String == "Syllume")
        precondition(target["productName"] as? String == "Syllume")
        precondition((info["UIBackgroundModes"] as? [String])?.contains("audio") == true)
        precondition(info["UIApplicationSceneManifest"] != nil)
        print("PASS: Xcode project references, app resources, and background-audio declaration")
    }

    private static func checkDownloadVerification() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "download.wav")
        let replacement = root.appending(path: "replacement.wav")
        try writeTone(to: original, frequency: 330)
        try writeTone(to: replacement, frequency: 660)

        let legacyJSON = Data(#"{"id":"download-legacy","source":"local","title":"Download","duration":2,"integrityChecked":true}"#.utf8)
        let legacy = try JSONDecoder().decode(Track.self, from: legacyJSON)
        precondition(legacy.isDownloaded && legacy.downloadVerification == nil)
        let videoID = "M7lc1UVf-VE"
        let otherVideoID = "dQw4w9WgXcQ"
        var boundDownload = legacy
        boundDownload.recording = SubtitleSong(id: videoID, source: "catalogue", title: "Download", artist: "Artist",
                                              durationMs: 2000, originVideoID: videoID)
        precondition(boundDownload.matchesDownloadOrigin(videoID) && !boundDownload.matchesDownloadOrigin(otherVideoID))
        precondition(boundDownload.matchesDownloadOrigin("file-" + UUID().uuidString))
        precondition(legacy.matchesDownloadOrigin(otherVideoID))
        let first = try await AudioIntegrity.verifyDownload(AVURLAsset(url: original), expected: legacy.duration,
                                                            previous: legacy.downloadVerification)
        precondition(AudioIntegrity.hasDownloadStamp(original, first))
        let persisted = try JSONDecoder().decode(DownloadVerification.self, from: JSONEncoder().encode(first))
        let unchanged = try await AudioIntegrity.verifyDownload(AVURLAsset(url: original), expected: 2, previous: persisted)
        precondition(unchanged == first)
        do {
            _ = try await AudioIntegrity.verifyDownload(AVURLAsset(url: original), expected: 30, previous: first)
            preconditionFailure("The cached verification ignored a new duration mismatch")
        } catch let problem as DiagnosticProblem { precondition(problem.mediaIssue == .durationMismatch) }

        let touched = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: touched], ofItemAtPath: original.path)
        precondition(!AudioIntegrity.hasDownloadStamp(original, first))
        let refreshed = try await AudioIntegrity.verifyDownload(AVURLAsset(url: original), expected: 2, previous: first)
        precondition(refreshed.digest == first.digest && refreshed.file != first.file)
        let replacementDuration = try await AudioIntegrity.inspect(replacement, expected: 2, decode: true)
        precondition(replacementDuration == first.duration)
        let replacementData = try Data(contentsOf: replacement)
        precondition(Int64(replacementData.count) == refreshed.file.size)
        try replacementData.write(to: original, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: touched], ofItemAtPath: original.path)
        do {
            _ = try await AudioIntegrity.verifyDownload(AVURLAsset(url: original), expected: 2, previous: refreshed)
            preconditionFailure("A playable replacement with the same size, duration and mtime was accepted")
        } catch let problem as DiagnosticProblem { precondition(problem.mediaIssue == .changedDownload) }
        print("PASS: reopen a verified download, migrate a legacy record, and reject audio replacement or a mismatched recording")
    }

    private static func writeTone(to url: URL, frequency: Double) throws {
        let sampleRate = 8_000.0
        let frames = AVAudioFrameCount(sampleRate * 2)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?.pointee else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            samples[index] = 0.25 * Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func readPlist(_ url: URL) throws -> [String: Any] {
        try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as! [String: Any]
    }
}
