import Foundation

// Cross-platform checks run without an iPhone or a server account.
@main
struct Checks {
    @MainActor static func main() async throws {
        try PlatformChecks.run()
        try YouTubeChecks.run()
        try SubtitleSourceChecks.run()
        if ProcessInfo.processInfo.environment["FOLIA_PROBE_SUBTITLE_SOURCES"] == "1" { await SubtitleSourceProbe.run() }
        let ios = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
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
        let demo = try String(contentsOf: ios.appending(path: "Folia/Resources/tide.lrc"), encoding: .utf8)
        precondition(LyricTimeline(lrc: demo).lines.count == 5)
        print("PASS: LRC, Folia .fia, Navidrome timeline, and bundled demonstration lyrics")

        let project = try readPlist(ios.appending(path: "Folia.xcodeproj/project.pbxproj"))
        let objects = project["objects"] as! [String: [String: Any]]
        let root = objects[project["rootObject"] as! String]!
        let target = objects[(root["targets"] as! [String])[0]]!
        let phases = (target["buildPhases"] as! [String]).map { objects[$0]! }
        let included = phases.flatMap { phase in
            (phase["files"] as! [String]).map { buildID in
                objects[objects[buildID]!["fileRef"] as! String]!["path"] as! String
            }
        }
        let app = ios.appending(path: "Folia", directoryHint: .isDirectory)
        let swiftSources = (FileManager.default.enumerator(atPath: app.path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".swift") }
        precondition(!swiftSources.isEmpty)
        precondition(Set(included.filter { $0.hasSuffix(".swift") }) == Set(swiftSources))
        precondition(included.count == Set(included).count)
        precondition(included.allSatisfy { FileManager.default.fileExists(atPath: app.appending(path: $0).path) })
        precondition(Set(["Resources/tide.lrc", "Resources/tide.m4a", "Resources/Assets.xcassets", "Resources/FoliaStage", "Resources/FoliaYouTube"]).isSubset(of: included))
        let bridge = try String(contentsOf: app.appending(path: "Resources/FoliaYouTube/player.js"), encoding: .utf8)
        precondition(bridge.contains("commandRevision") && bridge.contains("player.pauseVideo()"))
        let info = try readPlist(app.appending(path: "Resources/Info.plist"))
        precondition((info["UIBackgroundModes"] as? [String])?.contains("audio") == true)
        precondition(info["UIApplicationSceneManifest"] != nil)
        print("PASS: Xcode project references, app resources, and background-audio declaration")
    }

    private static func readPlist(_ url: URL) throws -> [String: Any] {
        try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as! [String: Any]
    }
}
