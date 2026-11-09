@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import UIKit

@MainActor
struct DiagnosticProbes {
    let inputs: DiagnosticsInputs

    private static let captionVideo = "RCXjG2tsojs"
    private static let helpVideo = "z2tDtdHHAHg"

    func google() async -> [DiagnosticCheck] {
        if inputs.fixture {
            let page = #"{"nextPageToken":"next","items":[{"id":"PLFixture","snippet":{"title":"Fixture"}}]}"#
            let decoded = try? PlatformLibrary.decode(Data(page.utf8), platform: .youtube, collection: .playlists)
            let state: DiagnosticState = decoded?.entries.count == 1 && decoded?.next == "next" ? .passed : .failed
            return [DiagnosticCheck("google.fixture", "歌單回應與分頁解析", state, .simulatedInput),
                    skipped("google.live", "真實 Google 授權與更新", .liveNetwork, .noData)]
        }
        let connection = inputs.youtube
        if let issue = connection.googleConfiguration.issue {
            let note: String
            switch issue {
            case .missing: note = "此 IPA 缺少維護者 Google 設定。"
            case .invalidClient: note = "維護者 OAuth Client ID 格式錯誤。"
            case .bundleMismatch: note = "側載後的 App 識別碼與 Google 登記不符。"
            case .missingCallback: note = "此 IPA 缺少 OAuth 回呼設定。"
            }
            return [DiagnosticCheck("google.configuration", "Google OAuth 設定", .failed, .operatingSystem,
                                    problem: DiagnosticProblem(code: .configuration), note: note),
                    skipped("google.live", "真實歌單與授權更新", .liveNetwork, .configuration)]
        }
        var checks = [DiagnosticCheck("google.configuration", "Google OAuth 設定", .passed, .operatingSystem)]
        guard connection.connected else {
            checks.append(skipped("google.live", "真實歌單與授權更新", .liveNetwork, .signedOut,
                                  note: "到 YouTube → 帳號，親自完成 Google 登入後重試。"))
            return checks
        }
        checks.append(DiagnosticCheck("google.credential", "鑰匙圈授權狀態", .passed, .operatingSystem,
                                      note: "已讀到目前 App 的授權，效力由後續 API 呼叫確認。"))

        let playlists = await page("google.playlists", "我的歌單 API", collection: .playlists)
        checks += playlists.checks
        if let first = playlists.entries.first {
            checks += await page("google.playlistItems", "選定歌單歌曲", collection: .playlist(first.id)).checks
        } else {
            checks.append(skipped("google.playlistItems", "選定歌單歌曲", .liveNetwork, .noData))
        }
        checks += await page("google.liked", "喜歡的影片", collection: .liked).checks

        let start = Date()
        do {
            try Task.checkCancellation()
            try await PlaybackLookup.within(.seconds(16)) { try await connection.verifyGoogleRefresh() }
            checks.append(DiagnosticCheck("google.refresh", "以刷新權杖更新並重讀 API", .passed, .liveNetwork, since: start))
        } catch {
            checks.append(externalFailure("google.refresh", "以刷新權杖更新並重讀 API", error, since: start))
        }
        return checks
    }

    private func page(_ key: String, _ title: String, collection: LibraryCollection) async -> (checks: [DiagnosticCheck], entries: [LibraryEntry]) {
        let connection = inputs.youtube
        let start = Date()
        do {
            try Task.checkCancellation()
            let first = try await PlaybackLookup.within(.seconds(10)) { try await connection.page(collection, cursor: nil) }
            let check = DiagnosticCheck(key, title, .passed, .liveNetwork, since: start, metrics: ["firstPageEntries": Double(first.entries.count)])
            guard let cursor = first.next else {
                return ([check, skipped(key + ".next", title + "第二頁", .liveNetwork, .noData,
                                        note: "這次 API 回覆沒有下一頁。")], first.entries)
            }
            let nextStart = Date()
            do {
                let next = try await PlaybackLookup.within(.seconds(10)) { try await connection.page(collection, cursor: cursor) }
                guard next.next != cursor else { throw DiagnosticProblem(code: .invalidResponse) }
                return ([check, DiagnosticCheck(key + ".next", title + "第二頁", .passed, .liveNetwork, since: nextStart,
                                                 metrics: ["secondPageEntries": Double(next.entries.count)])], first.entries)
            } catch {
                return ([check, externalFailure(key + ".next", title + "第二頁", error, since: nextStart)], first.entries)
            }
        } catch {
            return ([externalFailure(key, title, error, since: start)], [])
        }
    }

