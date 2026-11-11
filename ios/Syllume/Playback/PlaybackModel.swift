import AVFoundation
import MediaPlayer
import Observation
import UIKit

// The queue uses AVPlayer for matched audio and the visible IFrame clock for a YouTube video.
@MainActor @Observable
final class PlaybackModel {
    private(set) var queue: [Track] = []
    private(set) var index: Int?
    private(set) var wantsPlayback = false
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var timeline = LyricTimeline(lines: []) { didSet { timelineRevision = UUID() } }
    private(set) var timelineRevision = UUID()
    private(set) var externalPlayback = false
    private(set) var artwork: UIImage?
    private(set) var lyricsLoading = false
    private(set) var error: String?
    private(set) var repeatQueue = false
    private(set) var lyricClockRunning = false
    private(set) var lyricOffset = 0.0
    private(set) var audioSource: String?
    private(set) var activeLocalTrackID: String?
    private(set) var embeddedVideo: YouTubePlayback?
    private(set) var offersVideoFallback = false
    private(set) var didAdvancePlayback = false
    private(set) var diagnosticPlaybackProblem: DiagnosticProblem?
    private(set) var diagnosticPlaybackDetails: String?
    private var nativeReady = false
    private var nativeHasAdvanced = false
    private var videoHasAdvanced = false
    @ObservationIgnored private var videoDeadline: Task<Void, Never>?
    @ObservationIgnored private var queuedVideoReplay: UUID?
    @ObservationIgnored private var videoSurfaceVisible = false
    @ObservationIgnored private var videoRequested = false
    @ObservationIgnored private var lyricReferenceDuration: Double?
    @ObservationIgnored private var manualLyrics = false

    var canSeek: Bool {
        if let embeddedVideo { return embeddedVideo.visible && embeddedVideo.duration > 0 }
        return nativeReady && duration > 0
    }
    var transportLabel: String { isBuffering && wantsPlayback ? "取消載入" : wantsPlayback ? "暫停" : "播放" }
    var transportIcon: String { isBuffering && wantsPlayback ? "stop.fill" : wantsPlayback ? "pause.fill" : "play.fill" }

    var diagnosticTransportMetrics: [String: Double] {
        guard current != nil else { return [:] }
        var metrics: [String: Double] = ["displayedClock_s": position, "sourceDuration_s": duration,
            "lyricCueCount": Double(timeline.lines.count), "manualLyricOffset_s": lyricOffset]
        if let embeddedVideo {
            if !embeddedVideo.isSeeking, let sampledTime = embeddedVideo.sampledTime {
                metrics["displayClockDifference_s"] = abs(position - sampledTime)
            }
            return metrics
        }
        guard player.currentItem != nil else { return metrics }
        let audio = player.currentTime().seconds
        if audio.isFinite, !seeking { metrics["displayClockDifference_s"] = abs(position - audio) }
        if let event = player.currentItem?.accessLog()?.events.last {
            for (key, value) in ["stalls": Double(event.numberOfStalls), "observedBitrate_bps": event.observedBitrate, "startup_s": event.startupTime]
                where value.isFinite && value >= 0 { metrics[key] = value }
        }
        return metrics
    }
    var lyricPosition: Double { LyricTimingOffset.displayed(position: position, offset: lyricOffset) }
    var subtitleInput: SubtitleInput? {
        guard let track = current else { return nil }
        let recording = activeRecording ?? catalogueTarget?.recordingMetadata ?? track.recording
        let originalID = track.playlistSong.flatMap { song -> String? in
            guard YouTubeVideo.validID(song.videoID) else { return nil }
            if activeRecording != nil, let originalDuration = catalogueTarget?.duration,
               abs(originalDuration - duration) > 2 { return nil }
            return song.videoID
        }
        return SubtitleInput(song: SubtitleSong(id: track.id, source: track.source.rawValue,
            title: recording?.title ?? track.title, artist: recording?.artist ?? track.artist ?? "",
            durationMs: (duration * 10).rounded() * 100, ref: recording?.ref,
            originVideoID: track.playlistSong == nil ? recording?.originVideoID : originalID,
            usesVideoClock: embeddedVideo == nil ? nil : true),
            revision: timelineRevision, loading: lyricsLoading)
    }

