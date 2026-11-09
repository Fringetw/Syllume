import XCTest

@MainActor
final class FoliaUITests: XCTestCase {
    func testBuiltInTraditionalSubtitles() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Exercise subtitle rendering in the lyric list; the graphics runtime has its own test.
        app.launchArguments = ["--subtitle-fixture", "--subtitle-reset", "-Folia.LyricDisplayMode", "lyrics"]
        app.launch()
        XCTAssertTrue(app.buttons["demoTrack"].waitForExistence(timeout: 15))
        app.buttons["demoTrack"].tap()
        let transport = app.buttons["playerToggle"]
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        if transport.label == "暫停" { transport.tap() }
        assertLyric("頭髮發現", in: app)
        capture(app, name: "Built-in-subtitles-converted")
        openSubtitlePreferences(in: app)
        let conversion = app.switches["subtitleConversion"]
        XCTAssertTrue(conversion.waitForExistence(timeout: 10))
        setSwitch("subtitleConversion", to: false, in: app)
        capture(app, name: "Built-in-subtitle-settings")
        app.buttons["closeSubtitleSettings"].tap()
        app.buttons["closeLyricSearch"].tap()
        assertLyric("头发发现", in: app)

        app.terminate()
        app.launchArguments = ["--subtitle-fixture", "-Folia.LyricDisplayMode", "lyrics"]
        app.launch()
        app.buttons["demoTrack"].tap()
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        if transport.label == "暫停" { transport.tap() }
        assertLyric("头发发现", in: app)
        openSubtitlePreferences(in: app)
        setSwitch("subtitleConversion", to: true, in: app)
        setSwitch("subtitleActive", to: false, in: app)
        app.buttons["closeSubtitleSettings"].tap()
        app.buttons["closeLyricSearch"].tap()
        assertLyric("头发发现", in: app)
        openSubtitlePreferences(in: app)
        setSwitch("subtitleActive", to: true, in: app)
        app.buttons["closeSubtitleSettings"].tap()
        app.buttons["closeLyricSearch"].tap()
        assertLyric("頭髮發現", in: app)
        app.buttons["關閉播放畫面"].tap()
        app.buttons["Folia 設定"].tap()
        XCTAssertTrue(app.buttons["builtInTraditionalLyrics"].waitForExistence(timeout: 10))
        app.buttons["builtInTraditionalLyrics"].tap()
        XCTAssertTrue(app.switches["subtitleActive"].waitForExistence(timeout: 5))
        capture(app, name: "Built-in-module-entry")
        let report = app.staticTexts["subtitleReport"]
        for _ in 0..<10 { if report.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(report.isHittable)
        XCTAssertTrue(report.label.contains("顯示"))
        XCTAssertFalse(report.label.contains("完整結構化紀錄"))
    }