    func captions() async -> [DiagnosticCheck] {
        var checks: [DiagnosticCheck] = []
        let sample = (0..<4).map { index in
            LyricLine(startTime: Double(index * 2 + 1), endTime: Double(index * 2 + 2),
                      fullText: "あの日のこと \(index)", translation: "头发和风里的回声")
        }
        let original = sample.map { line in LyricLine(startTime: line.startTime + 0.4, endTime: line.endTime + 0.4, fullText: line.fullText) }
        let aligned = YouTubeCaptionDecoders.alignTranslation(sample, to: original)
        let started = Date()
        do {
            let translated = try await NativeSubtitleConverter.shared.convert(aligned.lines, preferences: SubtitlePreferences())
            let identicalClock = translated.map(\.startTime) == original.map(\.startTime)
            let converted = translated.first?.translationText == "頭髮和風裡的回聲" && translated.map(\.fullText) == original.map(\.fullText)
            let good = aligned.aligned && identicalClock && converted
            checks.append(DiagnosticCheck("captions.opencc", "OpenCC、雙語對齊與原文保留", good ? .passed : .failed, .simulatedInput,
                since: started, problem: good ? nil : DiagnosticProblem(code: .timeline), metrics: ["convertedCues": Double(translated.count)]))
        } catch {
            checks.append(DiagnosticCheck("captions.opencc", "OpenCC、雙語對齊與原文保留", .failed, .simulatedInput, since: started,
                                         problem: DiagnosticProblem.classify(error, fallback: .engine)))
        }

        let offset = LyricTimingOffset.adjusted(0, by: 0.4)
        let timed = LyricTimeline(lines: aligned.lines)
        let moved = timed.activeIndex(at: LyricTimingOffset.displayed(position: 1.2, offset: offset)) == 0
            && timed.activeIndex(at: 1.2) == nil
        checks.append(DiagnosticCheck("captions.offset", "手動偏移與播放時間對照", moved ? .passed : .failed, .simulatedInput,
                                      problem: moved ? nil : DiagnosticProblem(code: .timeline)))
        guard !inputs.fixture else {
            return checks + [skipped("captions.live", "JANE DOE 真實 CC", .liveNetwork, .noData)]
        }

        let startedLive = Date()
        do {
            let live = try await PlaybackLookup.within(.seconds(21)) {
                try await SubtitleNetwork.shared.inspectCaptions(Self.captionVideo)
            }
            checks.append(DiagnosticCheck("captions.tracks", "JANE DOE 中文與日文字幕軌",
                live.chineseTracks > 0 && live.japaneseTracks > 0 ? .passed : .partial, .liveNetwork, since: startedLive,
                note: "影片 RCXjG2tsojs。歷史上的 36 段僅供比較。",
                metrics: ["chineseManualTracks": Double(live.chineseTracks), "japaneseTracks": Double(live.japaneseTracks),
                          "japaneseCues": live.japaneseCues.map(Double.init)].compactMapValues { $0 }))
            if let problem = live.problem {
                checks.append(externalFailure("captions.live", "JANE DOE 真實 CC", problem, since: startedLive))
            } else {
                var seen = Set<String>()
                let duplicates = live.lines.filter { !seen.insert("\($0.startTime)|\($0.fullText)|\($0.translation ?? "")").inserted }.count
                let malformed = live.lines.filter { $0.startTime < 0 || $0.endTime <= $0.startTime ||
                    $0.fullText.contains("\u{FFFD}") || $0.translation?.contains("\u{FFFD}") == true }.count
                let clockOK = !live.lines.isEmpty && duplicates == 0 && malformed == 0
                checks.append(DiagnosticCheck("captions.live", "JANE DOE 真實 CC 內容與時間戳", clockOK ? .passed : .partial, .liveNetwork,
                    since: startedLive, problem: clockOK ? nil : DiagnosticProblem(code: .invalidResponse),
                    metrics: ["cues": Double(live.lines.count), "duplicateCues": Double(duplicates), "malformedCues": Double(malformed)]))
            }
        } catch { checks.append(externalFailure("captions.live", "JANE DOE 真實 CC", error, since: startedLive)) }
        checks.append(skipped("captions.realAlignment", "JANE DOE 對照原曲音訊與逐句遺漏", .userMedia, .noData,
                              note: "需有可驗證的原曲音檔和正確參考字幕；實際語意及遺漏不能由段數判定。"))
        return checks
    }

