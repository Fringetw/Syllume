import XCTest

@MainActor
final class FoliaUITests: XCTestCase {
    func testBuiltInTraditionalSubtitles() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--subtitle-fixture", "--subtitle-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["demoTrack"].waitForExistence(timeout: 15))
        app.buttons["demoTrack"].tap()
        let transport = app.buttons["playerToggle"]
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        if transport.label == "暫停" { transport.tap() }
        app.segmentedControls.buttons["歌詞"].tap()
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
        app.launchArguments = ["--subtitle-fixture"]
        app.launch()
        app.buttons["demoTrack"].tap()
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        if transport.label == "暫停" { transport.tap() }
        app.segmentedControls.buttons["歌詞"].tap()
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
        let ready = expectation(for: NSPredicate(format: "value == %@", "已就緒"), evaluatedWith: stage)
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
        let lumiereReady = expectation(for: NSPredicate(format: "value == %@", "已就緒"), evaluatedWith: lumiere)
        XCTAssertEqual(XCTWaiter.wait(for: [lumiereReady], timeout: 120), .completed, "Lumiere: \(String(describing: lumiere.value))")
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

    func testYouTubePlaylistSelectionPersists() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--playlist-sync-fixture", "--playlist-sync-reset"]
        app.launch()
        app.segmentedControls.buttons["YouTube"].tap()
        let second = app.buttons["playlistChoice-fixture-second"]
        XCTAssertTrue(second.waitForExistence(timeout: 20))
        second.tap()
        let title = app.staticTexts["selectedYouTubePlaylist"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "夜間播放清單")
        XCTAssertTrue(app.buttons["syncedTrack-fixture-row-second"].waitForExistence(timeout: 15))
        capture(app, name: "YouTube-selected-playlist")
        app.terminate()
        app.launchArguments = ["--playlist-sync-fixture"]
        app.launch()
        app.segmentedControls.buttons["YouTube"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, "夜間播放清單")
        XCTAssertFalse(app.buttons["playlistChoice-$liked"].exists)
        app.buttons["changeYouTubePlaylist"].tap()
        let liked = app.buttons["playlistChoice-$liked"]
        XCTAssertTrue(liked.waitForExistence(timeout: 15)); liked.tap()
        XCTAssertEqual(title.label, "喜歡的影片")
        app.terminate(); app.launch()
        app.segmentedControls.buttons["YouTube"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, "喜歡的影片")
        XCTAssertFalse(app.webViews["youtubeEmbeddedPlayer"].exists)
        capture(app, name: "YouTube-last-playlist-restored")
    }

    func testPlaylistDownloadedAudioPauses() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--playlist-sync-fixture", "--playlist-sync-reset", "--playback-probe"]
        app.launch()
        app.segmentedControls.buttons["YouTube"].tap()
        let liked = app.buttons["playlistChoice-$liked"]
        XCTAssertTrue(liked.waitForExistence(timeout: 20)); liked.tap()
        let summary = app.staticTexts["playlistDownloadSummary"]
        let downloaded = expectation(for: NSPredicate(format: "value == %@", "2|1"), evaluatedWith: summary)
        XCTAssertEqual(XCTWaiter.wait(for: [downloaded], timeout: 45), .completed,
                       "Duplicate playlist entries must share one complete music file")
        XCTAssertTrue(app.buttons["syncedTrack-fixture-unavailable"].waitForExistence(timeout: 10))
        let unavailable = expectation(for: NSPredicate(format: "label CONTAINS %@", "來源未提供"),
                                      evaluatedWith: app.buttons["syncedTrack-fixture-unavailable"])
        XCTAssertEqual(XCTWaiter.wait(for: [unavailable], timeout: 10), .completed)
        capture(app, name: "YouTube-playlist-downloaded-files")
        app.buttons["syncedTrack-fixture-row-duplicate"].tap()
        let toggle = app.buttons["playerToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        app.buttons["循環佇列"].tap()
        if toggle.label == "播放" { toggle.tap() }
        XCTAssertEqual(app.staticTexts["nowPlayingTrackTitle"].value as? String, "播放佇列第 2 首，共 2 首")
        let probe = app.staticTexts["localTransportProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        let advances = expectation(for: NSPredicate { _, _ in self.probeTime(probe) > 0.2 }, evaluatedWith: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [advances], timeout: 45), .completed, "The local fixture must really play")
        toggle.tap()
        let paused = expectation(for: NSPredicate { _, _ in (probe.value as? String ?? "").hasSuffix("|0.0") }, evaluatedWith: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 15), .completed)
        let stoppedTime = probeTime(probe); wait(2)
        XCTAssertEqual(probeTime(probe), stoppedTime, accuracy: 0.15)
        XCTAssertFalse(app.webViews["youtubeEmbeddedPlayer"].exists)
        capture(app, name: "Downloaded-audio-paused-without-video")
        toggle.tap()
        let resumes = expectation(for: NSPredicate { _, _ in self.probeTime(probe) > stoppedTime + 0.25 }, evaluatedWith: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [resumes], timeout: 15), .completed)
        toggle.tap()
        app.buttons["關閉播放畫面"].tap()
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
            app.buttons["closePlatformAccount"].tap()
        app.segmentedControls.buttons["YouTube"].tap()
        let googleConnect = app.buttons["googleConnect"]
        XCTAssertTrue(googleConnect.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Client ID"].exists)
        XCTAssertEqual(googleConnect.isEnabled, !app.staticTexts["googleAvailability"].exists)
        capture(app, name: "YouTube-maintainer-login")
        app.buttons["連線說明"].tap()
        XCTAssertFalse(app.textFields["Client ID"].exists)
        XCTAssertFalse(app.links["開啟 Google Cloud 憑證設定"].exists)
        capture(app, name: "YouTube-account-info")
        app.buttons["closePlatformAccount"].tap()
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
