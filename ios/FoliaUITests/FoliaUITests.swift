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
        app.buttons["繁體字幕設定"].tap()
        let conversion = app.switches["subtitleConversion"]
        XCTAssertTrue(conversion.waitForExistence(timeout: 10))
        conversion.tap()
        capture(app, name: "Built-in-subtitle-settings")
        app.buttons["關閉"].tap()
        assertLyric("头发发现", in: app)

        app.terminate()
        app.launchArguments = ["--subtitle-fixture"]
        app.launch()
        app.buttons["demoTrack"].tap()
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        if transport.label == "暫停" { transport.tap() }
        app.segmentedControls.buttons["歌詞"].tap()
        assertLyric("头发发现", in: app)
        app.buttons["繁體字幕設定"].tap()
        app.switches["subtitleConversion"].tap()
        app.switches["subtitleActive"].tap()
        app.buttons["關閉"].tap()
        assertLyric("头发发现", in: app)
        app.buttons["繁體字幕設定"].tap()
        app.switches["subtitleActive"].tap()
        app.buttons["關閉"].tap()
        assertLyric("頭髮發現", in: app)
        app.buttons["關閉播放畫面"].tap()
        app.buttons["Folia 設定"].tap()
        XCTAssertTrue(app.buttons["builtInTraditionalLyrics"].waitForExistence(timeout: 10))
        app.buttons["builtInTraditionalLyrics"].tap()
        XCTAssertTrue(app.switches["subtitleActive"].waitForExistence(timeout: 5))
        capture(app, name: "Built-in-module-entry")
    }

    func testAnimatedPlayback() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let demo = app.buttons["demoTrack"]
        XCTAssertTrue(demo.waitForExistence(timeout: 15))
        demo.tap()
        let toggle = app.buttons["playerToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let stage = app.descendants(matching: .any)["foliaSonnetStage"].firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 30))
        let ready = expectation(for: NSPredicate(format: "value == %@", "已就緒"), evaluatedWith: stage)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 45), .completed, "Sonnet: \(String(describing: stage.value))")
        // The 30-second sample can finish while a cold simulator obtains UI snapshots.
        app.buttons["循環佇列"].tap()
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
        app.buttons["進入沉浸模式"].tap()
        capture(app, name: "Sonnet-immersive")
        app.buttons["顯示播放控制"].tap()
        app.buttons["關閉播放畫面"].tap()
    }

    func testYouTubeStaysInsideFolia() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        app.segmentedControls.buttons["YouTube"].tap()
        let link = app.textFields["貼上 YouTube／YouTube Music 連結"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap(); link.typeText("https://www.youtube.com/watch?v=M7lc1UVf-VE")
        app.buttons["播放"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["YouTube · Folia"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.webViews["youtubeEmbeddedPlayer"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)
        capture(app, name: "YouTube-inside-Folia")
        app.buttons["關閉 YouTube 播放畫面"].tap()
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
        let googleConnect = app.buttons["googleConnect"]
        XCTAssertTrue(googleConnect.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Client ID"].exists)
        XCTAssertEqual(googleConnect.isEnabled, !app.staticTexts["googleAvailability"].exists)
        capture(app, name: "YouTube-maintainer-login")
        app.buttons["連線說明"].tap()
        XCTAssertFalse(app.textFields["Client ID"].exists)
        XCTAssertFalse(app.links["開啟 Google Cloud 憑證設定"].exists)
        capture(app, name: "YouTube-account-info")
        app.buttons["關閉"].tap()
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