    func audio() async -> [DiagnosticCheck] {
        if inputs.player.isPlaying {
            return [skipped("audio.busy", "音訊與解碼檢查", .observedPlayback, .appBusy, note: "暫停主播放器後可重試。")]
        }
        var checks: [DiagnosticCheck] = []
        if let demo = Bundle.main.url(forResource: "tide", withExtension: "m4a") {
            checks.append(await audioCheck("audio.bundled", "內建音檔的解碼與播放", url: demo, duration: 30, evidence: .bundledSample))
            checks.append(await interruptedCopy(demo))
        } else {
            checks.append(DiagnosticCheck("audio.bundled", "內建音檔的解碼與播放", .failed, .bundledSample,
                                          problem: DiagnosticProblem(code: .invalidMedia)))
        }
        let local = inputs.library.tracks.first { $0.id.hasPrefix("download-") && $0.duration != nil }
            ?? inputs.library.tracks.first { $0.duration != nil }
        if let local, let url = inputs.library.assetURL(for: local), let duration = local.duration {
            checks.append(await audioCheck("audio.local", "曲庫音檔離線重播", url: url, duration: duration, evidence: .userMedia))
        } else {
            checks.append(skipped("audio.local", "曲庫音檔離線重播", .userMedia, .noData))
        }
        guard !inputs.fixture, !Task.isCancelled else {
            return checks + [skipped("audio.live", "真實來源配對", .liveNetwork, .noData)]
        }

        let selected = inputs.useCurrentSong ? inputs.player.current?.playlistSong.flatMap {
            YouTubeVideo.validID($0.videoID) ? $0 : nil
        } : nil
        let videoID = selected?.videoID ?? Self.helpVideo
        guard let url = URL(string: "https://www.youtube.com/watch?v=" + videoID),
              var song = SyncedYouTubeSong(LibraryEntry(id: "diagnostics", title: selected?.title ?? "HELP!!",
                  subtitle: selected?.artist ?? "Kobo Kanaeru - Topic", url: url,
                  duration: selected?.duration ?? (videoID == Self.helpVideo ? 187 : nil))) else { return checks }
        let began = Date()
        do {
            let metadata = try await PlaybackLookup.within(.seconds(8)) {
                try await AudioDownloadService.shared.publicVideo(videoID)
            }
            if song.duration == nil { song.duration = metadata.duration }
            let comparable = DownloadSongMatch.sameDuration(song.duration, metadata.duration)
            checks.append(DiagnosticCheck("audio.youtube", "YouTube 影片的公開播放資料", comparable ? .passed : .partial, .liveNetwork,
                since: began, problem: comparable ? nil : DiagnosticProblem(code: .missingDuration),
                note: "這項驗證公開 metadata 與時長。實際 Syllume 開播結果可由播放事件紀錄驗證。",
                metrics: ["sourceDuration_s": metadata.duration]))
        } catch { checks.append(externalFailure("audio.youtube", "YouTube 影片的公開播放資料", error, since: began)) }
        if song.duration == nil { song = await inputs.youtube.playlistSongWithDuration(song) }

        let sources: [DiagnosticSource] = [.navidrome, .netease, .qq]
        for source in sources {
            if Task.isCancelled { break }
            if source == .navidrome && inputs.navidrome == nil {
                checks.append(skipped("audio.navidrome", "Navidrome 同版本配對", .liveNetwork, .signedOut))
                continue
            }
            checks += await provider(source, song: song)
        }
        return checks
    }