    func testOfflineTraditionalSubtitlesWhileSearchUnavailable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--subtitle-offline-only", "--subtitle-fixture", "--subtitle-reset",
                               "-Folia.LyricDisplayMode", "lyrics"]
        app.launch()
        XCTAssertTrue(app.buttons["demoTrack"].waitForExistence(timeout: 15))
        app.buttons["demoTrack"].tap()
        let transport = app.buttons["playerToggle"]
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        if transport.label == "暫停" { transport.tap() }
        assertLyric("頭髮發現", in: app)
        assertLyric("風裡的回聲", in: app)
        XCTAssertEqual(app.buttons["lyricLine-0"].value as? String, "GenSenRounded2JP-M")
    }

    func testSubtitleSourceSettingsPersist() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--subtitle-reset", "--subtitle-fixture"]
        app.launch()
        app.buttons["Folia 設定"].tap()
        app.buttons["builtInTraditionalLyrics"].tap()
        let qq = app.switches["subtitleQQSource"]
        for _ in 0..<5 { if qq.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(qq.isHittable)
        XCTAssertEqual(app.switches["subtitleNeteaseSource"].value as? String, "1")
        XCTAssertEqual(app.switches["subtitleYouTubeSource"].value as? String, "1")
        setSwitch("subtitleQQSource", to: false, in: app)
        capture(app, name: "Cross-platform-subtitle-sources")
        app.terminate()
        app.launchArguments = ["--subtitle-fixture"]
        app.launch()
        app.buttons["Folia 設定"].tap()
        app.buttons["builtInTraditionalLyrics"].tap()
        for _ in 0..<5 { if qq.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(qq.value as? String, "0")
        setSwitch("subtitleQQSource", to: true, in: app)
    }

    func testAnimatedPlayback() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--presentation-reset", "--playback-probe"]
        app.launch()
        let demo = app.buttons["demoTrack"]
        XCTAssertTrue(demo.waitForExistence(timeout: 15))
        demo.tap()
        let toggle = app.buttons["playerToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        // Keep the short sample alive while a cold simulator initializes the graphics context.
        app.buttons["循環佇列"].tap()
        if toggle.label == "播放" { toggle.tap() }
        let stage = app.descendants(matching: .any)["foliaSonnetStage"].firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 30))
        let ready = expectation(for: NSPredicate(format: "value == %@", "已就緒 · GenSenRounded2JP-M"), evaluatedWith: stage)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 90), .completed, "Sonnet: \(String(describing: stage.value))")
        if toggle.label == "播放" { toggle.tap() }
        XCTAssertEqual(toggle.label, "暫停")
        wait(2)
        capture(app, name: "Lyrics-playing-02")
        wait(3)
        capture(app, name: "Lyrics-playing-05")
        toggle.tap()
        let paused = expectation(for: NSPredicate(format: "label == %@", "播放"), evaluatedWith: toggle)
        wait(for: [paused], timeout: 10)
        capture(app, name: "Lyrics-paused")
        let mediaProbe = app.staticTexts["localTransportProbe"]
        XCTAssertTrue(mediaProbe.waitForExistence(timeout: 5))
        XCTAssertTrue((mediaProbe.value as? String ?? "").hasSuffix("|0.0"))
        let pausedTime = probeTime(mediaProbe)
        wait(2)
        XCTAssertEqual(probeTime(mediaProbe), pausedTime, accuracy: 0.15, "AVPlayer time must stop, not only the icon")
        app.segmentedControls.buttons["繪光"].tap()
        let lumiere = app.descendants(matching: .any)["foliaLumiereStage"].firstMatch
        XCTAssertTrue(lumiere.waitForExistence(timeout: 20))
        let lumiereReady = expectation(for: NSPredicate(format: "value == %@", "已就緒 · GenSenRounded2JP-M"), evaluatedWith: lumiere)
        XCTAssertEqual(XCTWaiter.wait(for: [lumiereReady], timeout: 120), .completed, "Lumiere: \(String(describing: lumiere.value))")
        XCTAssertGreaterThan(lumiere.frame.height, app.frame.height * 0.8)
        capture(app, name: "Lumiere-paused")
        toggle.tap(); wait(2); capture(app, name: "Lumiere-playing"); toggle.tap()
        app.buttons["尋找歌詞"].tap()
        XCTAssertTrue(app.buttons["findChineseLyrics"].waitForExistence(timeout: 10))
        capture(app, name: "Unified-lyric-search")
        app.buttons["closeLyricSearch"].tap()
        app.buttons["進入沉浸模式"].tap()
        capture(app, name: "Lumiere-immersive")
        app.buttons["顯示播放控制"].tap()
        app.buttons["關閉播放畫面"].tap()
    }

    func testYouTubePlaylistChoicePersists() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--youtube-sync-fixture", "--youtube-sync-reset", "--playback-probe"]
        app.launch()
        app.segmentedControls.buttons["YouTube"].tap()
        let liked = app.buttons["youtubePlaylist-liked"]
        XCTAssertTrue(liked.waitForExistence(timeout: 10))
        liked.tap()
        XCTAssertTrue(app.staticTexts["selectedYouTubePlaylist"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["selectedYouTubePlaylist"].label, "喜歡的影片")
        app.buttons["changeYouTubePlaylist"].tap()
        let playlist = app.buttons["youtubePlaylist-fixture-list"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 10)); playlist.tap()
        let selected = app.staticTexts["selectedYouTubePlaylist"]
        let changed = expectation(for: NSPredicate(format: "label == %@", "測試歌單"), evaluatedWith: selected)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed)
        app.terminate()
        app.launchArguments = ["--youtube-sync-fixture", "--playback-probe"]
        app.launch(); app.segmentedControls.buttons["YouTube"].tap()
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        XCTAssertEqual(selected.label, "測試歌單")
        XCTAssertFalse(app.buttons["youtubePlaylist-liked"].exists)
        XCTAssertFalse(app.webViews["youtubeEmbeddedPlayer"].exists)
        capture(app, name: "YouTube-selected-playlist-restored")
    }

    func testYouTubeSyncedAudioPausesWithoutVideo() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--youtube-sync-fixture", "--youtube-sync-reset", "--youtube-slow-source-fixture",
                               "--subtitle-fixture", "--playback-probe", "-Folia.LyricDisplayMode", "cover"]
        app.launch(); app.segmentedControls.buttons["YouTube"].tap()
        let liked = app.buttons["youtubePlaylist-liked"]
        XCTAssertTrue(liked.waitForExistence(timeout: 10)); liked.tap()
        let audio = app.buttons["youtubeSong-fixture-row"]
        XCTAssertTrue(audio.waitForExistence(timeout: 15))
        XCTAssertEqual(audio.value as? String, "點歌時搜尋音源")
        XCTAssertTrue(app.staticTexts["正在載入其餘歌曲…"].exists)
        audio.tap()
        let toggle = app.buttons["playerToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        app.buttons["循環佇列"].tap()
        if toggle.label == "播放" { toggle.tap() }
        XCTAssertFalse(app.webViews["youtubeEmbeddedPlayer"].exists)
        let probe = app.staticTexts["localTransportProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let advancing = expectation(for: NSPredicate { _, _ in self.probeTime(probe) > 0.3 }, evaluatedWith: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 15), .completed)
        toggle.tap(); wait(1)
        let stopped = probeTime(probe); wait(2)
        XCTAssertEqual(probeTime(probe), stopped, accuracy: 0.15)
        XCTAssertTrue((probe.value as? String ?? "").hasSuffix("|0.0"))
        toggle.tap()
        let resumed = expectation(for: NSPredicate { _, _ in
            let sample = (probe.value as? String ?? "").split(separator: "|")
            guard sample.count == 2, let time = Double(sample[0]), let rate = Double(sample[1]), rate > 0 else { return false }
            // Slow simulators can reach the end of the 30-second fixture during the resume query.
            return time > stopped + 0.25 || (stopped > 15 && time > 0.25 && time < stopped - 0.25)
        }, evaluatedWith: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 20), .completed,
                       "Expected the media clock to advance from \(stopped); observed \(String(describing: probe.value))")
        toggle.tap(); capture(app, name: "YouTube-audio-without-video")
        let closePlayer = app.buttons["關閉播放畫面"]
        let loadingPages = app.staticTexts["正在載入其餘歌曲…"]
        closePlayer.tap()
        XCTAssertTrue(loadingPages.waitForExistence(timeout: 10))
        app.buttons["openMiniPlayer"].tap()
        let playlistSync = app.staticTexts["youtubePlaylistSyncProbe"]
        XCTAssertTrue(playlistSync.waitForExistence(timeout: 10))
        XCTAssertEqual(playlistSync.value as? String, "已暫停")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(playlistSync.waitForExistence(timeout: 10))
        XCTAssertEqual(playlistSync.value as? String, "已暫停")
        closePlayer.tap()
        XCTAssertTrue(loadingPages.waitForExistence(timeout: 10))
        audio.press(forDuration: 1)
        let download = app.buttons["下載音樂"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        download.tap()
        let confirm = app.sheets.buttons["下載音樂"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertEqual(audio.value as? String, "點歌時搜尋音源")
        confirm.tap()
        let saved = expectation(for: NSPredicate(format: "value CONTAINS %@", "示範音軌"), evaluatedWith: audio)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 20), .completed)
    }

    func testDeveloperDiagnosticsProducesEvidenceAndReport() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--diagnostics-ui-fixture", "--presentation-reset"]
        app.launch()
        app.buttons["Folia 設定"].tap()
        let entry = app.buttons["developerDiagnostics"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        let run = app.buttons["diagnosticsRunAll"]
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        run.tap()
        let reportProbe = app.staticTexts["diagnosticsFixtureJSON"]
        XCTAssertTrue(reportProbe.waitForExistence(timeout: 110))
        let text = try XCTUnwrap(reportProbe.value as? String)
        let data = Data(text.utf8)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(report["environment"] as? String, "ciFixture")
        XCTAssertEqual(report["schemaVersion"] as? Int, 1)
        let areas = try XCTUnwrap(report["results"] as? [[String: Any]])
        XCTAssertEqual(Set(areas.compactMap { $0["area"] as? String }), ["google", "captions", "audio", "animation", "device"])
        let checks = areas.flatMap { $0["checks"] as? [[String: Any]] ?? [] }
        for id in ["google.fixture", "captions.opencc", "captions.offset", "audio.bundled", "audio.retry",
                   "animation.sonnet.init", "animation.sonnet.font", "animation.sonnet.clock",
                   "animation.lumiere.init", "animation.lumiere.font", "animation.lumiere.clock"] {
            let check = checks.first { $0["id"] as? String == id }
            XCTAssertEqual(check?["state"] as? String, "passed", "\(id): \(String(describing: check))")
        }
        XCTAssertFalse(checks.contains { $0["evidence"] as? String == "liveNetwork" && $0["state"] as? String == "passed" })
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Folia-Diagnostics-Simulator-Fixture"
        attachment.lifetime = .keepAlways
        add(attachment)
        capture(app, name: "Diagnostics-complete")
    }

    func testPlatformSetup() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.segmentedControls.buttons["Spotify"].tap()
            XCTAssertTrue(app.buttons["設定並登入"].waitForExistence(timeout: 5))
            app.buttons["設定並登入"].tap()
            XCTAssertTrue(app.textFields["Client ID"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["登入並讀取曲庫"].isEnabled)
            capture(app, name: "Spotify-setup")
            app.buttons["關閉"].tap()
        app.segmentedControls.buttons["YouTube"].tap()
        XCTAssertTrue(app.buttons["youtubeSyncAccount"].waitForExistence(timeout: 5))
        app.buttons["youtubeSyncAccount"].tap()
        XCTAssertFalse(app.textFields["Client ID"].exists)
        XCTAssertFalse(app.links["開啟 Google Cloud 憑證設定"].exists)
        capture(app, name: "YouTube-account-info")
        app.buttons["關閉"].tap()
    }

    private func openSubtitlePreferences(in app: XCUIApplication) {
        app.buttons["尋找歌詞"].tap()
        XCTAssertTrue(app.buttons["findChineseLyrics"].waitForExistence(timeout: 10))
        app.buttons["繁體字幕設定"].tap()
        let state = app.descendants(matching: .any)["subtitleEngineState"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        let ready = expectation(for: NSPredicate(format: "value == %@", "已就緒"), evaluatedWith: state)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed, "Subtitle engine must be running before testing settings")
    }

    private func probeTime(_ element: XCUIElement) -> Double {
        Double((element.value as? String ?? "").split(separator: "|").first ?? "") ?? -1
    }

    private func setSwitch(_ identifier: String, to enabled: Bool, in app: XCUIApplication) {
        let control = app.switches[identifier]
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        let target = enabled ? "1" : "0"
        if control.value as? String != target {
            // SwiftUI exposes the complete Form row as a switch; its thumb is on the trailing edge.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let changed = expectation(for: NSPredicate(format: "value == %@", target), evaluatedWith: control)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

    private func assertLyric(_ text: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons["lyricLine-0"]
        let matches = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: row)
        let result = XCTWaiter.wait(for: [matches], timeout: 15)
        if result != .completed {
            print("Subtitle display failure: \(app.debugDescription)")
            capture(app, name: "Subtitle-display-failure")
        }
        XCTAssertEqual(result, .completed, file: file, line: line)
    }

    private func wait(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "Playback advances")], timeout: seconds)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