    var current: Track? { index.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    var canAdvance: Bool { index.map { $0 + 1 < queue.count || repeatQueue } ?? false }
    var handlesRemoteCommands: Bool {
        current != nil && !externalPlayback && embeddedVideo == nil && (current?.source != .catalogue || error == nil)
    }
    #if DEBUG
    var mediaProbe: String {
        // Observe the clock even in cover mode or when a downloaded track has no lyrics.
        _ = position; _ = isPlaying; _ = isBuffering
        return String(format: "%.3f|%.1f", player.currentTime().seconds, player.rate)
    }
    var nowPlayingProbe: String {
        _ = position; _ = artwork; _ = isPlaying
        let published = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let time = published?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? -1
        let rate = published?[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? -1
        let hasArtwork = published?[MPMediaItemPropertyArtwork] != nil
        return String(format: "%.1f|%.1f|%@", time, rate, hasArtwork ? "artwork" : "empty")
    }
    #endif

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let library: LocalLibrary
    @ObservationIgnored private var client: NavidromeClient?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var system: PlaybackSystem?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var seekGeneration = UUID()
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var streamTimeout: Task<Void, Never>?
    @ObservationIgnored private var startupTimeout: Task<Void, Never>?
    @ObservationIgnored private var youtubeConnection: PlatformConnection?
    private var catalogueTarget: SyncedYouTubeSong?
    @ObservationIgnored private var catalogueMetadataTask: Task<SyncedYouTubeSong, Never>?
    @ObservationIgnored private var catalogueVideoStatus: YouTubeVideoDetails.Status?
    @ObservationIgnored private var catalogueVideoProblem: DiagnosticProblem?
    @ObservationIgnored private var activeCatalogueSource: DiagnosticSource?
    private var catalogueHasStarted = false
    @ObservationIgnored private var resolveTicket = UUID()
    private var activeRecording: SubtitleSong?
    @ObservationIgnored private var account: NavidromeAccount?
    @ObservationIgnored private var candidates: [DownloadAudioCandidate] = []
    @ObservationIgnored private var searchedCatalogue = false
    @ObservationIgnored private var attemptedCatalogueSources: Set<DiagnosticSource> = []
    @ObservationIgnored private var triedLocal = false
    @ObservationIgnored private var sourceFailures: [(source: String, problem: DiagnosticProblem, elapsedMs: Int?)] = []
    @ObservationIgnored private var resumeAfterInterruption = false

    init(library: LocalLibrary) {
        self.library = library
        player.automaticallyWaitsToMinimizeStalling = true
        system = PlaybackSystem(model: self, player: player)
    }

    func play(_ tracks: [Track], from selected: Track, client: NavidromeClient? = nil, presentingVideo: Bool = false) {
        guard let index = tracks.firstIndex(of: selected) else { return }
        self.client = client
        queue = tracks
        load(index, requestingVideo: presentingVideo || videoSurfaceVisible)
    }

    func playPlaylist(_ songs: [SyncedYouTubeSong], from song: SyncedYouTubeSong,
                      bindings: [String: YouTubeAudioBinding], account: NavidromeAccount?, connection: PlatformConnection,
                      presentingVideo: Bool = true) {
        let tracks = songs.map { Self.playlistTrack($0, bindings: bindings) }
        guard let track = tracks.first(where: { $0.id == song.id }) else { return }
        self.account = account
        youtubeConnection = connection
        play(tracks, from: track, presentingVideo: presentingVideo)
    }

    func playNext(_ song: SyncedYouTubeSong, bindings: [String: YouTubeAudioBinding], account: NavidromeAccount?, connection: PlatformConnection) {
        if let index {
            self.account = account
            youtubeConnection = connection
            var track = Self.playlistTrack(song, bindings: bindings)
            if queue.contains(where: { $0.id == track.id }) {
                track = Track(id: UUID().uuidString, source: .catalogue, title: track.title, artist: track.artist,
                    album: nil, duration: track.duration, playlistSong: song, preferredLocalID: track.preferredLocalID)
            }
            queue.insert(track, at: index + 1)
            system?.updateCommands(model: self)
        } else {
            playPlaylist([song], from: song, bindings: bindings, account: account, connection: connection, presentingVideo: false)
        }
    }

    private static func playlistTrack(_ song: SyncedYouTubeSong, bindings: [String: YouTubeAudioBinding]) -> Track {
        Track(id: song.id, source: .catalogue, title: song.title, artist: song.artist, album: nil,
            duration: song.duration, playlistSong: song, preferredLocalID: bindings[song.videoID]?.trackID ?? song.localTrackID)
    }

    func adjustLyrics(by amount: Double) {
        guard let track = current, amount.isFinite else { return }
        lyricOffset = LyricTimingOffset.adjusted(lyricOffset, by: amount)
        UserDefaults.standard.set(lyricOffset, forKey: offsetKey(track))
    }

    private func offsetKey(_ track: Track) -> String {
        "folia.lyricOffset." + (track.playlistSong?.videoID ?? (track.source.rawValue + "." + track.id))
    }

    func toggle(inApp: Bool = false) {
        if inApp { reclaimPlayback() }
        if wantsPlayback { pause() }
        else if inApp, offersVideoFallback || embeddedVideo != nil { requestVideoPlayback() }
        else { resume() }
    }

    private func reclaimPlayback() {
        guard externalPlayback else { return }
        externalPlayback = false
        system?.updateCommands(model: self)
    }

    func resume() {
        guard !externalPlayback else { return }
        if let embeddedVideo {
            guard embeddedVideo.visible else { return }
            if embeddedVideo.error != nil, !embeddedVideo.didBlockAutoplay {
                embeddedVideo.retry()
                videoHasAdvanced = false
            } else {
                if embeddedVideo.didReachEnd { embeddedVideo.seek(to: 0) }
                embeddedVideo.resume()
            }
            refreshEmbeddedVideo()
            return
        }
        guard resolveTask == nil else { return }
        if let track = current, track.source == .catalogue, error == nil,
           player.currentItem == nil || player.currentItem?.status == .failed {
            resolveCatalogue(track)
        } else if let index, (error != nil || player.currentItem == nil), resolveTask == nil {
            load(index)
        } else {
            startCurrentItem()
        }
    }

    private func startCurrentItem() {
        guard let item = player.currentItem, item.status != .failed else { return }
        if duration > 0, position >= duration - 0.15 { seek(to: 0) }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            resumeAfterInterruption = false
            error = nil
            wantsPlayback = true
            player.play()
            refreshTransport()
        } catch {
            fail("無法啟用音訊。請檢查目前的音訊輸出。")
        }
    }

    func pause() {
        videoRequested = false
        if let embeddedVideo {
            embeddedVideo.pause()
            refreshEmbeddedVideo()
            return
        }
        if isPlaying { DiagnosticsEvents.shared.record(.playbackPaused) }
        resumeAfterInterruption = false
        player.pause()
        wantsPlayback = false
        streamTimeout?.cancel(); streamTimeout = nil
        startupTimeout?.cancel(); startupTimeout = nil
        if resolveTask != nil {
            resolveTicket = UUID(); resolveTask?.cancel(); resolveTask = nil
        }
        refreshTransport()
    }

    func useLyrics(_ record: LyricSearchRecord) {
        guard current != nil, let text = record.syncedLyrics else { return }
        lyricsTask?.cancel(); lyricsLoading = false
        manualLyrics = true
        lyricReferenceDuration = record.duration
        timeline = LyricTimeline(lrc: text).prepared(for: duration)
    }

    func pauseForExternalPlayback() {
        pause()
        setEmbeddedVideoVisible(false)
        externalPlayback = true
        system?.updateCommands(model: self)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func next() {
        guard let index, canAdvance else { return }
        load((index + 1) % queue.count)
    }

    func previous() {
        guard let index else { return }
        if position > 3 || index == 0 { seek(to: 0) }
        else { load(index - 1) }
    }

    func selectQueueItem(_ selected: Int) {
        guard queue.indices.contains(selected) else { return }
        guard selected == index else { load(selected, requestingVideo: true); return }
        reclaimPlayback()
        if let video = embeddedVideo, !video.visible {
            queuedVideoReplay = video.session
            return
        }
        seek(to: 0)
        if offersVideoFallback { requestVideoPlayback() }
        else { resume() }
    }

    func toggleRepeat() {
        repeatQueue.toggle()
        system?.updateCommands(model: self)
    }

    func seekToLyric(_ time: Double) { seek(to: time - lyricOffset) }

    func seek(to time: Double) {
        if let embeddedVideo {
            guard canSeek, time.isFinite else { return }
            DiagnosticsEvents.shared.record(.seek, source: .youtube)
            embeddedVideo.seek(to: time)
            refreshEmbeddedVideo()
            return
        }
        guard let item = player.currentItem, time.isFinite else { return }
        let target = duration > 0 ? min(duration, max(0, time)) : max(0, time)
        DiagnosticsEvents.shared.record(.seek)
        let revision = UUID()
        seekGeneration = revision
        seeking = true
        lyricClockRunning = false
        position = target
        let precise = CMTime(seconds: target, preferredTimescale: 600)
        item.seek(to: precise, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, seekGeneration == revision else { return }
                seeking = false
                let actual = player.currentTime().seconds
                if actual.isFinite { position = max(0, actual) }
                refreshTransport()
            }
        }
        publishNowPlaying()
    }

    func removeFromQueue(_ id: String) {
        guard let position = queue.firstIndex(where: { $0.source == .local && $0.id == id }), let index else { return }
        if position == index {
            clear()
            return
        }
        queue.remove(at: position)
        if position < index { self.index = index - 1 }
        system?.updateCommands(model: self)
    }

    func clearNavidrome() {
        account = nil
        if current?.source == .navidrome || audioSource?.hasPrefix("Navidrome") == true { clear() }
    }

    func reloadLocalLyrics(_ track: Track) {
        guard let index, current?.id == track.id || activeLocalTrackID == track.id else { return }
        if current?.source == .local { queue[index] = track }
        manualLyrics = false
        loadLyrics(track: track, recording: track.recording ?? activeRecording)
    }

    private func loadLyrics(track: Track, recording: SubtitleSong?, remoteClient: NavidromeClient? = nil) {
        lyricsTask?.cancel()
        let revision = generation
        let metadata = recording == nil ? catalogueMetadataTask : nil
        let needsLookup = track.source == .catalogue || track.id.hasPrefix("download-") || activeLocalTrackID != nil
        lyricsLoading = track.lyricFile != nil || recording != nil || remoteClient != nil || needsLookup
        guard lyricsLoading else { return }
        lyricsTask = Task { [weak self, library] in
            let song = await metadata?.value ?? track.playlistSong
            let recording = recording ?? song?.recordingMetadata
            let expected = recording.map { $0.durationMs / 1000 } ?? track.duration ?? 0
            guard !Task.isCancelled else { return }
            #if DEBUG
            if track.source == .catalogue, ProcessInfo.processInfo.arguments.contains("--youtube-sync-fixture") {
                guard let self, generation == revision else { return }
                if ProcessInfo.processInfo.arguments.contains("--syllume-recording-regression"), expected > 0 {
                    timeline = LyricTimeline(lrc: "[00:00.00]头发发现\n[00:01.00]\(track.title) 測試文字\n[00:03.00]風聲")
                    lyricReferenceDuration = expected
                }
                lyricsLoading = false
                return
            }
            #endif
            let started = Date()
            var parsed = try? await library.lyrics(for: track)
            var problem: DiagnosticProblem?
            if parsed == nil, let remoteClient, let recording, recording.source == "navidrome" {
                let remote = Track(id: recording.id, source: .navidrome, title: recording.title,
                    artist: recording.artist, album: nil, duration: recording.durationMs / 1000)
                parsed = await remoteClient.lyrics(for: remote)
            } else if parsed == nil, let recording, ["netease", "qq"].contains(recording.source) {
                if let lines = try? await SubtitleNetwork.shared.lyrics(SubtitleRecord(song: recording),
                    netease: "", original: [], current: recording), !lines.isEmpty {
                    parsed = LyricTimeline(lines: lines)
                }
            }
            if parsed == nil, needsLookup, !Task.isCancelled {
                let artist = recording?.artist ?? track.artist ?? ""
                let title = recording?.title ?? track.title
                do {
                    let result = try await PlaybackLookup.within(.seconds(12)) {
                        try await OnlineLyrics.shared.exact(title: title, artist: artist, duration: expected)
                    }
                    if let text = result?.syncedLyrics { parsed = LyricTimeline(lrc: text) }
                } catch { problem = DiagnosticProblem.classify(error) }
            }
            guard let self, generation == revision, !Task.isCancelled else { return }
            if recording?.source == "ytm", activeRecording != nil, expected > 0, abs(duration - expected) > 2 {
                lyricsLoading = false
                return
            }
            if let next = parsed?.prepared(for: duration > 0 ? duration : expected), !next.lines.isEmpty {
                timeline = next
                lyricReferenceDuration = expected > 0 ? expected : nil
                DiagnosticsEvents.shared.record(.lyricsLoaded, since: started)
            } else if needsLookup {
                DiagnosticsEvents.shared.record(.lyricsUnavailable,
                    problem: problem ?? DiagnosticProblem(code: expected > 0 ? .noMatch : .missingDuration), since: started)
            }
            lyricsLoading = false
        }
    }

    private func prepareCatalogue(_ track: Track, song: SyncedYouTubeSong) {
        catalogueTarget = song
        let revision = generation
        let connection = youtubeConnection
        catalogueMetadataTask = Task { [weak self] in
            let started = Date()
            var details: YouTubeVideoDetails?
            var problem: DiagnosticProblem?
            if YouTubeVideo.validID(song.videoID) {
                do {
                    guard let connection else { throw DiagnosticProblem(code: .signedOut) }
                    details = try await connection.selectedVideoDetails(for: song)
                } catch { problem = DiagnosticProblem.classify(error) }
            }
            let resolved = details?.enrich(song) ?? song
            guard let self, generation == revision, !Task.isCancelled else { return song }
            catalogueTarget = resolved
            catalogueVideoStatus = details?.status
            catalogueVideoProblem = problem
            if !nativeReady, embeddedVideo == nil, let length = resolved.duration { duration = length }
            if song.duration == nil {
                DiagnosticsEvents.shared.record(resolved.duration == nil ? .durationUnavailable : .durationRead, source: .youtube,
                    problem: resolved.duration == nil ? DiagnosticProblem(code: .missingDuration) : nil, since: started)
            }
            return resolved
        }
        loadLyrics(track: track, recording: nil)
    }

    func tick() {
        guard let item = player.currentItem else { return }
        let seconds = player.currentTime().seconds
        if !seeking, seconds.isFinite, abs(position - seconds) > 0.01 {
            let advance = seconds - position
            position = max(0, seconds)
            if lyricClockRunning, advance > 0.01, advance <= 1.5 {
                DiagnosticsEvents.shared.observeAdvance(advance)
                if !nativeHasAdvanced {
                    nativeHasAdvanced = true
                    didAdvancePlayback = true
                    diagnosticPlaybackProblem = nil
                    diagnosticPlaybackDetails = nil
                    DiagnosticsEvents.shared.record(.playbackStarted, source: activeCatalogueSource)
                }
            }
        }
        let itemDuration = item.duration.seconds
        if itemDuration.isFinite, itemDuration > 0, duration != itemDuration {
            duration = itemDuration
            system?.updateCommands(model: self)
            publishNowPlaying()
        }
    }

    func transportChanged() { refreshTransport() }

    func didEnd(item: AVPlayerItem) {
        guard player.currentItem === item else { return }
        if wantsPlayback, canAdvance { next() }
        else { pause(); if duration > 0 { position = duration; publishNowPlaying() } }
    }

    func playbackFailed(item: AVPlayerItem) {
        guard player.currentItem === item else { return }
        if let track = current, track.source == .catalogue {
            let status = item.errorLog()?.events.last?.errorStatusCode
            let problem: DiagnosticProblem
            if let status, (400...599).contains(status) { problem = DiagnosticProblem.mediaHTTP(status) }
            else if let error = item.error { problem = DiagnosticProblem.classify(error, fallback: .invalidMedia) }
            else { problem = DiagnosticProblem(code: .timeout) }
            diagnosticPlaybackProblem = problem
            sourceFailures.append((audioSource ?? "音源", problem, nil))
            DiagnosticsEvents.shared.record(.playbackStalled, source: activeCatalogueSource, problem: problem)
            streamTimeout?.cancel(); streamTimeout = nil
            player.replaceCurrentItem(with: nil)
            nativeReady = false
            catalogueHasStarted = false; lyricClockRunning = false
            if wantsPlayback { resolveCatalogue(track) }
            return
        }
        fail(current?.source == .navidrome
             ? "無法串流這首歌。請檢查連線、音訊格式或伺服器轉碼設定。"
             : "無法播放這個音訊檔。",
             problem: item.error.map { DiagnosticProblem.classify($0, fallback: .invalidMedia) } ?? DiagnosticProblem(code: .invalidMedia))
    }

    func interrupt(began: Bool, shouldResume: Bool) {
        if began {
            DiagnosticsEvents.shared.record(.audioInterruption)
            let wasPlaying = wantsPlayback && embeddedVideo == nil
            pause()
            resumeAfterInterruption = wasPlaying
        } else {
            let resumePlayback = shouldResume && resumeAfterInterruption
            resumeAfterInterruption = false
            if resumePlayback { resume() }
        }
    }

    private func load(_ index: Int, requestingVideo: Bool? = nil) {
        resetItem()
        externalPlayback = false
        self.index = index
        let queued = queue[index]
        let track = queued.source == .local ? (library.tracks.first { $0.id == queued.id } ?? queued) : queued
        duration = track.duration ?? 0
        lyricOffset = min(15, max(-15, UserDefaults.standard.double(forKey: offsetKey(track))))
        error = nil
        let url: URL?
        switch track.source {
        case .catalogue:
            videoRequested = requestingVideo ?? videoSurfaceVisible
            system?.updateCommands(model: self)
            if let song = track.playlistSong {
                loadCatalogueArtwork(song, localID: track.preferredLocalID)
                prepareCatalogue(track, song: song)
            }
            resolveCatalogue(track)
            publishNowPlaying()
            return
        case .local:
            url = library.assetURL(for: track)
            activeLocalTrackID = track.id
            activeRecording = track.recording
            refreshArtworkIfNeeded()
            if track.id.hasPrefix("download-"), track.integrityChecked != true, let url, let expected = track.duration {
                let revision = generation
                wantsPlayback = true; isBuffering = true
                resolveTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        _ = try await AudioIntegrity.inspect(url, expected: expected, decode: true)
                        guard generation == revision, !Task.isCancelled else { return }
                        resolveTask = nil
                        reloadLocalLyrics(track); install(url)
                    } catch {
                        guard generation == revision, !Task.isCancelled else { return }
                        resolveTask = nil
                        fail("這份舊下載無法完整解碼。請從播放清單重新下載。")
                    }
                }
                return
            }
            reloadLocalLyrics(track)
        case .demo:
            url = Bundle.main.url(forResource: "tide", withExtension: "m4a")
            if let lyricURL = Bundle.main.url(forResource: "tide", withExtension: "lrc"),
               let text = try? String(contentsOf: lyricURL, encoding: .utf8) {
                timeline = LyricTimeline(lrc: text)
            }
        case .navidrome:
            url = try? client?.stream(for: track)
            if let client { loadRemoteDetails(track, client: client) }
        }
        guard let url else {
            system?.updateCommands(model: self)
            fail("找不到這首歌的音訊來源。")
            return
        }
        install(url)
    }

    private func install(_ url: URL) {
        install(AVURLAsset(url: url))
    }

    private func install(_ asset: AVURLAsset) {
        seekGeneration = UUID()
        seeking = false
        nativeReady = false
        nativeHasAdvanced = false
        statusObservation?.invalidate()
        let item = AVPlayerItem(asset: asset)
        if !asset.url.isFileURL { item.preferredForwardBufferDuration = 4 }
        player.replaceCurrentItem(with: item)
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                guard let self, player.currentItem === observed else { return }
                if observed.status == .failed { playbackFailed(item: observed) }
                else {
                    nativeReady = observed.status == .readyToPlay
                    system?.updateCommands(model: self)
                    tick()
                }
            }
        }
        startCurrentItem()
        system?.updateCommands(model: self)
    }

    private func resolveCatalogue(_ track: Track) {
        guard resolveTask == nil, let song = track.playlistSong else { return }
        let ticket = UUID(), revision = generation
        DiagnosticsEvents.shared.record(.lookupStarted)
        resolveTicket = ticket
        if videoSurfaceVisible { videoRequested = true }
        wantsPlayback = true; isPlaying = false; isBuffering = true; lyricClockRunning = false
        offersVideoFallback = false
        startCatalogueDeadline()
        resolveTask = Task { [weak self] in
            guard let self else { return }
            @MainActor func check() throws {
                try Task.checkCancellation()
                guard resolveTicket == ticket, generation == revision, !externalPlayback else { throw CancellationError() }
            }
            defer { if resolveTicket == ticket { resolveTask = nil } }
            let service = AudioDownloadService.shared
            do {
                try check()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--youtube-unavailable-audio-fixture") {
                    _ = await catalogueMetadataTask?.value
                    try check()
                    catalogueFailed(problem: DiagnosticProblem(code: .unavailable))
                    return
                }
                if ProcessInfo.processInfo.arguments.contains("--youtube-sync-fixture"),
                   !ProcessInfo.processInfo.arguments.contains("--syllume-recording-regression"),
                   !ProcessInfo.processInfo.arguments.contains("--youtube-device-playback-regression"),
                   !ProcessInfo.processInfo.arguments.contains("--youtube-slow-source-fixture"),
                   let url = Bundle.main.url(forResource: "tide", withExtension: "m4a") {
                    if let file = Bundle.main.url(forResource: "tide", withExtension: "lrc"),
                       let text = try? String(contentsOf: file, encoding: .utf8) { timeline = LyricTimeline(lrc: text) }
                    audioSource = "示範串流"; lyricsLoading = false
                    install(url); return
                }
                #endif
                let target = await catalogueMetadataTask?.value ?? song
                try check()
                if !triedLocal {
                    var locals = library.matchingAudio(for: target).sorted(by: DownloadAudioCandidate.preferred)
                    if let id = track.preferredLocalID, let local = library.availableTrack(id),
                       let url = library.assetURL(for: local), let length = local.duration {
                        locals.removeAll { $0.localTrackID == id }
                        locals.insert(DownloadAudioCandidate(url: url, title: local.title, artist: local.artist ?? "",
                            duration: length, format: url.pathExtension, bitrate: 0, source: "本機音檔", localTrackID: id,
                            recording: local.recording), at: 0)
                    }
                    candidates += locals
                    triedLocal = true
                }
                while true {
                    try check()
                    if let candidate = candidates.first {
                        let local = candidate.localTrackID.flatMap(library.availableTrack)
                        let url = candidate.streamingURL ?? candidate.url
                        let started = Date()
                        do {
                            let asset = AVURLAsset(url: url)
                            let length = try await AudioIntegrity.inspect(asset, expected: candidate.duration,
                                decode: local?.id.hasPrefix("download-") == true && local?.integrityChecked != true,
                                deadline: url.isFileURL ? nil : .seconds(5))
                            try check()
                            candidates.removeFirst()
                            duration = length; position = 0
                            resetLyricsIfClockChanged(to: length)
                            activeRecording = candidate.recording ?? SubtitleSong(id: track.id, source: "catalogue",
                                title: candidate.title, artist: candidate.artist, durationMs: length * 1000)
                            activeLocalTrackID = local?.id
                            activeCatalogueSource = candidate.diagnosticSource
                            audioSource = candidate.quality
                            install(asset)
                            return
                        } catch {
                            try check()
                            let problem = DiagnosticProblem.classify(error, fallback: .invalidMedia)
                            candidates.removeFirst()
                            let elapsedMs = max(0, Int(Date().timeIntervalSince(started) * 1000))
                            sourceFailures.append((candidate.source, problem, elapsedMs))
                            DiagnosticsEvents.shared.record(.assetRejected, source: candidate.diagnosticSource,
                                problem: problem, elapsedMs: elapsedMs)
                        }
                    } else if !searchedCatalogue {
                        let attempts = try await service.streamingSearch(for: target, account: account,
                            excluding: attemptedCatalogueSources)
                        try check()
                        attemptedCatalogueSources.formUnion(attempts.map(\.source))
                        var seen = Set<URL>()
                        candidates = attempts.flatMap(\.candidates).sorted(by: DownloadAudioCandidate.preferredForStreaming)
                            .filter { seen.insert($0.url).inserted }
                        for attempt in attempts {
                            DiagnosticsEvents.shared.record(attempt.problem == nil ? .providerMatched : .providerUnavailable,
                                source: attempt.source, problem: attempt.problem, elapsedMs: attempt.elapsedMs)
                            if let problem = attempt.problem {
                                sourceFailures.append((attempt.source.title, problem, attempt.elapsedMs))
                            }
                        }
                        searchedCatalogue = attempts.isEmpty || candidates.isEmpty
                    } else {
                        catalogueFailed(problem: DiagnosticProblem.afterExhaustingAudioSources(sourceFailures.map(\.problem)))
                        return
                    }
                }
            } catch {
                // Ignore callbacks from an older or cancelled track. Any other failure must end the spinner.
                guard resolveTicket == ticket, generation == revision, !Task.isCancelled else { return }
                let problem = DiagnosticProblem.classify(error)
                catalogueFailed(problem: problem)
            }
        }
    }

    private func startCatalogueDeadline() {
        guard startupTimeout == nil else { return }
        let revision = generation
        startupTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(34))
            guard let self, !Task.isCancelled, generation == revision, wantsPlayback, !lyricClockRunning else { return }
            statusObservation?.invalidate(); statusObservation = nil
            player.replaceCurrentItem(with: nil)
            nativeReady = false
            catalogueFailed(problem: DiagnosticProblem(code: .timeout))
        }
    }

    private func catalogueFailed(problem: DiagnosticProblem) {
        let videoID = current?.playlistSong?.videoID
        let hasVideo = videoID.map(YouTubeVideo.validID) == true
        offersVideoFallback = hasVideo && catalogueVideoStatus?.allowsEmbeddedPlayback == true
        var failure = problem
        let messages = sourceFailures.map { "\($0.source)：\($0.problem.code.title)" }
        error = messages.isEmpty ? problem.code.title : Set(messages).sorted().joined(separator: "、")
        if hasVideo {
            if offersVideoFallback {
                error = "找不到可用的音檔，可在播放畫面播放 YouTube 原片。"
            } else if catalogueVideoStatus?.embeddable == false {
                failure = DiagnosticProblem(code: .permission)
                error = "YouTube 限制這部影片的內嵌播放。"
            } else if catalogueVideoStatus?.madeForKids == true {
                failure = DiagnosticProblem(code: .permission)
                error = "這部兒童專屬影片可在 YouTube Music 開啟。"
            } else {
                failure = catalogueVideoProblem ?? DiagnosticProblem(code: .noData)
                error = "無法確認 YouTube 的嵌入播放設定。可重試，或在 YouTube Music 開啟。"
            }
        }
        let details = sourceFailures.map { failure in
            let time = failure.elapsedMs.map { $0 == 0 ? "<1 ms" : "\($0) ms" }
            return ["\(failure.source)：\(failure.problem.detail)", time].compactMap { $0 }.joined(separator: " · ")
        }
        diagnosticPlaybackProblem = failure
        diagnosticPlaybackDetails = details.isEmpty ? nil : Set(details).sorted().joined(separator: "\n")
        let shouldSwitch = wantsPlayback && videoRequested && offersVideoFallback
        DiagnosticsEvents.shared.record(shouldSwitch ? .playbackStalled : .playbackFailed,
            source: activeCatalogueSource, problem: failure)
        pause()
        system?.updateCommands(model: self)
        videoRequested = shouldSwitch
        startRequestedVideoIfVisible()
    }

    func requestVideoPlayback() {
        reclaimPlayback()
        videoRequested = true
        startRequestedVideoIfVisible()
    }

    func setVideoSurfaceVisible(_ visible: Bool) {
        videoSurfaceVisible = visible
        if !visible { videoRequested = false }
        if embeddedVideo != nil { setEmbeddedVideoVisible(visible) }
        else { startRequestedVideoIfVisible() }
    }

    private func startRequestedVideoIfVisible() {
        guard videoSurfaceVisible, videoRequested, !externalPlayback else { return }
        if let embeddedVideo {
            guard embeddedVideo.visible else { return }
            videoRequested = false
            resume()
        } else if offersVideoFallback {
            playYouTubeFallback()
        }
    }

    private func playYouTubeFallback() {
        guard offersVideoFallback, embeddedVideo == nil, !externalPlayback, let song = current?.playlistSong,
              YouTubeVideo.validID(song.videoID) else { return }
        videoRequested = false
        offersVideoFallback = false
        player.replaceCurrentItem(with: nil)
        nativeReady = false
        let video = YouTubeVideo(id: song.videoID, title: song.title, artist: song.artist)
        let transport = YouTubePlayback(automaticallyMatchesLyrics: false)
        let needsOriginalLyrics = activeRecording != nil || (timeline.lines.isEmpty && !lyricsLoading)
        activeRecording = nil
        activeLocalTrackID = nil
        embeddedVideo = transport
        videoHasAdvanced = false
        didAdvancePlayback = false
        diagnosticPlaybackProblem = nil
        audioSource = "YouTube · 官方播放器"
        error = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        system?.updateCommands(model: self)
        DiagnosticsEvents.shared.record(.videoFallbackRequested, source: .youtube)
        transport.play([video], selected: video)
        if !transport.timeline.lines.isEmpty {
            lyricsTask?.cancel()
            timeline = transport.timeline
            manualLyrics = true
            lyricReferenceDuration = catalogueTarget?.duration
            lyricsLoading = false
        } else if needsOriginalLyrics && !manualLyrics, let track = current {
            loadLyrics(track: track, recording: nil)
        }
        refreshEmbeddedVideo()
    }

    func setEmbeddedVideoVisible(_ visible: Bool) {
        guard let embeddedVideo else { return }
        if visible, !embeddedVideo.visible {
            let replay = queuedVideoReplay == embeddedVideo.session
            queuedVideoReplay = nil
            if replay {
                embeddedVideo.setVisible(true)
                seek(to: 0)
                resume()
                return
            }
        }
        embeddedVideo.setVisible(visible)
        refreshEmbeddedVideo()
        if visible { startRequestedVideoIfVisible() }
    }

    func refreshEmbeddedVideo() {
        guard let video = embeddedVideo else { return }
        let wasPlaying = isPlaying
        let previousError = error
        let previousPosition = position
        position = video.position
        if video.duration > 0, duration != video.duration {
            duration = video.duration
            resetLyricsIfClockChanged(to: duration)
        }
        if video.duration > 0, var song = catalogueTarget, let track = current, !manualLyrics,
           song.duration.map({ abs($0 - video.duration) > 2 }) ?? true {
            song.duration = video.duration
            catalogueTarget = song
            loadLyrics(track: track, recording: song.recordingMetadata)
        }
        wantsPlayback = video.wantsPlayback
        let reportsPlaying = video.visible && video.isPlaying
        error = video.error
        let advance = position - previousPosition
        if reportsPlaying, !video.isSeeking, advance > 0.02, advance <= 1.5 {
            DiagnosticsEvents.shared.observeAdvance(advance)
            if !videoHasAdvanced {
                videoHasAdvanced = true
                didAdvancePlayback = true
                diagnosticPlaybackProblem = nil
                diagnosticPlaybackDetails = nil
                DiagnosticsEvents.shared.record(.playbackStarted, source: .youtube)
            }
        }
        isPlaying = reportsPlaying && videoHasAdvanced
        isBuffering = video.wantsPlayback && !isPlaying
        lyricClockRunning = isPlaying && !video.isSeeking
        if wasPlaying && !isPlaying {
            DiagnosticsEvents.shared.record(.playbackPaused, source: .youtube)
            videoHasAdvanced = false
        }
        if !video.visible || !wantsPlayback || videoHasAdvanced {
            videoDeadline?.cancel()
            videoDeadline = nil
        } else if videoDeadline == nil {
            let session = video.session
            videoDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                guard let self, !Task.isCancelled, let video = embeddedVideo, video.session == session else { return }
                video.failed(-2, session: session.uuidString)
                refreshEmbeddedVideo()
            }
        }
        if let problem = video.failure, error != previousError {
            diagnosticPlaybackProblem = problem
            DiagnosticsEvents.shared.record(.playbackFailed, source: .youtube, problem: problem)
        }
        if video.didReachEnd && canAdvance { next() }
    }

    private func loadCatalogueDetails(_ track: Track, recording: SubtitleSong) {
        let local = activeLocalTrackID.flatMap(library.availableTrack)
        if let image = local.flatMap(library.artwork).flatMap(UIImage.init(data:)) {
            artworkTask?.cancel()
            artwork = image
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--youtube-slow-source-fixture") {
            lyricsLoading = false
            return
        }
        #endif
        if !manualLyrics {
            loadLyrics(track: local ?? track, recording: recording,
                       remoteClient: account.map { NavidromeClient(account: $0) })
        }
    }

    private func resetLyricsIfClockChanged(to length: Double) {
        guard let reference = lyricReferenceDuration, abs(reference - length) > 2 else { return }
        timeline = LyricTimeline(lines: [])
        lyricReferenceDuration = nil
        manualLyrics = false
    }

    private func loadCatalogueArtwork(_ song: SyncedYouTubeSong, localID: String?) {
        let file = localID.flatMap(library.availableTrack).flatMap(library.artworkURL)
        loadArtwork(SongArtworkSource(file: file, song: song), song: song)
    }

    func artworkSource(for track: Track) -> SongArtworkSource {
        let local = track.preferredLocalID.flatMap(library.availableTrack) ??
            (track.source == .local ? library.availableTrack(track.id) ?? track : nil)
        let file = local.flatMap(library.artworkURL)
        if let song = track.playlistSong { return SongArtworkSource(file: file, song: song) }
        return SongArtworkSource(file: file, videoID: track.recording?.originVideoID)
    }

    func refreshArtworkIfNeeded() {
        guard artwork == nil, artworkTask == nil, let track = current,
              track.source == .catalogue || track.source == .local else { return }
        loadArtwork(artworkSource(for: track), song: track.playlistSong)
    }

    private func loadArtwork(_ source: SongArtworkSource, song: SyncedYouTubeSong?) {
        guard source.file != nil || source.videoID.map(YouTubeVideo.validID) == true else { return }
        let revision = generation
        let connection = youtubeConnection
        artworkTask = Task(priority: .utility) { [weak self] in
            let started = Date()
            let store = YouTubeArtworkStore.shared
            let bytes = await store.image(for: source)
            var image = bytes.flatMap(UIImage.init(data:))
            if image == nil, !Task.isCancelled, let song, let connection, connection.connected, let channel = song.channelID,
               !YouTubeCaptionDecoders.isTranslatedUpload(song.title), DownloadSongMatch.versions(song.title).isEmpty,
               let portrait = try? await connection.channelPortraits([channel])[channel], !source.candidates.contains(portrait.url) {
                let performer = YouTubeCaptionDecoders.metadata(id: song.videoID, title: song.title,
                    artist: song.artist, duration: song.duration ?? 0).artist
                if !DownloadSongMatch.artistKeys(performer).isDisjoint(with: DownloadSongMatch.artistKeys(portrait.name)),
                   let bytes = await store.portrait(at: portrait.url) {
                    image = UIImage(data: bytes)
                }
            }
            guard let self, generation == revision, !Task.isCancelled else { return }
            artworkTask = nil
            DiagnosticsEvents.shared.record(image == nil ? .artworkUnavailable : .artworkLoaded,
                source: source.videoID != nil ? .youtube : .local,
                problem: image == nil ? DiagnosticProblem(code: .unavailable) : nil, since: started)
            guard let image else { return }
            artwork = image
            publishNowPlaying()
        }
    }

    private func loadRemoteDetails(_ track: Track, client: NavidromeClient) {
        let revision = generation
        lyricsLoading = true
        lyricsTask = Task { [weak self] in
            let timeline = await client.lyrics(for: track)
            guard let self, generation == revision, !Task.isCancelled else { return }
            self.timeline = timeline?.prepared(for: duration) ?? LyricTimeline(lines: [])
            lyricsLoading = false
        }
        artworkTask = Task { [weak self] in
            let data = await client.artwork(for: track)
            guard let self, generation == revision, !Task.isCancelled else { return }
            artwork = data.flatMap { UIImage(data: $0) }
            publishNowPlaying()
        }
    }

    private func resetItem() {
        if isPlaying { DiagnosticsEvents.shared.record(.playbackPaused) }
        embeddedVideo?.stop()
        embeddedVideo = nil
        queuedVideoReplay = nil
        videoRequested = false
        videoDeadline?.cancel(); videoDeadline = nil
        offersVideoFallback = false
        nativeReady = false
        nativeHasAdvanced = false
        videoHasAdvanced = false
        didAdvancePlayback = false
        diagnosticPlaybackProblem = nil
        diagnosticPlaybackDetails = nil
        generation = UUID()
        seekGeneration = UUID()
        seeking = false
        resolveTicket = UUID(); resolveTask?.cancel(); resolveTask = nil
        streamTimeout?.cancel(); streamTimeout = nil
        startupTimeout?.cancel(); startupTimeout = nil
        catalogueTarget = nil; catalogueHasStarted = false
        catalogueVideoStatus = nil; catalogueVideoProblem = nil
        catalogueMetadataTask?.cancel(); catalogueMetadataTask = nil
        lyricReferenceDuration = nil; manualLyrics = false
        activeCatalogueSource = nil
        candidates = []; searchedCatalogue = false; attemptedCatalogueSources = []
        triedLocal = false; sourceFailures = []
        audioSource = nil; activeRecording = nil; activeLocalTrackID = nil; lyricClockRunning = false
        resumeAfterInterruption = false
        statusObservation?.invalidate()
        statusObservation = nil
        if player.currentItem != nil {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        lyricsTask?.cancel()
        artworkTask?.cancel()
        artworkTask = nil
        lyricsLoading = false
        position = 0
        duration = 0
        artwork = nil
        timeline = LyricTimeline(lines: [])
        wantsPlayback = false
        isPlaying = false
        isBuffering = false
    }

    private func clear() {
        resetItem()
        index = nil
        queue = []
        client = nil
        error = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        system?.updateCommands(model: self)
        publishNowPlaying()
    }

    private func fail(_ message: String, problem: DiagnosticProblem = DiagnosticProblem(code: .unavailable)) {
        lyricsTask?.cancel(); lyricsLoading = false
        diagnosticPlaybackProblem = problem
        DiagnosticsEvents.shared.record(.playbackFailed, problem: problem)
        pause()
        error = message
    }

    private func refreshTransport() {
        guard embeddedVideo == nil else { return }
        let status = player.timeControlStatus
        let wasBuffering = isBuffering
        isPlaying = wantsPlayback && status == .playing && player.currentItem != nil
        isBuffering = wantsPlayback && !isPlaying
        lyricClockRunning = isPlaying && !seeking
        if isBuffering && !wasBuffering { DiagnosticsEvents.shared.record(.playbackStalled) }
        if !isPlaying { nativeHasAdvanced = false }
        if lyricClockRunning {
            startupTimeout?.cancel(); startupTimeout = nil
            if !catalogueHasStarted, let track = current, track.playlistSong != nil {
                catalogueHasStarted = true
                if let recording = activeRecording { loadCatalogueDetails(track, recording: recording) }
            }
        }
        let remote = (player.currentItem?.asset as? AVURLAsset)?.url.isFileURL == false
        if !isBuffering || !remote {
            streamTimeout?.cancel(); streamTimeout = nil
        } else if streamTimeout == nil, let item = player.currentItem {
            let wait: Duration = position < 0.1 ? .seconds(7) : .seconds(12)
            streamTimeout = Task { [weak self, weak item] in
                try? await Task.sleep(for: wait)
                guard let self, let item, !Task.isCancelled, isBuffering, player.currentItem === item else { return }
                playbackFailed(item: item)
            }
        }
        publishNowPlaying()
    }

    private func publishNowPlaying() {
        guard embeddedVideo == nil else { return }
        guard !externalPlayback, let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: lyricClockRunning ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        info[MPMediaItemPropertyArtist] = track.artist
        info[MPMediaItemPropertyAlbumTitle] = track.album
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