    private func provider(_ source: DiagnosticSource, song: SyncedYouTubeSong) async -> [DiagnosticCheck] {
        let start = Date()
        let key = "audio." + source.rawValue
        let title = source.title + "同版本配對"
        let account = inputs.navidrome
        do {
            let attempt = try await PlaybackLookup.within(.seconds(14)) {
                await AudioDownloadService.shared.streamingSource(source, song: song, account: account)
            }
            if let problem = attempt.problem { return [externalFailure(key, title, problem, since: start)] }
            guard let best = attempt.candidates.sorted(by: DownloadAudioCandidate.preferredForStreaming).first else {
                return [skipped(key, title, .liveNetwork, .noMatch)]
            }
            var checks = [DiagnosticCheck(key, title, .passed, .liveNetwork, since: start,
                note: "沿用正式播放器的歌名、演出者、時長與版本比對。",
                metrics: ["matchedCandidates": Double(attempt.candidates.count), "expectedDuration_s": best.duration])]
            guard inputs.allowMedia else {
                return checks + [skipped(key + ".media", source.title + "實際音訊與下載", .liveNetwork, .authorizationRequired)]
            }
            checks.append(await audioCheck(key + ".media", source.title + "實際音訊播放",
                                           url: best.streamingURL ?? best.url, duration: best.duration, evidence: .liveNetwork))
            let downloadedAt = Date()
            do {
                let local = try await PlaybackLookup.within(.seconds(18)) {
                    try await AudioDownloadService.shared.download(best, limit: 15_000_000)
                }
                defer { try? FileManager.default.removeItem(at: local) }
                let test = await audioCheck(key + ".download", source.title + "下載、完整解碼與離線重播",
                                            url: local, duration: best.duration, evidence: .liveNetwork)
                checks.append(DiagnosticCheck(test.id, test.title, test.state, test.evidence, since: downloadedAt,
                    problem: test.problem, note: test.note, metrics: test.metrics))
            } catch { checks.append(externalFailure(key + ".download", source.title + "下載與離線重播", error, since: downloadedAt)) }
            return checks
        } catch { return [externalFailure(key, title, error, since: start)] }
    }

