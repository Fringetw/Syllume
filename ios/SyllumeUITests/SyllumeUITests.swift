import XCTest
import Network

@MainActor
final class SyllumeUITests: XCTestCase {
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
        app.buttons["Syllume 設定"].tap()
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
        app.buttons["Syllume 設定"].tap()
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
        app.buttons["Syllume 設定"].tap()
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
        let stage = app.descendants(matching: .any)["syllumeSonnetStage"].firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 30))
        let ready = expectation(for: NSPredicate(format: "value == %@", "已就緒 · GenSenRounded2JP-M"), evaluatedWith: stage)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 90), .completed, "Sonnet: \(String(describing: stage.value))")
        if toggle.label == "播放" { toggle.tap() }
        let mediaProbe = app.staticTexts["localTransportProbe"]
        let playing = expectation(for: NSPredicate { _, _ in
            let fields = (mediaProbe.value as? String ?? "").split(separator: "|")
            guard fields.count == 2, let time = Double(fields[0]), let rate = Double(fields[1]) else { return false }
            return time.isFinite && time > 0.2 && rate > 0
        }, evaluatedWith: mediaProbe)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 20), .completed,
                       "Expected the native sample to advance; got \(String(describing: mediaProbe.value))")
        XCTAssertEqual(toggle.label, "暫停")
        wait(2)
        capture(app, name: "Lyrics-playing-02")
        wait(3)
        capture(app, name: "Lyrics-playing-05")
        toggle.tap()
        let pausedTime = waitForPausedNativeClock(mediaProbe)
        XCTAssertEqual(toggle.label, "播放")
        capture(app, name: "Lyrics-paused")
        wait(2)
        XCTAssertEqual(probeTime(mediaProbe), pausedTime, accuracy: 0.15, "AVPlayer time must stop, not only the icon")
        app.segmentedControls.buttons["繪光"].tap()
        let lumiere = app.descendants(matching: .any)["syllumeLumiereStage"].firstMatch
        XCTAssertTrue(lumiere.waitForExistence(timeout: 20))
        let lumiereReady = expectation(for: NSPredicate(format: "value == %@", "已就緒 · GenSenRounded2JP-M"), evaluatedWith: lumiere)
        XCTAssertEqual(XCTWaiter.wait(for: [lumiereReady], timeout: 120), .completed, "Lumiere: \(String(describing: lumiere.value))")
        XCTAssertGreaterThan(lumiere.frame.height, app.frame.height * 0.8)
        capture(app, name: "Lumiere-paused")
        toggle.tap()
        let resumed = expectation(for: NSPredicate(format: "label == %@", "暫停"), evaluatedWith: toggle)
        wait(for: [resumed], timeout: 10)
        wait(2)
        capture(app, name: "Lumiere-playing")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let lumierePausedTime = waitForPausedNativeClock(mediaProbe)
        XCTAssertEqual(toggle.label, "播放")
        wait(2)
        XCTAssertEqual(probeTime(mediaProbe), lumierePausedTime, accuracy: 0.15)
        app.buttons["尋找歌詞"].tap()
        XCTAssertTrue(app.buttons["findChineseLyrics"].waitForExistence(timeout: 10))
        capture(app, name: "Unified-lyric-search")
        app.buttons["closeLyricSearch"].tap()
        app.buttons["進入沉浸模式"].tap()
        capture(app, name: "Lumiere-immersive")
        app.buttons["顯示播放控制"].tap()
        app.buttons["關閉播放畫面"].tap()
    }

    func testNativeLocalStartupRecoversOnce() {
        continueAfterFailure = false
        let app = openDemoWithPlaybackFixture("--native-local-start-fixture")
        let trace = app.staticTexts["nativeTransportDebugProbe"]
        let recovery = expectation(for: NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@",
            "local-start-held", "local-start-retry"), evaluatedWith: trace)
        XCTAssertEqual(XCTWaiter.wait(for: [recovery], timeout: 40), .completed,
                       "The stalled file should be reopened once. \(String(describing: trace.value))")
        waitForDemoAudio(app)
        XCTAssertEqual((trace.value as? String ?? "").components(separatedBy: "local-start-retry").count - 1, 1)
        capture(app, name: "Syllume-local-start-recovered")
    }

    func testNativeFrozenClockStopsPlayingAndCanRetry() {
        continueAfterFailure = false
        let app = openDemoWithPlaybackFixture("--native-frozen-clock-fixture")
        app.buttons["循環佇列"].tap()
        waitForDemoAudio(app)

        let clock = app.staticTexts["localTransportProbe"]
        let toggle = app.buttons["playerToggle"]
        let trace = app.staticTexts["nativeTransportDebugProbe"]
        func mediaSample() -> (time: Double, rate: Double)? {
            let fields = (clock.value as? String ?? "").split(separator: "|")
            guard fields.count == 2, let time = Double(fields[0]), time.isFinite,
                  let rate = Double(fields[1]) else { return nil }
            return (time, rate)
        }
        func firstTraceSample(_ event: String, after previousUptime: Double = 0) -> (uptime: Double, time: Double)? {
            for line in (trace.value as? String ?? "").split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: " ")
                guard fields.count > 1, fields[1] == event,
                      let uptime = Double(fields[0]), uptime > previousUptime else { continue }
                if let time = fields.first(where: { $0.hasPrefix("time=") }),
                   let seconds = Double(time.dropFirst("time=".count)), seconds.isFinite { return (uptime, seconds) }
            }
            return nil
        }

        toggle.tap()
        waitForPausedNativeClock(clock)
        let progress = app.descendants(matching: .any)["playbackProgress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.33, dy: 0.5)).tap()
        let positioned = expectation(for: NSPredicate { _, _ in
            guard let sample = mediaSample() else { return false }
            return sample.rate == 0 && (8...12).contains(sample.time)
        }, evaluatedWith: clock)
        XCTAssertEqual(XCTWaiter.wait(for: [positioned], timeout: 15), .completed,
                       "AVPlayer must confirm an interior seek in the 30-second fixture.")
        let interiorTime = probeTime(clock)
        toggle.tap()
        let advancingFromInterior = expectation(for: NSPredicate { _, _ in
            guard let sample = mediaSample() else { return false }
            return sample.rate > 0 && sample.time > interiorTime + 0.2
        }, evaluatedWith: clock)
        XCTAssertEqual(XCTWaiter.wait(for: [advancingFromInterior], timeout: 15), .completed)

        let hold = app.buttons["holdNativeClock"]
        XCTAssertTrue(hold.waitForExistence(timeout: 10))
        hold.tap()
        let stalled = expectation(for: NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@",
            "clock-held", "clock-stale"), evaluatedWith: trace)
        XCTAssertEqual(XCTWaiter.wait(for: [stalled], timeout: 20), .completed,
                       "A playing transport with a frozen clock must enter buffering. \(String(describing: trace.value))")

        let error = app.staticTexts["等待音訊逾時。請點播放重試。"]
        XCTAssertTrue(error.waitForExistence(timeout: 30), String(describing: trace.value))
        XCTAssertTrue((trace.value as? String)?.contains("buffer-timeout") == true)
        XCTAssertFalse((trace.value as? String)?.contains("local-start-retry") == true,
                       "An item that already played must not use the initial-start retry.")
        let frozenTime = waitForPausedNativeClock(clock)
        XCTAssertTrue((8...26).contains(frozenTime), "The held AVPlayer clock must remain inside the demo track.")
        capture(app, name: "Syllume-frozen-native-clock-timeout")

        XCTAssertEqual(toggle.label, "播放")
        XCTAssertEqual(mediaSample()?.rate, 0)
        XCTAssertEqual(probeTime(clock), frozenTime, accuracy: 0.15)
        XCTAssertNil(firstTraceSample("recovery-positioned"), "The player must wait for explicit retry.")
        toggle.tap()

        let restored = expectation(for: NSPredicate { _, _ in firstTraceSample("recovery-positioned") != nil },
                                   evaluatedWith: trace)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 30), .completed,
                       "Retry must confirm its first AVPlayer position. \(String(describing: trace.value))")
        guard let recovery = firstTraceSample("recovery-positioned") else {
            XCTFail("The confirmed recovery sample was no longer available.")
            return
        }
        XCTAssertEqual(recovery.time, frozenTime, accuracy: 0.35,
                       "Retry must start near the last confirmed sample instead of replaying from zero.")
        let advanced = expectation(for: NSPredicate { _, _ in
            guard let sample = mediaSample() else { return false }
            return sample.rate > 0 && sample.time > recovery.time + 0.2
        }, evaluatedWith: clock)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 20), .completed,
                       "The actual media clock must advance after recovery.")
        XCTAssertFalse(error.exists)
        capture(app, name: "Syllume-frozen-native-clock-retry")

        hold.tap()
        let secondTimeout = expectation(for: NSPredicate { _, _ in
            firstTraceSample("buffer-timeout", after: recovery.uptime) != nil
        }, evaluatedWith: trace)
        XCTAssertEqual(XCTWaiter.wait(for: [secondTimeout], timeout: 35), .completed,
                       "The recovered item must reach another timeout. \(String(describing: trace.value))")
        XCTAssertTrue(error.waitForExistence(timeout: 12))
        let secondFrozenTime = waitForPausedNativeClock(clock)

        // Pick a new interior time at least several seconds away from the second stall.
        let fraction = secondFrozenTime < 12 ? 0.65 : 0.12
        let target = fraction * 30
        progress.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)).tap()
        var newPosition: Double?
        let manuallyPositioned = expectation(for: NSPredicate { _, _ in
            guard let sample = mediaSample(), sample.rate == 0, abs(sample.time - target) < 1.5 else { return false }
            newPosition = sample.time
            return true
        }, evaluatedWith: clock)
        XCTAssertEqual(XCTWaiter.wait(for: [manuallyPositioned], timeout: 20), .completed,
                       "The manual seek must reach the alternate position while AVPlayer is paused.")
        guard let newPosition else { return }
        XCTAssertGreaterThan(abs(newPosition - secondFrozenTime), 5)
        XCTAssertTrue(error.waitForNonExistence(timeout: 15), "A successful manual seek must clear the old timeout.")
        XCTAssertEqual(mediaSample()?.rate, 0)
        XCTAssertEqual(probeTime(clock), newPosition, accuracy: 0.15)

        toggle.tap()
        var firstMotion: Double?
        let resumedFromManualSeek = expectation(for: NSPredicate { _, _ in
            guard let sample = mediaSample(), sample.rate > 0, abs(sample.time - newPosition) > 0.2 else { return false }
            firstMotion = sample.time
            return true
        }, evaluatedWith: clock)
        XCTAssertEqual(XCTWaiter.wait(for: [resumedFromManualSeek], timeout: 20), .completed,
                       "AVPlayer must move after pressing Play from the manually selected position.")
        guard let firstMotion else { return }
        XCTAssertTrue((newPosition...(newPosition + 5)).contains(firstMotion),
                      "The first moving sample was \(firstMotion), expected close to the new position \(newPosition).")
        XCTAssertNil(firstTraceSample("recovery-positioned", after: recovery.uptime),
                     "Play must not restore the obsolete pre-seek bookmark.")
        capture(app, name: "Syllume-native-retry-manual-seek")
    }

    func testLiveNavidromeResumesAtConfirmedTimeAfterTimeout() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["SYLLUME_NAVIDROME_URL"],
              let url = URLComponents(string: server), url.scheme == "https", url.host == "localhost",
              url.port != nil, url.user == nil, url.password == nil,
              let user = environment["SYLLUME_NAVIDROME_USER"], !user.isEmpty,
              let password = environment["SYLLUME_NAVIDROME_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Requires the isolated Navidrome HTTPS workflow and its simulator certificate.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--native-frozen-clock-fixture", "--playback-probe", "-Folia.LyricDisplayMode", "cover"]
        app.launch()
        app.segmentedControls.buttons["Navidrome"].tap()
        app.buttons["設定伺服器"].tap()

        let address = app.textFields["https://music.example.com"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        address.tap()
        address.typeText(server)
        let username = app.textFields["帳號"]
        username.tap()
        username.typeText(user)
        let secret = app.secureTextFields["密碼"]
        secret.tap()
        secret.typeText(password)
        app.buttons["測試並儲存"].tap()

        let query = app.textFields["搜尋歌曲、歌手或專輯"]
        XCTAssertTrue(query.waitForExistence(timeout: 25), "The app must connect through its normal HTTPS client.")
        query.tap()
        query.typeText("Syllume")
        app.buttons["搜尋"].tap()
        let song = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
            "潮汐之間", "Syllume Fixture")).firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 25), "Navidrome must return the test recording.")
        song.tap()

        let clock = app.staticTexts["localTransportProbe"]
        let trace = app.staticTexts["nativeTransportDebugProbe"]
        let toggle = app.buttons["playerToggle"]
        let hold = app.buttons["holdNativeClock"]
        let progress = app.descendants(matching: .any)["playbackProgress"].firstMatch
        XCTAssertTrue(hold.waitForExistence(timeout: 20))
        waitForDemoAudio(app)
        toggle.tap()
        _ = waitForPausedNativeClock(clock)
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.33, dy: 0.5)).tap()
        let positioned = expectation(for: NSPredicate { [self] _, _ in
            (8...12).contains(probeTime(clock)) && (clock.value as? String)?.hasSuffix("|0.0") == true
        }, evaluatedWith: clock)
        XCTAssertEqual(XCTWaiter.wait(for: [positioned], timeout: 25), .completed)
        let interiorTime = probeTime(clock)
        toggle.tap()
        waitForDemoAudio(app, from: interiorTime)
        hold.tap()

        let timeout = app.staticTexts["等待音訊逾時。請點播放重試。"]
        XCTAssertTrue(timeout.waitForExistence(timeout: 48), String(describing: trace.value))
        let frozenTime = waitForPausedNativeClock(clock)
        XCTAssertTrue((8...26).contains(frozenTime))
        XCTAssertEqual(toggle.label, "播放")
        XCTAssertFalse((trace.value as? String ?? "").contains("recovery-positioned"))
        capture(app, name: "Syllume-Navidrome-confirmed-timeout")

        toggle.tap()
        let restored = expectation(for: NSPredicate(format: "value CONTAINS %@", "recovery-positioned"), evaluatedWith: trace)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 48), .completed, String(describing: trace.value))
        let entries = (trace.value as? String ?? "").split(whereSeparator: \.isNewline)
        let heldItem = entries.first { $0.contains(" clock-held ") }?.split(separator: " ").first { $0.hasPrefix("item=") }
        let recovery = entries.first { $0.contains(" recovery-positioned ") }?.split(separator: " ") ?? []
        let newItem = recovery.first { $0.hasPrefix("item=") }
        XCTAssertNotNil(heldItem)
        XCTAssertNotNil(newItem)
        XCTAssertNotEqual(heldItem, newItem, "The retry must use a new AVPlayerItem.")
        guard let field = recovery.first(where: { $0.hasPrefix("time=") }),
              let restoredTime = Double(field.dropFirst("time=".count)) else {
            XCTFail("AVPlayer did not confirm a retry position.")
            return
        }
        XCTAssertEqual(restoredTime, frozenTime, accuracy: 0.35)
        let moving = expectation(for: NSPredicate { [self] _, _ in
            probeTime(clock) > restoredTime + 0.2 && (clock.value as? String)?.hasSuffix("|1.0") == true
        }, evaluatedWith: clock)
        XCTAssertEqual(XCTWaiter.wait(for: [moving], timeout: 25), .completed)
        print("Navidrome resume evidence: frozen=\(frozenTime), restored=\(restoredTime), advanced=\(probeTime(clock))")
        XCTAssertFalse(timeout.exists)
        capture(app, name: "Syllume-Navidrome-confirmed-retry")
    }

    func testSonnetRetriesRejectedInitialization() {
        continueAfterFailure = false
        let app = openDemoWithPlaybackFixture("--stage-initialization-fails-once")
        waitForDemoAudio(app)
        app.segmentedControls.buttons["商籟"].tap()
        let stage = app.descendants(matching: .any)["syllumeSonnetStage"].firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 15))
        let ready = expectation(for: NSPredicate(format: "value BEGINSWITH %@ AND value ENDSWITH %@",
            "已就緒", " · 已重試"), evaluatedWith: stage)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 65), .completed,
                       "The stage should load after the first song command is rejected. \(String(describing: stage.value))")
        capture(app, name: "Syllume-Sonnet-recovered")
    }

    func testSonnetTimeoutEndsWithoutStoppingAudio() {
        continueAfterFailure = false
        let app = openDemoWithPlaybackFixture("--stage-initialization-stall")
        app.buttons["循環佇列"].tap()
        waitForDemoAudio(app)
        app.segmentedControls.buttons["商籟"].tap()
        let stage = app.descendants(matching: .any)["syllumeSonnetStage"].firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 15))
        let failed = expectation(for: NSPredicate(format: "value BEGINSWITH %@", "載入失敗："), evaluatedWith: stage)
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 48), .completed,
                       "A renderer that never becomes ready should leave the loading state.")
        XCTAssertFalse(app.staticTexts["正在準備歌詞動畫"].exists)
        XCTAssertTrue(app.staticTexts["animatedLyricsFallback"].waitForExistence(timeout: 15))
        waitForDemoAudio(app, from: probeTime(app.staticTexts["localTransportProbe"]))
        capture(app, name: "Syllume-Sonnet-timeout")
    }

    private func openDemoWithPlaybackFixture(_ fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--presentation-reset", "--playback-probe", fixture]
        app.launchEnvironment["SYLLUME_TEST_INITIAL_DISPLAY_MODE"] = "cover"
        app.launch()
        let demo = app.buttons["demoTrack"]
        XCTAssertTrue(demo.waitForExistence(timeout: 15))
        demo.tap()
        XCTAssertTrue(app.buttons["playerToggle"].waitForExistence(timeout: 15))
        return app
    }

    private func waitForDemoAudio(_ app: XCUIApplication, from previousTime: Double = 0,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let clock = app.staticTexts["localTransportProbe"]
        let playing = expectation(for: NSPredicate { _, _ in
            let sample = (clock.value as? String ?? "").split(separator: "|")
            guard sample.count == 2, let time = Double(sample[0]), let rate = Double(sample[1]) else { return false }
            return time.isFinite && time > 0.2 && rate > 0 && abs(time - previousTime) > 0.2
        }, evaluatedWith: clock)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 30), .completed,
                       "The bundled audio clock should advance. \(String(describing: clock.value))", file: file, line: line)
    }

    func testLineOnlyLyricsRemainVisibleInBothAnimatedStylesAfterSeek() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--presentation-reset", "--playback-probe", "--line-only-lyrics-fixture",
                               "-Folia.EnergySavingAnimation", "YES"]
        app.launchEnvironment["SYLLUME_TEST_INITIAL_DISPLAY_MODE"] = "cover"
        app.launch()
        let demo = app.buttons["demoTrack"]
        XCTAssertTrue(demo.waitForExistence(timeout: 15))
        demo.tap()
        let toggle = app.buttons["playerToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        app.buttons["循環佇列"].tap()
        let clock = app.staticTexts["localTransportProbe"]
        let started = expectation(for: NSPredicate { _, _ in
            let sample = (clock.value as? String ?? "").split(separator: "|")
            guard sample.count == 2, let time = Double(sample[0]), let rate = Double(sample[1]) else { return false }
            return time > 0.2 && time.isFinite && rate > 0
        }, evaluatedWith: clock)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 20), .completed)
        if toggle.label != "播放" { toggle.tap() }
        waitForPausedNativeClock(clock)
        let progress = app.descendants(matching: .any)["playbackProgress"].firstMatch
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.46, dy: 0.5)).tap()
        let sought = expectation(for: NSPredicate { _, _ in
            let sample = (clock.value as? String ?? "").split(separator: "|")
            guard sample.count == 2, let time = Double(sample[0]), let rate = Double(sample[1]) else { return false }
            return (13...15).contains(time) && rate == 0
        }, evaluatedWith: clock)
        XCTAssertEqual(XCTWaiter.wait(for: [sought], timeout: 15), .completed)
        let pausedTime = probeTime(clock)

        for (name, id) in [("商籟", "syllumeSonnetStage"), ("繪光", "syllumeLumiereStage")] {
            app.segmentedControls.buttons[name].tap()
            let stage = app.descendants(matching: .any)[id].firstMatch
            let ready = expectation(for: NSPredicate(format: "value BEGINSWITH %@ AND label CONTAINS %@",
                "已就緒", "Let the current carry us"), evaluatedWith: stage)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 90), .completed, "\(name) did not render the sought line")
            XCTAssertTrue(app.staticTexts["讓潮水帶我們向前"].waitForExistence(timeout: 10))
            XCTAssertEqual(probeTime(clock), pausedTime, accuracy: 0.15)
            capture(app, name: "Syllume-line-only-\(id)")
        }
    }

    func testMistStylePersistsAndProgressControlsSeekPausedAudio() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--presentation-reset", "--playback-probe", "--subtitle-fixture", "--subtitle-reset"]
        app.launchEnvironment["SYLLUME_TEST_INITIAL_DISPLAY_MODE"] = "cover"
        app.launch()
        let demo = app.buttons["demoTrack"]
        XCTAssertTrue(demo.waitForExistence(timeout: 15)); demo.tap()
        let toggle = app.buttons["playerToggle"]
        let started = expectation(for: NSPredicate(format: "label == %@", "暫停"), evaluatedWith: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 15), .completed,
                       "The demo must start playing before the pause and seek actions.")
        toggle.tap()
        let clock = app.staticTexts["localTransportProbe"]
        waitForPausedNativeClock(clock)
        let progress = app.descendants(matching: .any)["playbackProgress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        selectPlaybackMode("霧盞", in: app)
        let mist = app.descendants(matching: .any)["mistLyricStage"].firstMatch
        XCTAssertTrue(mist.waitForExistence(timeout: 15))
        func expectPausedPosition(_ time: Double) {
            let positioned = expectation(for: NSPredicate { _, _ in
                let value = clock.value as? String ?? ""
                guard value.hasSuffix("|0.0"), let first = value.split(separator: "|").first,
                      let actual = Double(first) else { return false }
                return abs(actual - time) < 1.8
            }, evaluatedWith: clock)
            XCTAssertEqual(XCTWaiter.wait(for: [positioned], timeout: 15), .completed,
                           "Expected paused AVPlayer near \(time)s, got \(String(describing: clock.value)).")
        }
        let tap = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.29, dy: 0.5))
        tap.tap()
        expectPausedPosition(8.7)
        let destination = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.5))
        tap.press(forDuration: 0.12, thenDragTo: destination)
        expectPausedPosition(20.4)
        let currentLine = app.descendants(matching: .any)["mistLyricCurrentLine"].firstMatch
        let traditional = expectation(for: NSPredicate(format: "label == %@ AND value == %@", "頭髮發現", "風裡的回聲"),
                                      evaluatedWith: currentLine)
        XCTAssertEqual(XCTWaiter.wait(for: [traditional], timeout: 15), .completed)
        capture(app, name: "Syllume-mist-and-progress")

        app.terminate()
        app.launchEnvironment = [:]
        app.launchArguments = ["--playback-probe", "--subtitle-fixture"]
        app.launch()
        XCTAssertTrue(demo.waitForExistence(timeout: 15)); demo.tap()
        XCTAssertTrue(mist.waitForExistence(timeout: 15), "The last lyric style should survive relaunch.")
    }

    func testNativeDelayedEndDoesNotReplaceSeekAndSeekingToEndRepeats() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--native-end-fixture", "--playback-probe", "--presentation-reset",
                               "-Folia.EnergySavingAnimation", "YES"]
        app.launchEnvironment["SYLLUME_TEST_INITIAL_DISPLAY_MODE"] = "cover"
        app.launch()
        let demo = app.buttons["demoTrack"]
        XCTAssertTrue(demo.waitForExistence(timeout: 15)); demo.tap()
        let clock = app.staticTexts["localTransportProbe"]
        let seek = app.staticTexts["nativeSeekProbe"]
        let toggle = app.buttons["playerToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        app.buttons["循環佇列"].tap()
        func expectClock(_ accepts: @escaping (Double, Double) -> Bool, _ message: String) {
            let observed = expectation(for: NSPredicate { _, _ in
                let fields = (clock.value as? String ?? "").split(separator: "|")
                guard fields.count == 2, let time = Double(fields[0]), time.isFinite,
                      let rate = Double(fields[1]), rate.isFinite else { return false }
                return seek.value as? String == "idle|0" && accepts(time, rate)
            }, evaluatedWith: clock)
            XCTAssertEqual(XCTWaiter.wait(for: [observed], timeout: 20), .completed,
                           "\(message). Actual AVPlayer sample: \(String(describing: clock.value))")
        }
        expectClock({ $0 > 0.2 && $1 > 0 }, "The real demo audio must start")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForPausedNativeClock(clock)
        let progress = app.descendants(matching: .any)["playbackProgress"].firstMatch
        progress.coordinate(withNormalizedOffset: CGVector(dx: 1.0 / 3.0, dy: 0.5)).tap()
        expectClock({ abs($0 - 10) < 1 && $1 == 0 }, "The paused audio must seek near ten seconds")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectClock({ $0 >= 9.5 && $0 < 20 && $1 > 0 }, "The sought audio must resume")

        // The callback ordering is simulated; all time and playback checks use AVPlayer.
        let delayedEnd = app.buttons["simulateDelayedNativeEnd"]
        XCTAssertTrue(delayedEnd.waitForExistence(timeout: 10)); delayedEnd.tap()
        var previousAfterCallback: Double?
        expectClock({ time, rate in
            guard time >= 9.5, time < 20, rate > 0 else { previousAfterCallback = nil; return false }
            defer { previousAfterCallback = time }
            return previousAfterCallback.map { time > $0 + 0.01 } ?? false
        }, "A delayed old end must preserve two advancing samples after this seek")
        capture(app, name: "Syllume-native-simulated-stale-end-after-seek")

        let seekEnd = app.buttons["seekToNativeEnd"]
        XCTAssertTrue(seekEnd.waitForExistence(timeout: 10)); seekEnd.tap()
        expectClock({ $0 > 0.1 && $0 < 8 && $1 > 0 }, "A playing seek to the exact physical end must repeat")
        capture(app, name: "Syllume-native-seek-to-end-repeated")

        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForPausedNativeClock(clock)
        seekEnd.tap()
        expectClock({ abs($0 - 30) < 0.2 && $1 == 0 }, "A paused seek to the physical end must stay paused")
        capture(app, name: "Syllume-native-paused-seek-to-end")
    }

    func testLargeTextPlaybackKeepsStyleMenuAndControlsUsable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--accessibility-text-fixture", "--subtitle-fixture", "--subtitle-reset",
                               "--presentation-reset", "--playback-probe", "-Folia.EnergySavingAnimation", "YES"]
        app.launchEnvironment["SYLLUME_TEST_INITIAL_DISPLAY_MODE"] = "cover"
        app.launch()

        let demo = app.buttons["demoTrack"]
        XCTAssertTrue(demo.waitForExistence(timeout: 15))
        demo.tap()

        let style = app.buttons["lyricStyleMenu"]
        XCTAssertTrue(style.waitForExistence(timeout: 15))
        let menuReady = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: style)
        XCTAssertEqual(XCTWaiter.wait(for: [menuReady], timeout: 15), .completed)
        style.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let mistOption = app.buttons["霧盞"]
        XCTAssertTrue(mistOption.waitForExistence(timeout: 10))
        mistOption.tap()
        let mist = app.descendants(matching: .any)["mistLyricCurrentLine"].firstMatch
        XCTAssertTrue(mist.waitForExistence(timeout: 15))

        let toggle = app.buttons["playerToggle"]
        let progress = app.descendants(matching: .any)["playbackProgress"].firstMatch
        for control in [toggle, progress] {
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            XCTAssertTrue(app.frame.contains(control.frame))
        }
        if toggle.label == "暫停" { toggle.tap() }
        waitForPausedNativeClock(app.staticTexts["localTransportProbe"])
        capture(app, name: "Syllume-large-text-playback")
    }

    func testMistRenderingResourceSample() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--presentation-reset", "--playback-probe", "--subtitle-fixture", "--subtitle-reset"]
        app.launchEnvironment["SYLLUME_TEST_INITIAL_DISPLAY_MODE"] = "mist"
        app.launch()
        let demo = app.buttons["demoTrack"]
        XCTAssertTrue(demo.waitForExistence(timeout: 15)); demo.tap()
        let mist = app.descendants(matching: .any)["mistLyricCurrentLine"].firstMatch
        XCTAssertTrue(mist.waitForExistence(timeout: 15))
        let toggle = app.buttons["playerToggle"]
        app.buttons["循環佇列"].tap()
        if toggle.label == "播放" { toggle.tap() }
        let clock = app.staticTexts["localTransportProbe"]
        let playing = expectation(for: NSPredicate(format: "value ENDSWITH %@", "|1.0"), evaluatedWith: clock)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 15), .completed)

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: options) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 4))
        }
        capture(app, name: "Syllume-mist-playing")
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

    func testYouTubeCoverFallbackAndOfflineCacheWhenAudioUnavailable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--youtube-sync-fixture", "--youtube-sync-reset", "--youtube-artwork-reset", "--youtube-unavailable-audio-fixture",
                               "--subtitle-fixture", "-Folia.LyricDisplayMode", "cover"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Syllume"].waitForExistence(timeout: 10))
        app.segmentedControls.buttons["YouTube"].tap()
        let liked = app.buttons["youtubePlaylist-liked"]
        XCTAssertTrue(liked.waitForExistence(timeout: 10)); liked.tap()
        let song = app.buttons["youtubeSong-fixture-row"]
        XCTAssertTrue(song.waitForExistence(timeout: 15)); song.tap()
        XCTAssertTrue(app.staticTexts["YouTube 限制這部影片的內嵌播放。"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.webViews["youtubeEmbeddedPlayer"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["openYouTubeMusic"].firstMatch.exists)
        let artwork = app.descendants(matching: .any)["playerArtwork"].firstMatch
        XCTAssertTrue(artwork.waitForExistence(timeout: 10))
        let nowPlaying = app.staticTexts["systemNowPlayingProbe"]
        let published = expectation(for: NSPredicate(format: "value == %@", "0.0|0.0|artwork"), evaluatedWith: nowPlaying)
        XCTAssertEqual(XCTWaiter.wait(for: [published], timeout: 10), .completed)
        app.terminate()
        app.launchArguments = ["--youtube-sync-fixture", "--youtube-artwork-offline", "--youtube-unavailable-audio-fixture",
                               "--subtitle-fixture", "-Folia.LyricDisplayMode", "cover"]
        for attempt in 1...2 {
            app.launch()
            app.segmentedControls.buttons["YouTube"].tap()
            XCTAssertTrue(song.waitForExistence(timeout: 15)); song.tap()
            XCTAssertTrue(artwork.waitForExistence(timeout: 10), "Cached cover after offline launch \(attempt)")
            app.terminate()
        }
    }

    func testYouTubeShowsVerifiedArtistPortraitAlongsideCover() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = ["--youtube-sync-fixture", "--youtube-artist-portrait-fixture",
                       "--subtitle-fixture", "--playback-probe", "-Folia.LyricDisplayMode", "cover"]
        app.launchArguments = fixture + ["--youtube-sync-reset", "--youtube-artwork-reset"]
        app.launch()
        app.segmentedControls.buttons["YouTube"].tap()
        let liked = app.buttons["youtubePlaylist-liked"]
        XCTAssertTrue(liked.waitForExistence(timeout: 10)); liked.tap()
        let song = app.buttons["youtubeSong-fixture-portrait"]
        let wrongOwner = app.buttons["youtubeSong-fixture-portrait-mismatch"]
        let cover = app.descendants(matching: .any)["playerArtwork"].firstMatch
        let portrait = app.descendants(matching: .any)["nowPlayingArtistPortrait"].firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 15)); song.tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 10))
        XCTAssertTrue(portrait.waitForExistence(timeout: 15), "A successful cover must not suppress the verified artist photo")
        XCTAssertEqual(portrait.label, "歌手頭像")
        XCTAssertNotEqual(cover.frame, portrait.frame)
        capture(app, name: "Syllume-YouTube-cover-and-artist-portrait")

        app.buttons["關閉播放畫面"].tap()
        XCTAssertTrue(wrongOwner.waitForExistence(timeout: 10)); wrongOwner.tap()
        let clock = app.staticTexts["localTransportProbe"]
        let playing = expectation(for: NSPredicate { _, _ in
            let sample = (clock.value as? String ?? "").split(separator: "|")
            guard sample.count == 2, let position = Double(sample[0]), let rate = Double(sample[1]) else { return false }
            return position.isFinite && position > 1 && rate > 0
        }, evaluatedWith: clock)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 15), .completed)
        XCTAssertTrue(cover.waitForExistence(timeout: 10))
        XCTAssertFalse(portrait.exists, "A mismatched uploader must not show the previous singer's portrait")

        app.terminate()
        app.launchArguments = fixture + ["--youtube-artwork-offline"]
        app.launch()
        app.segmentedControls.buttons["YouTube"].tap()
        XCTAssertTrue(song.waitForExistence(timeout: 15)); song.tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 10))
        XCTAssertTrue(portrait.waitForExistence(timeout: 15), "The verified artist photo must survive offline relaunch")
        capture(app, name: "Syllume-YouTube-cached-artist-portrait")
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
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let stopped = waitForPausedNativeClock(probe)
        wait(2)
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
    }

    func testNativeLoopbackStreamsAndSeeks() throws {
        try verifyNativeStreamAndSeek(scheme: "http")
    }

    func testNativePublicHTTPSStreamsAndSeeks() throws {
        _ = try XCTUnwrap(ProcessInfo.processInfo.environment["SYLLUME_TEST_RANGE_AUDIO_URL"],
                          "The public HTTPS check requires a successful remote fixture preflight.")
        try verifyNativeStreamAndSeek(scheme: "https")
    }

    private func verifyNativeStreamAndSeek(scheme: String) throws {
        continueAfterFailure = false
        let app = try openNativeNetworkPlaylistTrack()
        let transport = scheme.uppercased()
        let clock = app.staticTexts["localTransportProbe"]
        let trace = app.staticTexts["nativeTransportDebugProbe"]
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "測試 \(transport) 音源")).firstMatch
            .waitForExistence(timeout: 20))
        waitForNativeStreamAdvance(clock, media: scheme, trace: trace)

        let toggle = app.buttons["playerToggle"]
        if toggle.label == "暫停" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let paused = expectation(for: NSPredicate(format: "value ENDSWITH %@", "|0.0|\(scheme)|none"), evaluatedWith: clock)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 15), .completed)
        let progress = app.descendants(matching: .any)["playbackProgress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        let seek = app.staticTexts["nativeSeekProbe"]
        XCTAssertTrue(seek.waitForExistence(timeout: 5))
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        let sought = expectation(for: NSPredicate { _, _ in
            let sample = (clock.value as? String ?? "").split(separator: "|")
            guard sample.count == 4, let time = Double(sample[0]), sample[1] == "0.0",
                  sample[2] == scheme, sample[3] == "none" else { return false }
            return abs(time - 12) < 1.2 && seek.value as? String == "idle|0"
        }, evaluatedWith: clock)
        XCTAssertEqual(XCTWaiter.wait(for: [sought], timeout: 20), .completed,
                       "Expected prepared paused \(transport) audio near 12 seconds; state \(String(describing: seek.value)), clock \(String(describing: clock.value))")
        capture(app, name: "Syllume-\(transport)-stream-seek")

        let soughtTime = probeTime(clock)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let resumed = expectation(for: NSPredicate { _, _ in
            let sample = (clock.value as? String ?? "").split(separator: "|")
            guard sample.count == 4, let time = Double(sample[0]), let rate = Double(sample[1]),
                  sample[2] == scheme, sample[3] == "none" else { return false }
            return time > soughtTime + 0.25 && rate > 0 && seek.value as? String == "idle|0"
        }, evaluatedWith: clock)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 20), .completed,
                       "Prepared \(transport) audio must advance after resuming from \(soughtTime); observed \(String(describing: clock.value))")
        XCTAssertFalse(app.descendants(matching: .any)["youtubeEmbeddedPlayer"].firstMatch.exists)
        print("Native \(transport) paused seek at \(soughtTime), resumed at \(String(describing: clock.value))")
        capture(app, name: "Syllume-\(transport)-stream-resumed-after-seek")
    }

    func testNativeLoopbackFallsBackAfterTimeout() throws {
        continueAfterFailure = false
        let app = try openNativeNetworkPlaylistTrack()
        let fallback = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "測試本機備援")).firstMatch
        XCTAssertTrue(fallback.waitForExistence(timeout: 25), "An unresponsive HTTP stream should give way to the local candidate")
        waitForNativeStreamAdvance(app.staticTexts["localTransportProbe"], media: "file", after: "timeout")
        XCTAssertFalse(app.descendants(matching: .any)["youtubeEmbeddedPlayer"].firstMatch.exists)
        capture(app, name: "Syllume-HTTP-stream-fallback")
    }

    func testNativePausedSeekEndsWhenHTTPStopsResponding() throws {
        continueAfterFailure = false
        let app = try openNativeNetworkPlaylistTrack(seekFixture: true)
        let clock = app.staticTexts["localTransportProbe"]
        func attachSeekTransport(_ name: String) {
            let evidence = app.staticTexts["nativeTransportDebugProbe"].value as? String ?? "No native transport trace"
            let attachment = XCTAttachment(string: evidence)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            print("\(name)\n\(evidence)")
        }
        waitForNativeStreamAdvance(clock, media: "http", trace: app.staticTexts["nativeTransportDebugProbe"])
        let toggle = app.buttons["playerToggle"]
        if toggle.label == "暫停" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let paused = expectation(for: NSPredicate(format: "value ENDSWITH %@", "|0.0|http|none"), evaluatedWith: clock)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 15), .completed)
        try setLoopbackControl("stall")

        let progress = app.descendants(matching: .any)["playbackProgress"].firstMatch
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        let seek = app.staticTexts["nativeSeekProbe"]
        let ended = expectation(for: NSPredicate(format: "value == %@", "idle|-5"), evaluatedWith: seek)
        let stalledSeekResult = XCTWaiter.wait(for: [ended], timeout: 20)
        attachSeekTransport("Native HTTP paused seek after stopping transfer")
        XCTAssertEqual(stalledSeekResult, .completed,
                       "The stalled paused seek must terminate. State \(String(describing: seek.value)), clock \(String(describing: clock.value))")
        XCTAssertTrue((clock.value as? String ?? "").contains("|0.0|http|"))
        XCTAssertEqual(toggle.label, "播放")
        capture(app, name: "Syllume-HTTP-paused-seek-timeout")

        try setLoopbackControl("resume")
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        let retried = expectation(for: NSPredicate { _, _ in
            let fields = (clock.value as? String ?? "").split(separator: "|")
            guard fields.count == 4, let time = Double(fields[0]), fields[1] == "0.0", fields[2] == "http" else { return false }
            return abs(time - 7.5) < 1.2 && seek.value as? String == "idle|0"
        }, evaluatedWith: clock)
        let recoveredSeekResult = XCTWaiter.wait(for: [retried], timeout: 20)
        attachSeekTransport("Native HTTP paused seek after restoring transfer")
        XCTAssertEqual(recoveredSeekResult, .completed,
                       "A new paused seek must recover after HTTP resumes. \(String(describing: clock.value))")
        capture(app, name: "Syllume-HTTP-paused-seek-recovered")
    }

    private func setLoopbackControl(_ action: String) throws {
        guard ["stall", "resume"].contains(action),
              let endpoint = ProcessInfo.processInfo.environment["SYLLUME_TEST_RANGE_AUDIO_URL"],
              let parts = URLComponents(string: endpoint), parts.host == "127.0.0.1", let port = parts.port,
              (1...65535).contains(port),
              let networkPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw XCTSkip("Requires a loopback audio fixture with control enabled.")
        }
        let connection = NWConnection(host: "127.0.0.1", port: networkPort, using: .tcp)
        defer { connection.cancel() }
        let completed = expectation(description: "Loopback HTTP control \(action)")
        let request = "POST /control/\(action) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    XCTAssertNil(error)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, receiveError in
                        XCTAssertNil(receiveError)
                        let response = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        XCTAssertTrue(response.hasPrefix("HTTP/1.1 204"), response)
                        completed.fulfill()
                    }
                })
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 10), .completed)
    }

    private func openNativeNetworkPlaylistTrack(seekFixture: Bool = false) throws -> XCUIApplication {
        guard let endpoint = ProcessInfo.processInfo.environment["SYLLUME_TEST_RANGE_AUDIO_URL"] else {
            throw XCTSkip("Requires the native network audio fixture from the macOS workflow.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--native-network-fixture", "--youtube-sync-fixture", "--youtube-sync-reset",
                               "--subtitle-fixture", "--playback-probe", "-Folia.EnergySavingAnimation", "YES",
                               "-Folia.LyricDisplayMode", "cover"]
        if seekFixture { app.launchArguments.append("--loopback-seek-fixture") }
        app.launchEnvironment["SYLLUME_TEST_RANGE_AUDIO_URL"] = endpoint
        app.launch()
        app.segmentedControls.buttons["YouTube"].tap()
        let liked = app.buttons["youtubePlaylist-liked"]
        XCTAssertTrue(liked.waitForExistence(timeout: 10)); liked.tap()
        let audio = app.buttons["youtubeSong-fixture-row"]
        XCTAssertTrue(audio.waitForExistence(timeout: 15)); audio.tap()
        return app
    }

    private func waitForNativeStreamAdvance(_ clock: XCUIElement, media: String, after problem: String = "none",
                                            trace: XCUIElement? = nil,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let advancing = expectation(for: NSPredicate { _, _ in
            let sample = (clock.value as? String ?? "").split(separator: "|")
            guard sample.count == 4, let time = Double(sample[0]), let rate = Double(sample[1]) else { return false }
            return time > 0.3 && time.isFinite && rate > 0 && sample[2] == media && sample[3] == problem
        }, evaluatedWith: clock)
        // Cover the bounded 34-second startup window and cross-process accessibility snapshots.
        // Keep checking the real media source so a late local fallback cannot satisfy this wait.
        let result = XCTWaiter.wait(for: [advancing], timeout: 45)
        if result != .completed, let trace {
            let evidence = trace.value as? String ?? "No native transport trace"
            let attachment = XCTAttachment(string: evidence)
            attachment.name = "Native network transport trace"
            attachment.lifetime = .keepAlways
            add(attachment)
            print(evidence)
        }
        XCTAssertEqual(result, .completed,
                       "Expected \(media) after \(problem) to advance; observed \(String(describing: clock.value))", file: file, line: line)
    }

    func testYouTubePlaylistDownloadRequiresConfirmation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--youtube-sync-fixture", "--youtube-sync-reset", "--subtitle-fixture",
                               "-Folia.LyricDisplayMode", "cover"]
        app.launch()
        app.segmentedControls.buttons["YouTube"].tap()
        let liked = app.buttons["youtubePlaylist-liked"]
        XCTAssertTrue(liked.waitForExistence(timeout: 10)); liked.tap()
        XCTAssertTrue(liked.waitForNonExistence(timeout: 15))
        let audio = app.buttons["youtubeSong-fixture-row"]
        XCTAssertTrue(audio.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["syncYouTubePlaylist"].waitForExistence(timeout: 15))
        XCTAssertEqual(audio.value as? String, "點歌時搜尋音源")
        let options = app.buttons["youtubeSongMenu-fixture-row"]
        let confirm = app.buttons["confirmPlaylistDownload"]
        let download = app.buttons["下載音樂"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        func optionsOnScreen() -> Bool {
            let frame = options.frame
            return !frame.isNull && !frame.isInfinite && frame.height >= 44 && app.frame.contains(frame)
        }
        if !optionsOnScreen() { app.swipeUp() }
        func openConfirmation() {
            let ready = expectation(for: NSPredicate { _, _ in optionsOnScreen() }, evaluatedWith: options)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
            XCTAssertTrue(options.isHittable)
            XCTAssertFalse(options.frame.intersects(audio.frame))
            options.tap()
            XCTAssertTrue(download.waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["playerToggle"].exists, "Opening song options must not start playback")
            XCTAssertFalse(confirm.exists, "The confirmation sheet needs an explicit download selection")
            download.tap()
            XCTAssertTrue(confirm.waitForExistence(timeout: 20))
        }
        openConfirmation()
        let cancel = app.buttons["cancelPlaylistDownload"]
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 15))
        let cancelled = expectation(for: NSPredicate(format: "hittable == true AND value == %@", "點歌時搜尋音源"),
                                    evaluatedWith: audio)
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 15), .completed)
        openConfirmation()
        confirm.tap()
        let saved = expectation(for: NSPredicate(format: "value CONTAINS %@", "示範音軌"), evaluatedWith: audio)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 20), .completed)
    }

    func testAttachmentUsesItsOwnImportWhileDownloading() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--youtube-sync-fixture", "--youtube-sync-reset", "--syllume-recording-regression",
                               "--youtube-attachment-race-fixture", "--subtitle-fixture"]
        app.launch()
        app.segmentedControls.buttons["YouTube"].tap()
        let liked = app.buttons["youtubePlaylist-liked"]
        XCTAssertTrue(liked.waitForExistence(timeout: 10)); liked.tap()
        let attach = app.buttons["attachWhileDownloadingFixture"]
        XCTAssertTrue(attach.waitForExistence(timeout: 15)); attach.tap()
        let attached = expectation(for: NSPredicate(format: "value MATCHES %@", "[A-Fa-f0-9-]{36}"), evaluatedWith: attach)
        XCTAssertEqual(XCTWaiter.wait(for: [attached], timeout: 35), .completed,
                       "The manual import must bind a plain UUID even when the earlier catalogue entry is a download.")
        let download = app.buttons["youtubeSong-recording-jane"]
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        XCTAssertTrue((download.value as? String ?? "").contains("示範音軌"))
        let manual = app.buttons["youtubeSong-recording-lemon"]
        XCTAssertTrue(manual.waitForExistence(timeout: 10))
        XCTAssertEqual(manual.value as? String, "手動附加音檔")
    }

    func testSpotifyHandoffAllowsPlaybackFromEitherPlayer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--spotify-handoff-fixture", "--playback-probe", "--subtitle-fixture",
                               "-Folia.LyricDisplayMode", "cover"]
        app.launch()
        let demo = app.buttons["demoTrack"]
        XCTAssertTrue(demo.waitForExistence(timeout: 15)); demo.tap()
        let close = app.buttons["關閉播放畫面"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        app.buttons["循環佇列"].tap()
        close.tap()
        app.segmentedControls.buttons["Spotify"].tap()
        let external = app.buttons["在 Spotify 查看曲庫"]
        XCTAssertTrue(external.waitForExistence(timeout: 10))
        let mini = app.buttons["openMiniPlayer"]
        let miniToggle = app.buttons["miniPlayerToggle"]
        let fullToggle = app.buttons["playerToggle"]
        for (index, fromMini) in [false, true].enumerated() {
            XCTAssertTrue(external.waitForExistence(timeout: 10)); external.tap()
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(miniToggle.waitForExistence(timeout: 10))
            XCTAssertEqual(miniToggle.label, "播放")
            if fromMini { miniToggle.tap() }
            mini.tap()
            let handoff = app.staticTexts["spotifyHandoffProbe"]
            XCTAssertTrue(handoff.waitForExistence(timeout: 10))
            if !fromMini {
                let probe = app.staticTexts["localTransportProbe"]
                let paused = expectation(for: NSPredicate(format: "value ENDSWITH %@", "|0.0"), evaluatedWith: probe)
                XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 10), .completed)
                fullToggle.tap()
            }
            // The native clock accumulates real advancing samples for this handoff, so an
            // incomplete accessibility snapshot cannot discard a sample or confuse two handoffs.
            let advancing = expectation(for: NSPredicate(format: "value == %@", "\(index + 1)|advancing"),
                                        evaluatedWith: handoff)
            XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 25), .completed,
                           "Expected AVPlayer time to advance after resuming from the \(fromMini ? "mini" : "full") player.")
            close.tap()
            XCTAssertTrue(handoff.waitForNonExistence(timeout: 15))
        }
    }

    func testLateYouTubeDurationLoadsLyricsAndQueueRestartsVideo() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--youtube-sync-fixture", "--youtube-sync-reset", "--syllume-recording-regression",
                               "--youtube-playback-fixture", "--youtube-missing-duration-fixture", "--subtitle-fixture", "--subtitle-reset",
                               "-Folia.LyricDisplayMode", "lyrics"]
        app.launch()
        app.segmentedControls.buttons["YouTube"].tap()
        let liked = app.buttons["youtubePlaylist-liked"]
        XCTAssertTrue(liked.waitForExistence(timeout: 10)); liked.tap()
        let jane = app.buttons["youtubeSong-recording-jane"]
        XCTAssertTrue(jane.waitForExistence(timeout: 15)); jane.tap()
        XCTAssertTrue(app.descendants(matching: .any)["youtubeEmbeddedPlayer"].firstMatch.waitForExistence(timeout: 15))
        let transport = app.staticTexts["youtubeTransportProbe"]
        assertLyric("頭髮發現", in: app, timeout: 30)
        let beforeQueue = waitForYouTubePlayback(transport, above: 25, timeout: 55,
                                                "Expected actual playback before selecting the current queue row.")
        app.buttons["播放佇列"].tap()
        let current = app.buttons["trackRow-recording-jane"]
        XCTAssertTrue(current.waitForExistence(timeout: 10)); current.tap()
        // The media fixture has a continuous timeline. A lower, advancing clock demonstrates a restart.
        waitForYouTubePlayback(transport, below: beforeQueue - 2, timeout: 40,
                               "Selecting the current queue row must restart playback from \(beforeQueue)s.")
    }

    func testPublicYouTubeIFrameReferenceVideo() {
        verifyPublicYouTubeIFrame(song: "fixture-row", videoID: "M7lc1UVf-VE")
    }

    func testPublicYouTubeIFrameRecordedHelp() {
        verifyPublicYouTubeIFrame(song: "recording-help", videoID: "z2tDtdHHAHg",
                                 playlistArguments: ["--youtube-device-playback-regression"])
    }

    private func verifyPublicYouTubeIFrame(song: String, videoID: String, playlistArguments: [String] = []) {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The catalogue row and unavailable independent audio are controlled. The IFrame and media are live.
        app.launchArguments = ["--youtube-sync-fixture", "--youtube-sync-reset", "--youtube-public-smoke",
                               "--subtitle-fixture", "-Folia.LyricDisplayMode", "cover"] + playlistArguments
        app.launch()
        let tab = app.segmentedControls.buttons["YouTube"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        tab.tap()
        let liked = app.buttons["youtubePlaylist-liked"]
        XCTAssertTrue(liked.waitForExistence(timeout: 10))
        liked.tap()
        let entry = app.buttons["youtubeSong-\(song)"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        entry.tap()
        let video = app.descendants(matching: .any)["youtubeEmbeddedPlayer"].firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 20))
        XCTAssertGreaterThanOrEqual(video.frame.width, 200)
        XCTAssertGreaterThanOrEqual(video.frame.height, 200)
        XCTAssertTrue(app.staticTexts["YouTube · 官方播放器"].exists)
        let transport = app.staticTexts["youtubeTransportProbe"]
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        var firstTime: Double?
        var lastSample = "unavailable"
        var advanced = false
        let resolved = expectation(for: NSPredicate { _, _ in
            lastSample = transport.value as? String ?? "unavailable"
            let fields = lastSample.split(separator: "|")
            guard fields.count == 2 else { return false }
            if fields[1].contains(":") { return true }
            guard fields[1] == "playing", let time = Double(fields[0]), time.isFinite else { return false }
            if firstTime == nil { firstTime = time }
            advanced = firstTime.map { time - $0 >= 2 } ?? false
            return advanced
        }, evaluatedWith: transport)
        _ = XCTWaiter.wait(for: [resolved], timeout: 50)
        print("Public YouTube IFrame \(videoID): first=\(String(describing: firstTime)) last=\(lastSample)")
        capture(app, name: "public-YouTube-\(videoID)")
        if lastSample.hasSuffix("|permission:101") || lastSample.hasSuffix("|permission:150") {
            XCTAssertTrue(app.staticTexts["YouTube 目前無法在 App 內播放這部影片。"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.descendants(matching: .any)["openYouTubeMusic"].firstMatch.exists)
            let progress = app.descendants(matching: .any)["playbackProgress"].firstMatch
            let displayedTime = progress.value as? String
            XCTAssertNotNil(displayedTime)
            XCTAssertFalse(displayedTime?.contains("緩衝中") == true)
        }
        XCTAssertTrue(advanced, "Official IFrame \(videoID) did not advance by two seconds. Last media sample: \(lastSample)")
    }

    func testYouTubeSongAutomaticallyPlaysVisibleOriginal() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--youtube-sync-fixture", "--youtube-sync-reset", "--youtube-device-playback-regression",
                               "--youtube-playback-fixture", "--youtube-reject-resume-fixture", "--subtitle-fixture",
                               "-Folia.LyricDisplayMode", "cover",
                               "-Folia.EnergySavingAnimation", "YES"]
        app.launch()
        app.segmentedControls.buttons["YouTube"].tap()
        let liked = app.buttons["youtubePlaylist-liked"]
        XCTAssertTrue(liked.waitForExistence(timeout: 10)); liked.tap()
        let help = app.buttons["youtubeSong-recording-help"]
        XCTAssertTrue(help.waitForExistence(timeout: 15)); help.tap()
        let video = app.descendants(matching: .any)["youtubeEmbeddedPlayer"].firstMatch
        let transport = app.staticTexts["youtubeTransportProbe"]
        XCTAssertTrue(video.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(video.frame.width, 200)
        XCTAssertGreaterThanOrEqual(video.frame.height, 200)
        let beforeClosing = waitForYouTubePlayback(transport, above: 10, timeout: 40,
                                                  "The song tap must start playback without a second action.")
        XCTAssertTrue(app.staticTexts["YouTube · 官方播放器"].exists)

        app.buttons["關閉播放畫面"].tap()
        let mini = app.buttons["miniPlayerToggle"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        let paused = expectation(for: NSPredicate(format: "label == %@", "播放"), evaluatedWith: mini)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 10), .completed)
        mini.tap()
        XCTAssertTrue(video.waitForExistence(timeout: 15))
        waitForYouTubePlayback(transport, above: beforeClosing + 0.5, timeout: 40,
                               "Expected the reopened media to play past \(beforeClosing)s.")
        capture(app, name: "HELP-YouTube-visible-playback")

        let toggle = app.buttons["playerToggle"]
        toggle.tap()
        let stopped = expectation(for: NSPredicate(format: "label == %@", "播放"), evaluatedWith: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 15), .completed)
        let rail = app.descendants(matching: .any)["playbackProgress"].firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 10))
        rail.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.5)).tap()
        let sought = expectation(for: NSPredicate { _, _ in
            let value = transport.value as? String ?? ""
            guard value.hasSuffix("|paused"), let first = value.split(separator: "|").first,
                  let time = Double(first) else { return false }
            return abs(time - 90.24) < 4
        }, evaluatedWith: transport)
        XCTAssertEqual(XCTWaiter.wait(for: [sought], timeout: 18), .completed,
                       "Expected the paused iframe fixture to seek near 90s. Got \(String(describing: transport.value)).")

        toggle.tap()
        let retried = expectation(for: NSPredicate(format: "label == %@", "YouTube 播放指令已重送"), evaluatedWith: transport)
        XCTAssertEqual(XCTWaiter.wait(for: [retried], timeout: 15), .completed,
                       "The first resume dispatch must be rejected by WebKit and retried.")
        waitForYouTubePlayback(transport, above: 93, below: 125, timeout: 30,
                               "A single resume tap must recover and play past the paused seek target.")
        capture(app, name: "HELP-YouTube-playback-dispatch-recovered")
    }

    func testCompactYouTubePlayerKeepsVideoAndControlsVisibleWithLargeText() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--accessibility-text-fixture", "--youtube-sync-fixture", "--youtube-sync-reset",
                               "--syllume-recording-regression", "--youtube-playback-fixture", "--subtitle-fixture",
                               "--subtitle-reset", "--presentation-reset", "-Folia.EnergySavingAnimation", "YES"]
        app.launchEnvironment["SYLLUME_TEST_INITIAL_DISPLAY_MODE"] = "cover"
        app.launch()
        XCTAssertLessThanOrEqual(app.frame.width, 375)
        XCTAssertLessThanOrEqual(app.frame.height, 667, "Run this case on the iPhone SE simulator.")
        let sources = app.buttons["librarySourceMenu"]
        XCTAssertTrue(sources.waitForExistence(timeout: 10)); sources.tap()
        let youtube = app.buttons["YouTube"]
        XCTAssertTrue(youtube.waitForExistence(timeout: 10)); youtube.tap()
        let liked = app.buttons["youtubePlaylist-liked"]
        XCTAssertTrue(liked.waitForExistence(timeout: 10)); liked.tap()
        let jane = app.buttons["youtubeSong-recording-jane"]
        XCTAssertTrue(app.staticTexts["selectedYouTubePlaylist"].waitForExistence(timeout: 15))
        for _ in 0..<5 where !jane.isHittable { app.swipeUp() }
        XCTAssertTrue(jane.isHittable); jane.tap()

        let video = app.descendants(matching: .any)["youtubeEmbeddedPlayer"].firstMatch
        let transport = app.staticTexts["youtubeTransportProbe"]
        XCTAssertTrue(video.waitForExistence(timeout: 20))
        let originalVideoFrame = video.frame
        XCTAssertGreaterThanOrEqual(originalVideoFrame.width, 200)
        XCTAssertGreaterThanOrEqual(originalVideoFrame.height, 200)
        XCTAssertTrue(app.frame.contains(originalVideoFrame))
        waitForYouTubePlayback(transport, above: 10, timeout: 45, "The visible fixture must play beyond the seek target.")

        let toggle = app.buttons["playerToggle"]
        let rail = app.descendants(matching: .any)["playbackProgress"].firstMatch
        let style = app.buttons["lyricStyleMenu"]
        for control in [toggle, rail, style] {
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            XCTAssertTrue(app.frame.contains(control.frame))
            XCTAssertFalse(originalVideoFrame.intersects(control.frame))
        }
        capture(app, name: "Compact-YouTube-SE-large-text-playback")

        toggle.tap()
        let stopped = expectation(for: NSPredicate(format: "label == %@", "播放"), evaluatedWith: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 15), .completed)
        // Seek within the fixture's final lyric cue (3–8 seconds).
        rail.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: 0.5)).tap()
        let sought = expectation(for: NSPredicate { _, _ in
            let value = (transport.value as? String ?? "").split(separator: "|")
            guard value.count == 2, value[1] == "paused", let time = Double(value[0]) else { return false }
            return time > 4 && time < 7.8
        }, evaluatedWith: transport)
        XCTAssertEqual(XCTWaiter.wait(for: [sought], timeout: 18), .completed,
                       "The paused iframe should acknowledge the seek. Got \(String(describing: transport.value)).")

        style.tap()
        let mistOption = app.buttons["霧盞"]
        XCTAssertTrue(mistOption.waitForExistence(timeout: 10)); mistOption.tap()
        let details = app.scrollViews["compactPlaybackDetails"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        let progressFrame = rail.frame
        let title = details.staticTexts["JANE DOE"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let titleY = title.frame.minY
        details.swipeUp()
        XCTAssertTrue(!title.isHittable || title.frame.minY < titleY, "Song details should scroll below the fixed player.")
        let line = details.descendants(matching: .any)["mistLyricCurrentLine"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        func lyricOnScreen() -> Bool {
            let frame = line.frame
            return !frame.isEmpty && details.frame.insetBy(dx: -1, dy: -1).contains(frame)
        }
        for _ in 0..<2 where !lyricOnScreen() { details.swipeUp() }
        XCTAssertTrue(lyricOnScreen(), "The synchronized lyric must fit entirely inside the details viewport.")
        XCTAssertEqual(line.label, "風聲")
        XCTAssertEqual(video.frame, originalVideoFrame)
        XCTAssertEqual(rail.frame, progressFrame)
        XCTAssertTrue(toggle.isHittable)
        capture(app, name: "Compact-YouTube-SE-large-text-lyrics")
    }

    func testRecordedSongsUseVisibleFallbackWithSharedArtworkAndTimedLyrics() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--youtube-sync-fixture", "--youtube-sync-reset", "--youtube-artwork-reset",
                               "--syllume-recording-regression", "--youtube-playback-fixture", "--subtitle-fixture", "--subtitle-reset",
                               "--presentation-reset"]
        // Begin with artwork before launching the heavier lyric renderer; the picker stays editable.
        app.launchEnvironment["SYLLUME_TEST_INITIAL_DISPLAY_MODE"] = "cover"
        app.launch()
        app.segmentedControls.buttons["YouTube"].tap()
        let liked = app.buttons["youtubePlaylist-liked"]
        XCTAssertTrue(liked.waitForExistence(timeout: 10)); liked.tap()
        let jane = app.buttons["youtubeSong-recording-jane"]
        XCTAssertTrue(jane.waitForExistence(timeout: 15)); jane.tap()
        let toggle = app.buttons["playerToggle"]
        let video = app.descendants(matching: .any)["youtubeEmbeddedPlayer"].firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["playerArtwork"].firstMatch.waitForExistence(timeout: 10))

        app.buttons["關閉播放畫面"].tap()
        let mini = app.buttons["openMiniPlayer"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        XCTAssertEqual(mini.value as? String, "已載入歌曲封面")
        mini.tap()
        XCTAssertTrue(app.descendants(matching: .any)["playerArtwork"].firstMatch.waitForExistence(timeout: 15))
        selectPlaybackMode("歌詞", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["nowPlayingThumbnail"].firstMatch.waitForExistence(timeout: 10))
        assertLyric("頭髮發現", in: app)
        XCTAssertEqual(app.buttons["lyricLine-0"].value as? String, "GenSenRounded2JP-M")

        let transport = app.staticTexts["youtubeTransportProbe"]
        func playAndVerify(_ song: String, mode: String, stageID: String) {
            XCTAssertTrue(video.waitForExistence(timeout: 15), song)
            if toggle.label == "播放" { toggle.tap() }
            XCTAssertGreaterThanOrEqual(video.frame.width, 200, song)
            XCTAssertGreaterThanOrEqual(video.frame.height, 200, song)
            waitForYouTubePlayback(transport, above: 0.5, timeout: 90, "Expected \(song) to play.")
            selectPlaybackMode(mode, in: app)
            let stage = app.staticTexts[stageID]
            let renderedTime = NSPredicate(format: "value MATCHES %@", #"(0\.[5-9][0-9]*|[1-9][0-9]*\.[0-9]+)\|playing\|GenSenRounded2JP-M"#)
            let rendering = expectation(for: renderedTime, evaluatedWith: stage)
            XCTAssertEqual(XCTWaiter.wait(for: [rendering], timeout: 120), .completed, "\(song) \(mode): \(String(describing: stage.value))")
            XCTAssertGreaterThan(probeTime(stage), 0.5, song)
            let button = toggle.frame
            let screen = app.frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: button.midX - screen.minX, dy: button.midY - screen.minY)).tap()
            let transportPaused = expectation(for: NSPredicate(format: "value ENDSWITH %@", "|paused"), evaluatedWith: transport)
            XCTAssertEqual(XCTWaiter.wait(for: [transportPaused], timeout: 30), .completed,
                           "\(song) must pause its media clock before the lyric clock is compared.")
            let paused = expectation(for: NSPredicate(format: "value ENDSWITH %@", "|paused|GenSenRounded2JP-M"), evaluatedWith: stage)
            XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 35), .completed,
                           "\(song) \(mode) should freeze after media pauses: \(String(describing: stage.value))")
            let audio = probeTime(transport), animation = probeTime(stage)
            XCTAssertEqual(animation, audio, accuracy: 0.65, "\(song) \(mode) follows the video clock")
            wait(0.7)
            XCTAssertEqual(probeTime(transport), audio, accuracy: 0.20)
            XCTAssertEqual(probeTime(stage), animation, accuracy: 0.12)
        }
        playAndVerify("JANE DOE", mode: "商籟", stageID: "syllumeSonnetClockProbe")
        app.buttons["播放佇列"].tap()
        let janeQueue = app.buttons["trackRow-recording-jane"], lemonQueue = app.buttons["trackRow-recording-lemon"]
        for row in [janeQueue, lemonQueue] {
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            let cover = expectation(for: NSPredicate(format: "value == %@", "已載入歌曲封面"), evaluatedWith: row)
            XCTAssertEqual(XCTWaiter.wait(for: [cover], timeout: 10), .completed)
        }
        capture(app, name: "Recorded-songs-queue-artwork")
        lemonQueue.tap()
        XCTAssertTrue(lemonQueue.waitForNonExistence(timeout: 15), "The playback queue must finish dismissing.")
        XCTAssertTrue(app.staticTexts["Lemon"].waitForExistence(timeout: 15))
        XCTAssertTrue(video.waitForExistence(timeout: 15), "Lemon rejects the short sample and switches to the original video")
        playAndVerify("Lemon", mode: "繪光", stageID: "syllumeLumiereClockProbe")
        capture(app, name: "Recorded-songs-Lemon-visible-fallback")
    }

    func testDeveloperDiagnosticsProducesEvidenceAndReport() throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["--diagnostics-ui-fixture", "--presentation-reset"]
        app.launch()
        app.buttons["Syllume 設定"].tap()
        let entry = app.buttons["developerDiagnostics"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.staticTexts["SYLLUME DIAGNOSTICS"].waitForExistence(timeout: 10))
        let run = app.buttons["diagnosticsRunAll"]
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        run.tap()
        let reportProbe = app.staticTexts["diagnosticsFixtureJSON"]
        XCTAssertTrue(reportProbe.waitForExistence(timeout: 180))
        let text = try XCTUnwrap(reportProbe.value as? String)
        let data = Data(text.utf8)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Syllume-Diagnostics-Simulator-Fixture"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(report["environment"] as? String, "ciFixture")
        XCTAssertEqual(report["schemaVersion"] as? Int, 1)
        let areas = try XCTUnwrap(report["results"] as? [[String: Any]])
        XCTAssertEqual(Set(areas.compactMap { $0["area"] as? String }), ["google", "captions", "audio", "animation", "device"])
        let checks = areas.flatMap { $0["checks"] as? [[String: Any]] ?? [] }
        for id in ["google.fixture", "captions.opencc", "captions.offset", "audio.bundled", "audio.retry",
                   "animation.nativeFont", "animation.sonnet.init", "animation.sonnet.font", "animation.sonnet.clock",
                   "animation.lumiere.init", "animation.lumiere.font", "animation.lumiere.clock"] {
            let check = checks.first { $0["id"] as? String == id }
            XCTAssertEqual(check?["state"] as? String, "passed", "\(id): \(String(describing: check))")
        }
        let device = areas.first { $0["area"] as? String == "device" }
        XCTAssertGreaterThan(device?["elapsedMs"] as? Int ?? 0, 0)
        for id in ["audio.currentClock", "device.transport", "captions.live"] {
            XCTAssertEqual(checks.first { $0["id"] as? String == id }?["state"] as? String, "unverifiable", id)
        }
        let sample = checks.first { $0["id"] as? String == "audio.bundled" }?["metrics"] as? [String: Double]
        XCTAssertGreaterThan(sample?["observedClock_s"] ?? 0, 0)
        XCTAssertLessThanOrEqual(sample?["pauseDrift_s"] ?? 1, 0.1)
        XCTAssertLessThanOrEqual(sample?["seekError_s"] ?? 1, 0.08)
        XCTAssertFalse(checks.contains { $0["evidence"] as? String == "liveNetwork" && $0["state"] as? String == "passed" })
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

    @discardableResult
    private func waitForPausedNativeClock(_ probe: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> Double {
        var pausedTime: Double?
        let paused = expectation(for: NSPredicate { _, _ in
            let fields = (probe.value as? String ?? "").split(separator: "|")
            guard fields.count == 2, let time = Double(fields[0]), time.isFinite, fields[1] == "0.0" else { return false }
            pausedTime = time
            return true
        }, evaluatedWith: probe)
        let result = XCTWaiter.wait(for: [paused], timeout: 20)
        XCTAssertEqual(result, .completed, "Expected a finite paused AVPlayer clock, got \(String(describing: probe.value))", file: file, line: line)
        return pausedTime ?? -1
    }

    @discardableResult
    private func waitForYouTubePlayback(_ transport: XCUIElement, above minimum: Double = 0,
                                        below maximum: Double = .infinity, timeout: TimeInterval,
                                        _ message: String, file: StaticString = #filePath, line: UInt = #line) -> Double {
        var matchedTime: Double?
        var observedValues: [String] = []
        let advancing = expectation(for: NSPredicate { _, _ in
            let value = transport.value as? String ?? "missing"
            observedValues.append(value)
            let fields = value.split(separator: "|")
            // The model reports playing once it has observed advancement from the active media.
            guard fields.count == 2, fields[1] == "playing", let time = Double(fields[0]),
                  time > minimum, time < maximum else { return false }
            matchedTime = time
            return true
        }, evaluatedWith: transport)
        let result = XCTWaiter.wait(for: [advancing], timeout: timeout)
        let samples = observedValues.suffix(8).joined(separator: ", ")
        XCTAssertEqual(result, .completed, "\(message) Media clock samples: \(samples)", file: file, line: line)
        print("YouTube fixture media clock: \(samples)")
        return matchedTime ?? -1
    }

    private func selectPlaybackMode(_ title: String, in app: XCUIApplication,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let mode = app.segmentedControls.buttons[title]
        let hittable = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: mode)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 15), .completed, file: file, line: line)
        mode.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
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
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 15), .completed,
                       "\(identifier): expected \(target), got \(String(describing: control.value))")
    }

    private func assertLyric(_ text: String, in app: XCUIApplication, timeout: TimeInterval = 15,
                             file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons["lyricLine-0"]
        let matches = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: row)
        let result = XCTWaiter.wait(for: [matches], timeout: timeout)
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
