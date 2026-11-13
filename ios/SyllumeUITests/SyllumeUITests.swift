import XCTest

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
        let lumiere = app.descendants(matching: .any)["syllumeLumiereStage"].firstMatch
        XCTAssertTrue(lumiere.waitForExistence(timeout: 20))
        let lumiereReady = expectation(for: NSPredicate(format: "value == %@", "已就緒 · GenSenRounded2JP-M"), evaluatedWith: lumiere)
        XCTAssertEqual(XCTWaiter.wait(for: [lumiereReady], timeout: 120), .completed, "Lumiere: \(String(describing: lumiere.value))")
        XCTAssertGreaterThan(lumiere.frame.height, app.frame.height * 0.8)
        capture(app, name: "Lumiere-paused")
        // The animated WebKit background can delay an accessibility hit-test on a busy runner.
        // Tap the visible control at its measured center, then verify the native playback clock stopped.
        let frame = toggle.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertTrue(app.frame.contains(center))
        let pausePoint = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: center.x - app.frame.minX, dy: center.y - app.frame.minY))
        toggle.tap()
        let resumed = expectation(for: NSPredicate(format: "label == %@", "暫停"), evaluatedWith: toggle)
        wait(for: [resumed], timeout: 10)
        wait(2)
        capture(app, name: "Lumiere-playing")
        pausePoint.tap()
        let lumierePaused = expectation(for: NSPredicate(format: "label == %@", "播放"), evaluatedWith: toggle)
        wait(for: [lumierePaused], timeout: 10)
        XCTAssertTrue((mediaProbe.value as? String ?? "").hasSuffix("|0.0"))
        let lumierePausedTime = probeTime(mediaProbe)
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
        capture(app, name: "Syllume-cover-with-unavailable-audio")
        app.terminate()
        app.launchArguments = ["--youtube-sync-fixture", "--youtube-artwork-offline", "--youtube-unavailable-audio-fixture",
                               "--subtitle-fixture", "-Folia.LyricDisplayMode", "cover"]
        for attempt in 1...2 {
            app.launch()
            app.segmentedControls.buttons["YouTube"].tap()
            XCTAssertTrue(song.waitForExistence(timeout: 15)); song.tap()
            XCTAssertTrue(artwork.waitForExistence(timeout: 10), "Cached cover after offline launch \(attempt)")
            capture(app, name: "Syllume-cover-cached-after-relaunch-\(attempt)")
            app.terminate()
        }
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
        let audio = app.buttons["youtubeSong-fixture-row"]
        XCTAssertTrue(audio.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["syncYouTubePlaylist"].waitForExistence(timeout: 15))
        XCTAssertEqual(audio.value as? String, "點歌時搜尋音源")
        let confirm = app.buttons["confirmPlaylistDownload"]
        let download = app.buttons["下載音樂"].firstMatch
        func openConfirmation() {
            let ready = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: audio)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
            // Hold over the leading artwork where the visible row content begins.
            audio.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).press(forDuration: 1.5)
            let menuShown = download.waitForExistence(timeout: 15)
            if !menuShown { capture(app, name: "Download-context-menu-missing") }
            XCTAssertTrue(menuShown, "Long press must open the song's context menu.")
            download.tap()
            XCTAssertTrue(confirm.waitForExistence(timeout: 20))
        }
        openConfirmation()
        app.buttons["cancelPlaylistDownload"].tap()
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
        let probe = app.staticTexts["localTransportProbe"]
        for fromMini in [false, true] {
            XCTAssertTrue(external.waitForExistence(timeout: 10)); external.tap()
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(miniToggle.waitForExistence(timeout: 10))
            XCTAssertEqual(miniToggle.label, "播放")
            if fromMini { miniToggle.tap() }
            mini.tap()
            XCTAssertTrue(probe.waitForExistence(timeout: 10))
            if !fromMini {
                let paused = expectation(for: NSPredicate(format: "value ENDSWITH %@", "|0.0"), evaluatedWith: probe)
                XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 10), .completed)
                fullToggle.tap()
            }
            let playing = expectation(for: NSPredicate { _, _ in
                self.probeTime(probe) > 0.2 && (probe.value as? String ?? "").hasSuffix("|1.0")
            }, evaluatedWith: probe)
            XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 15), .completed,
                           "Expected AVPlayer playback after returning from the external handoff.")
            close.tap()
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
        let beforeQueue = waitForAdvancingYouTubeClock(transport, above: 25, timeout: 55,
                                                     "Expected actual playback before selecting the current queue row.")
        app.buttons["播放佇列"].tap()
        let current = app.buttons["trackRow-recording-jane"]
        XCTAssertTrue(current.waitForExistence(timeout: 10)); current.tap()
        // The media fixture has a continuous timeline. A lower, advancing clock demonstrates a restart.
        waitForAdvancingYouTubeClock(transport, below: beforeQueue - 2, timeout: 35,
                                     "Selecting the current queue row must restart playback from \(beforeQueue)s.")
    }

    func testYouTubeSongAutomaticallyPlaysVisibleOriginal() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--youtube-sync-fixture", "--youtube-sync-reset", "--youtube-device-playback-regression",
                               "--youtube-playback-fixture", "--subtitle-fixture", "-Folia.LyricDisplayMode", "cover"]
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
        let beforeClosing = waitForAdvancingYouTubeClock(transport, above: 10, timeout: 40,
                                                       "The song tap must start playback without a second action.")
        XCTAssertTrue(app.staticTexts["YouTube · 官方播放器"].exists)

        app.buttons["關閉播放畫面"].tap()
        let mini = app.buttons["miniPlayerToggle"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        let paused = expectation(for: NSPredicate(format: "label == %@", "播放"), evaluatedWith: mini)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 10), .completed)
        mini.tap()
        XCTAssertTrue(video.waitForExistence(timeout: 15))
        var resumeSamples: [String] = []
        let resumed = expectation(for: NSPredicate { _, _ in
            let value = transport.value as? String ?? "missing"
            resumeSamples.append(value)
            let fields = value.split(separator: "|")
            // The playback model reports playing after the reopened media clock advances.
            guard fields.count == 2, fields[1] == "playing", let time = Double(fields[0]) else { return false }
            return time > beforeClosing + 0.5
        }, evaluatedWith: transport)
        let resumedResult = XCTWaiter.wait(for: [resumed], timeout: 40)
        let resumeEvidence = resumeSamples.suffix(8).joined(separator: ", ")
        XCTAssertEqual(resumedResult, .completed,
                       "Expected the reopened media to play past \(beforeClosing)s. Samples: \(resumeEvidence)")
        print("YouTube fixture resume clock: \(resumeEvidence)")
        capture(app, name: "HELP-YouTube-visible-playback")
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
        app.buttons["播放佇列"].tap()
        let janeQueue = app.buttons["trackRow-recording-jane"], lemonQueue = app.buttons["trackRow-recording-lemon"]
        for row in [janeQueue, lemonQueue] {
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            let cover = expectation(for: NSPredicate(format: "value == %@", "已載入歌曲封面"), evaluatedWith: row)
            XCTAssertEqual(XCTWaiter.wait(for: [cover], timeout: 10), .completed)
        }
        capture(app, name: "Recorded-songs-queue-artwork")
        app.buttons["完成"].tap()
        app.segmentedControls.buttons["歌詞"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["nowPlayingThumbnail"].firstMatch.waitForExistence(timeout: 10))
        assertLyric("頭髮發現", in: app)
        XCTAssertEqual(app.buttons["lyricLine-0"].value as? String, "GenSenRounded2JP-M")

        let transport = app.staticTexts["youtubeTransportProbe"]
        func playAndVerify(_ song: String, mode: String, stageID: String) {
            XCTAssertTrue(video.waitForExistence(timeout: 15), song)
            if toggle.label == "播放" { toggle.tap() }
            XCTAssertGreaterThanOrEqual(video.frame.width, 200, song)
            XCTAssertGreaterThanOrEqual(video.frame.height, 200, song)
            // Use one accessibility snapshot for both the real media time and the play state.
            let hasAdvanced = NSPredicate(format: "value MATCHES %@", #"(0\.[5-9][0-9]*|[1-9][0-9]*\.[0-9]+)\|playing"#)
            let advancing = expectation(for: hasAdvanced, evaluatedWith: transport)
            XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 90), .completed, "\(song): \(String(describing: transport.value))")
            app.segmentedControls.buttons[mode].tap()
            let stage = app.staticTexts[stageID]
            let renderedTime = NSPredicate(format: "value MATCHES %@", #"(0\.[5-9][0-9]*|[1-9][0-9]*\.[0-9]+)\|playing\|GenSenRounded2JP-M"#)
            let rendering = expectation(for: renderedTime, evaluatedWith: stage)
            XCTAssertEqual(XCTWaiter.wait(for: [rendering], timeout: 120), .completed, "\(song) \(mode): \(String(describing: stage.value))")
            XCTAssertGreaterThan(probeTime(stage), 0.5, song)
            let button = toggle.frame
            let screen = app.frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: button.midX - screen.minX, dy: button.midY - screen.minY)).tap()
            let paused = expectation(for: NSPredicate(format: "value ENDSWITH %@", "|paused|GenSenRounded2JP-M"), evaluatedWith: stage)
            XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 15), .completed)
            let audio = probeTime(transport), animation = probeTime(stage)
            XCTAssertEqual(animation, audio, accuracy: 0.65, "\(song) \(mode) follows the video clock")
            wait(0.7)
            XCTAssertEqual(probeTime(transport), audio, accuracy: 0.20)
            XCTAssertEqual(probeTime(stage), animation, accuracy: 0.12)
        }
        playAndVerify("JANE DOE", mode: "商籟", stageID: "syllumeSonnetClockProbe")
        app.buttons["播放佇列"].tap()
        XCTAssertTrue(lemonQueue.waitForExistence(timeout: 10)); lemonQueue.tap()
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
    private func waitForAdvancingYouTubeClock(_ transport: XCUIElement, above minimum: Double = 0,
                                             below maximum: Double = .infinity, timeout: TimeInterval,
                                             _ message: String, file: StaticString = #filePath, line: UInt = #line)
        -> Double {
        var previousTime: Double?
        var observedValues: [String] = []
        let advancing = expectation(for: NSPredicate { _, _ in
            let value = transport.value as? String ?? "missing"
            observedValues.append(value)
            let fields = value.split(separator: "|")
            guard fields.count == 2, fields[1] == "playing", let time = Double(fields[0]) else {
                previousTime = nil
                return false
            }
            guard time > minimum, time < maximum else {
                previousTime = nil
                return false
            }
            let advanced = previousTime.map { time - $0 >= 0.1 } ?? false
            previousTime = time
            return advanced
        }, evaluatedWith: transport)
        let result = XCTWaiter.wait(for: [advancing], timeout: timeout)
        let samples = observedValues.suffix(8).joined(separator: ", ")
        XCTAssertEqual(result, .completed, "\(message) Media clock samples: \(samples)", file: file, line: line)
        print("YouTube fixture media clock: \(samples)")
        return previousTime ?? -1
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