    private func interruptedCopy(_ demo: URL) async -> DiagnosticCheck {
        let start = Date()
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let bytes = try Data(contentsOf: demo)
            try bytes.prefix(bytes.count * 3 / 5).write(to: file, options: .atomic)
            var acceptedTruncated = false
            do { _ = try await AudioIntegrity.inspect(file, expected: 30, decode: true); acceptedTruncated = true }
            catch { try Task.checkCancellation() }
            guard !acceptedTruncated else { throw DiagnosticProblem(code: .invalidMedia) }
            try bytes.write(to: file, options: .atomic)
            let test = await audioCheck("audio.retry", "中斷檔案拒收與完整重試", url: file, duration: 30, evidence: .simulatedInput)
            return DiagnosticCheck(test.id, test.title, test.state, test.evidence, since: start, problem: test.problem,
                note: "模擬傳輸截斷，再以完整檔案重試；不宣稱支援網路斷點續傳。", metrics: test.metrics)
        } catch {
            return DiagnosticCheck("audio.retry", "中斷檔案拒收與完整重試", .failed, .simulatedInput, since: start,
                                   problem: DiagnosticProblem.classify(error, fallback: .invalidMedia))
        }
    }

    private func audioCheck(_ key: String, _ title: String, url: URL, duration: Double, evidence: DiagnosticEvidence) async -> DiagnosticCheck {
        let start = Date()
        do {
            let asset = AVURLAsset(url: url)
            let length = try await AudioIntegrity.inspect(asset, expected: duration, decode: url.isFileURL, deadline: .seconds(8))
            var metrics = ["duration_s": length]
            if url.isFileURL, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                metrics["size_bytes"] = Double(size)
            }
            if let format = try await asset.loadTracks(withMediaType: .audio).first {
                if let rate = try? await format.load(.estimatedDataRate), rate > 0 { metrics["bitrate_bps"] = Double(rate) }
                if let descriptions = try? await format.load(.formatDescriptions), let first = descriptions.first,
                   let info = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee {
                    metrics["sampleRate_Hz"] = info.mSampleRate
                    metrics["channels"] = Double(info.mChannelsPerFrame)
                    metrics["formatFourCC"] = Double(info.mFormatID)
                    if info.mBitsPerChannel > 0 { metrics["bitsPerChannel"] = Double(info.mBitsPerChannel) }
                }
            }
            metrics.merge(try await mutedPlayback(asset)) { _, latest in latest }
            let extensionName = url.pathExtension.lowercased()
            let formatNote = ["m4a", "flac", "mp3", "aac", "wav", "aiff", "aif", "alac"].contains(extensionName) ? "容器副檔名 \(extensionName.uppercased())。" : nil
            return DiagnosticCheck(key, title, .passed, evidence, since: start, note: formatNote, metrics: metrics)
        } catch {
            if evidence == .liveNetwork { return externalFailure(key, title, error, since: start, fallback: .invalidMedia) }
            return DiagnosticCheck(key, title, .failed, evidence, since: start,
                                   problem: DiagnosticProblem.classify(error, fallback: .invalidMedia))
        }
    }

    private func mutedPlayback(_ asset: AVURLAsset) async throws -> [String: Double] {
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let start = ProcessInfo.processInfo.systemUptime
        player.play()
        while ProcessInfo.processInfo.systemUptime - start < 7 {
            try Task.checkCancellation()
            if let error = item.error { throw error }
            if player.currentTime().seconds > 0.12 && player.timeControlStatus == .playing {
                var metrics = ["playerFirstAudioClock_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000]
                if let event = item.accessLog()?.events.last, event.numberOfStalls >= 0 {
                    metrics["stalls"] = Double(event.numberOfStalls)
                }
                return metrics
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DiagnosticProblem(code: .timeout)
    }

    func animation(_ stage: DiagnosticStageProbe) async -> [DiagnosticCheck] {
        if inputs.player.isPlaying { return [skipped("animation.busy", "商籟與繪光", .observedPlayback, .appBusy)] }
        guard let file = Bundle.main.url(forResource: "tide", withExtension: "lrc"),
              let text = try? String(contentsOf: file, encoding: .utf8) else {
            return [DiagnosticCheck("animation.resources", "動畫測試資源", .failed, .bundledSample,
                                    problem: DiagnosticProblem(code: .engine))]
        }
        let timeline = LyricTimeline(lrc: text)
        var checks = await stage.inspect(.sonnet, timeline: timeline)
        if !Task.isCancelled { checks += await stage.inspect(.lumiere, timeline: timeline) }
        checks.append(skipped("animation.interactions", "真實音源同步、弱網與沉浸／背景切換", .observedPlayback, .noData,
                              note: "控制時鐘已取樣。要核對真實歌曲與系統切換，請開啟播放事件紀錄後操作。"))
        return checks
    }

    func device(since start: Date, counters before: [String: Double]) -> [DiagnosticCheck] {
        let after = DiagnosticsDevice.counters()
        let wall = Date().timeIntervalSince(start)
        var counters = after
        if let cpu = after["appCPU_s"], let previous = before["appCPU_s"], wall >= 0.2 {
            counters["appCPU_percent_oneCore"] = max(0, (cpu - previous) / wall * 100)
        }
        if let memory = after["appResidentMemory_MiB"], let previous = before["appResidentMemory_MiB"] {
            counters["appResidentChange_MiB"] = memory - previous
        }
        if let launch = DiagnosticsEvents.shared.firstViewMs { counters["appInitToFirstView_ms"] = launch }
        var checks = [DiagnosticCheck("device.process", "App 啟動、CPU 與記憶體取樣", counters.isEmpty ? .unverifiable : .passed, .operatingSystem,
            since: start, note: "啟動取樣從 App 初始化算到首頁出現；CPU 為本次觀測期間、記憶體為進程常駐量。", metrics: counters)]
        let events = DiagnosticsEvents.shared.snapshot
        let transport = inputs.player.diagnosticTransportMetrics
        let observed = !events.isEmpty || !transport.isEmpty
        let begin = events.filter { $0.kind == .playbackStarted }.first?.at
        let elapsed = begin.flatMap { first in events.last.map { $0.at.timeIntervalSince(first) } } ?? 0
        checks.append(DiagnosticCheck("device.transport", "實際播放緩衝與前後景事件", observed ? .partial : .unverifiable, .observedPlayback,
            problem: observed ? nil : DiagnosticProblem(code: .noData), note: "事件最多保留最近 96 筆。長時間穩定性以實際播放紀錄分析。",
            metrics: transport.merging(["events": Double(events.count), "observedSpan_s": elapsed,
                "backgroundTransitions": Double(events.filter { $0.kind == .background }.count),
                "interruptions": Double(events.filter { $0.kind == .audioInterruption }.count)]) { first, _ in first }))
        let system = DiagnosticsSystemMetrics.shared.metrics
        checks.append(DiagnosticCheck("device.metricKit", "MetricKit 系統效能與異常報告", system.isEmpty ? .unverifiable : .partial, .operatingSystem,
            problem: system.isEmpty ? DiagnosticProblem(code: .systemUnavailable) : nil,
            note: "需先開啟播放事件紀錄，系統提供資料後才可讀取。僅保留 Syllume 的堆疊位移。", metrics: system))
        let playing = DiagnosticsEvents.shared.observedPlaybackSeconds
        checks.append(DiagnosticCheck("device.longRun", "長時間播放觀測", playing >= 600 ? .partial : .unverifiable, .observedPlayback,
            problem: playing >= 600 ? nil : DiagnosticProblem(code: .noData),
            note: "開啟紀錄並正常播放至少 10 分鐘可比較播放秒數與中斷事件。這些取樣無法證明沒有卡頓或記憶體洩漏。",
            metrics: ["observedPlaying_s": playing]))
        checks.append(skipped("device.systemTotals", "系統全域 CPU 與精確 GPU 呈現幀數", .operatingSystem, .systemUnavailable))
        return checks
    }

    private func skipped(_ key: String, _ title: String, _ evidence: DiagnosticEvidence, _ code: DiagnosticCode, note: String? = nil) -> DiagnosticCheck {
        DiagnosticCheck(key, title, .unverifiable, evidence, problem: DiagnosticProblem(code: code), note: note)
    }

    private func externalFailure(_ key: String, _ title: String, _ error: Error, since start: Date,
                                 fallback: DiagnosticCode = .transport) -> DiagnosticCheck {
        DiagnosticCheck(key, title, .unverifiable, .liveNetwork, since: start,
                        problem: DiagnosticProblem.classify(error, fallback: fallback))
    }
}
