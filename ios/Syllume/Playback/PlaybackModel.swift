import AVFoundation
import MediaPlayer
import Observation
import UIKit

// Native playback, queue and Now Playing state share a single AVPlayer clock.
@MainActor @Observable
final class PlaybackModel {
    private(set) var queue: [Track] = []
    private(set) var index: Int?
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

    var diagnosticTransportMetrics: [String: Double] {
        guard player.currentItem != nil else { return [:] }
        var metrics: [String: Double] = ["lyricCueCount": Double(timeline.lines.count), "manualLyricOffset_s": lyricOffset]
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
        let recording = activeRecording ?? track.recording
        return SubtitleInput(song: SubtitleSong(id: track.id, source: track.source.rawValue,
            title: recording?.title ?? track.title, artist: recording?.artist ?? track.artist ?? "",
            durationMs: (duration * 10).rounded() * 100, ref: recording?.ref,
            originVideoID: track.playlistSong.flatMap { YouTubeVideo.validID($0.videoID) ? $0.videoID : nil } ?? recording?.originVideoID),
            revision: timelineRevision, loading: lyricsLoading || (track.source == .catalogue && !catalogueHasStarted))
    }

    var current: Track? { index.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    var canAdvance: Bool { index.map { $0 + 1 < queue.count || repeatQueue } ?? false }
    #if DEBUG
    var mediaProbe: String {
        // Observe the clock even in cover mode or when a downloaded track has no lyrics.
        _ = position; _ = isPlaying; _ = isBuffering
        return String(format: "%.3f|%.1f", player.currentTime().seconds, player.rate)
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
    @ObservationIgnored private var catalogueTarget: SyncedYouTubeSong?
    @ObservationIgnored private var activeCatalogueSource: DiagnosticSource?
    private var catalogueHasStarted = false
    @ObservationIgnored private var resolveTicket = UUID()
    private var activeRecording: SubtitleSong?
    @ObservationIgnored private var account: NavidromeAccount?
    @ObservationIgnored private var candidates: [DownloadAudioCandidate] = []
    @ObservationIgnored private var searchedCatalogue = false
    @ObservationIgnored private var attemptedCatalogueSources: Set<DiagnosticSource> = []
    @ObservationIgnored private var triedLocal = false
    @ObservationIgnored private var sourceFailures: [String] = []
    @ObservationIgnored private var resumeAfterInterruption = false

    init(library: LocalLibrary) {
        self.library = library
        player.automaticallyWaitsToMinimizeStalling = true
        system = PlaybackSystem(model: self, player: player)
    }

    func play(_ tracks: [Track], from selected: Track, client: NavidromeClient? = nil) {
        guard let index = tracks.firstIndex(of: selected) else { return }
        externalPlayback = false
        self.client = client
        queue = tracks
        load(index)
    }

    func playPlaylist(_ songs: [SyncedYouTubeSong], from song: SyncedYouTubeSong,
                      bindings: [String: YouTubeAudioBinding], account: NavidromeAccount?, connection: PlatformConnection) {
        let tracks = songs.map { Self.playlistTrack($0, bindings: bindings) }
        guard let track = tracks.first(where: { $0.id == song.id }) else { return }
        self.account = account
        youtubeConnection = connection
        play(tracks, from: track)
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
        } else { playPlaylist([song], from: song, bindings: bindings, account: account, connection: connection) }
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

    func toggle() { isPlaying ? pause() : resume() }

    func resume() {
        guard !externalPlayback else { return }
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
            isPlaying = true
            player.play()
            refreshTransport()
        } catch {
            fail("無法啟用音訊。請檢查目前的音訊輸出。")
        }
    }

    func pause() {
        if isPlaying { DiagnosticsEvents.shared.record(.playbackPaused) }
        resumeAfterInterruption = false
        player.pause()
        isPlaying = false
        streamTimeout?.cancel(); streamTimeout = nil
        startupTimeout?.cancel(); startupTimeout = nil
        if resolveTask != nil {
            resolveTicket = UUID(); resolveTask?.cancel(); resolveTask = nil
            lyricsLoading = false
        }
        refreshTransport()
    }

    func useLyrics(_ record: LyricSearchRecord) {
        guard current != nil, let text = record.syncedLyrics else { return }
        lyricsTask?.cancel(); lyricsLoading = false
        timeline = LyricTimeline(lrc: text).prepared(for: duration)
    }

    func pauseForExternalPlayback() {
        pause()
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
        if selected == index { seek(to: 0); resume() }
        else { load(selected) }
    }

    func toggleRepeat() {
        repeatQueue.toggle()
        system?.updateCommands(model: self)
    }

    func seekToLyric(_ time: Double) { seek(to: time - lyricOffset) }

    func seek(to time: Double) {
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
        loadLyrics(track: track, recording: track.recording ?? activeRecording)
    }

    private func loadLyrics(track: Track, recording: SubtitleSong?, remoteClient: NavidromeClient? = nil) {
        lyricsTask?.cancel()
        let revision = generation
        let needsLookup = track.source == .catalogue || track.id.hasPrefix("download-") || activeLocalTrackID != nil
        lyricsLoading = track.lyricFile != nil || recording != nil || remoteClient != nil || needsLookup
        guard lyricsLoading else { return }
        lyricsTask = Task { [weak self, library] in
            var parsed = try? await library.lyrics(for: track)
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
                let duration = recording.map { $0.durationMs / 1000 } ?? track.duration ?? 0
                let result = try? await OnlineLyrics.shared.exact(title: title, artist: artist, duration: duration)
                if let text = result?.syncedLyrics { parsed = LyricTimeline(lrc: text) }
            }
            guard let self, generation == revision, !Task.isCancelled else { return }
            if let next = parsed?.prepared(for: duration), !next.lines.isEmpty { timeline = next }
            lyricsLoading = false
        }
    }

    func tick() {
        guard let item = player.currentItem else { return }
        let seconds = player.currentTime().seconds
        if !seeking, seconds.isFinite, abs(position - seconds) > 0.01 { position = max(0, seconds) }
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
        if isPlaying, canAdvance { next() }
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
            sourceFailures.append((audioSource ?? "音源") + "：" + problem.code.title)
            DiagnosticsEvents.shared.record(.playbackStalled, source: activeCatalogueSource, problem: problem)
            streamTimeout?.cancel(); streamTimeout = nil
            player.replaceCurrentItem(with: nil)
            lyricsTask?.cancel()
            catalogueHasStarted = false; lyricClockRunning = false
            if isPlaying { resolveCatalogue(track) }
            return
        }
        fail(current?.source == .navidrome
             ? "無法串流這首歌。請檢查連線、音訊格式或伺服器轉碼設定。"
             : "無法播放這個音訊檔。")
    }

    func interrupt(began: Bool, shouldResume: Bool) {
        if began {
            DiagnosticsEvents.shared.record(.audioInterruption)
            let wasPlaying = isPlaying
            pause()
            resumeAfterInterruption = wasPlaying
        } else {
            let resumePlayback = shouldResume && resumeAfterInterruption
            resumeAfterInterruption = false
            if resumePlayback { resume() }
        }
    }

    private func load(_ index: Int) {
        resetItem()
        self.index = index
        let queued = queue[index]
        let track = queued.source == .local ? (library.tracks.first { $0.id == queued.id } ?? queued) : queued
        duration = track.duration ?? 0
        lyricOffset = min(15, max(-15, UserDefaults.standard.double(forKey: offsetKey(track))))
        error = nil
        let url: URL?
        switch track.source {
        case .catalogue:
            if let song = track.playlistSong { loadCatalogueArtwork(song, localID: track.preferredLocalID) }
            resolveCatalogue(track)
            return
        case .local:
            url = library.assetURL(for: track)
            activeLocalTrackID = track.id
            activeRecording = track.recording
            artwork = library.artwork(for: track).flatMap { UIImage(data: $0) }
            if artwork == nil, let videoID = track.recording?.originVideoID {
                loadYouTubeArtwork(videoID: videoID)
            }
            if track.id.hasPrefix("download-"), track.integrityChecked != true, let url, let expected = track.duration {
                let revision = generation
                isPlaying = true; isBuffering = true
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
        statusObservation?.invalidate()
        let item = AVPlayerItem(asset: asset)
        if !asset.url.isFileURL { item.preferredForwardBufferDuration = 4 }
        player.replaceCurrentItem(with: item)
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                guard let self, player.currentItem === observed else { return }
                if observed.status == .failed { playbackFailed(item: observed) }
                else { tick() }
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
        isPlaying = true; isBuffering = true; lyricClockRunning = false; lyricsLoading = true
        startCatalogueDeadline()
        lyricsTask?.cancel()
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
                    fail("測試音源目前無法播放。")
                    return
                }
                if ProcessInfo.processInfo.arguments.contains("--youtube-sync-fixture"),
                   !ProcessInfo.processInfo.arguments.contains("--youtube-slow-source-fixture"),
                   let url = Bundle.main.url(forResource: "tide", withExtension: "m4a") {
                    if let file = Bundle.main.url(forResource: "tide", withExtension: "lrc"),
                       let text = try? String(contentsOf: file, encoding: .utf8) { timeline = LyricTimeline(lrc: text) }
                    audioSource = "示範串流"; lyricsLoading = false
                    install(url); return
                }
                #endif
                if !triedLocal {
                    var locals = library.matchingAudio(for: song).sorted(by: DownloadAudioCandidate.preferred)
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
                var target = catalogueTarget ?? song
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
                            duration = length; position = 0; timeline = LyricTimeline(lines: [])
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
                            sourceFailures.append(candidate.source + "：" + problem.code.title)
                            DiagnosticsEvents.shared.record(.assetRejected, source: candidate.diagnosticSource,
                                problem: problem, since: started)
                        }
                    } else if !searchedCatalogue {
                        if target.duration == nil, catalogueTarget == nil, YouTubeVideo.validID(song.videoID) {
                            let connection = youtubeConnection
                            let started = Date()
                            let probes: [@Sendable () async -> SyncedYouTubeSong?] = [
                                { @Sendable in
                                    guard let connection else { return nil }
                                    let result = await connection.playlistSongWithDuration(song)
                                    return result.duration == nil ? nil : result
                                },
                                { @Sendable in
                                    let result = await service.withDuration(song)
                                    return result.duration == nil ? nil : result
                                }
                            ]
                            let resolved = try? await PlaybackLookup.within(.seconds(4)) {
                                try await PlaybackLookup.firstAvailable(probes)
                            }
                            try check()
                            target = resolved ?? song
                            catalogueTarget = target
                            DiagnosticsEvents.shared.record(target.duration == nil ? .durationUnavailable : .durationRead,
                                source: .youtube, problem: target.duration == nil ? DiagnosticProblem(code: .missingDuration) : nil,
                                since: started)
                            if target.duration != nil {
                                candidates = library.matchingAudio(for: target).filter { $0.localTrackID != track.preferredLocalID }
                                    .sorted(by: DownloadAudioCandidate.preferred)
                                if !candidates.isEmpty { continue }
                            }
                        }
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
                                sourceFailures.append(attempt.source.title + "：" + problem.code.title)
                            }
                        }
                        searchedCatalogue = attempts.isEmpty || candidates.isEmpty
                    } else {
                        lyricsLoading = false
                        fail((sourceFailures.last ?? "目前沒有可播放的同版本音源。") + " 按播放重試，或附加音檔。")
                        return
                    }
                }
            } catch {
                // Ignore callbacks from an older or cancelled track. Any other failure must end the spinner.
                guard resolveTicket == ticket, generation == revision, !Task.isCancelled else { return }
                let problem = DiagnosticProblem.classify(error)
                DiagnosticsEvents.shared.record(.providerUnavailable, problem: problem)
                fail(problem.code.title + "。按播放重試，或附加音檔。")
            }
        }
    }

    private func startCatalogueDeadline() {
        guard startupTimeout == nil else { return }
        let revision = generation
        startupTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(34))
            guard let self, !Task.isCancelled, generation == revision, isPlaying, !lyricClockRunning else { return }
            DiagnosticsEvents.shared.record(.providerUnavailable, problem: DiagnosticProblem(code: .timeout))
            statusObservation?.invalidate(); statusObservation = nil
            player.replaceCurrentItem(with: nil)
            lyricsLoading = false
            fail("音源連線逾時。按播放重試，或在歌單附加音檔。")
        }
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
        loadLyrics(track: local ?? track, recording: recording,
                   remoteClient: account.map { NavidromeClient(account: $0) })
    }

    private func loadCatalogueArtwork(_ song: SyncedYouTubeSong, localID: String?) {
        if let image = localID.flatMap(library.availableTrack).flatMap(library.artwork).flatMap(UIImage.init(data:)) {
            artwork = image
            return
        }
        loadYouTubeArtwork(videoID: song.videoID, song: song)
    }

    private func loadYouTubeArtwork(videoID: String, song: SyncedYouTubeSong? = nil) {
        guard YouTubeVideo.validID(videoID) else { return }
        let revision = generation
        let connection = youtubeConnection
        artworkTask = Task(priority: .utility) { [weak self] in
            let started = Date()
            let urls = song?.artworkURLs
            let store = YouTubeArtworkStore.shared
            let bytes = await store.cover(for: videoID, candidates: urls)
            var image = bytes.flatMap(UIImage.init(data:))
            if image == nil, !Task.isCancelled, let song, let connection, connection.connected, let channel = song.channelID,
               !YouTubeCaptionDecoders.isTranslatedUpload(song.title), DownloadSongMatch.versions(song.title).isEmpty,
               let portrait = try? await connection.channelPortraits([channel])[channel], urls?.contains(portrait.url) != true {
                let performer = YouTubeCaptionDecoders.metadata(id: song.videoID, title: song.title,
                    artist: song.artist, duration: song.duration ?? 0).artist
                if !DownloadSongMatch.artistKeys(performer).isDisjoint(with: DownloadSongMatch.artistKeys(portrait.name)),
                   let bytes = await store.portrait(at: portrait.url) {
                    image = UIImage(data: bytes)
                }
            }
            guard let self, generation == revision, !Task.isCancelled else { return }
            DiagnosticsEvents.shared.record(image == nil ? .artworkUnavailable : .artworkLoaded,
                source: .youtube, problem: image == nil ? DiagnosticProblem(code: .unavailable) : nil, since: started)
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
        generation = UUID()
        seekGeneration = UUID()
        seeking = false
        resolveTicket = UUID(); resolveTask?.cancel(); resolveTask = nil
        streamTimeout?.cancel(); streamTimeout = nil
        startupTimeout?.cancel(); startupTimeout = nil
        catalogueTarget = nil; catalogueHasStarted = false
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
        lyricsLoading = false
        position = 0
        duration = 0
        artwork = nil
        timeline = LyricTimeline(lines: [])
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

    private func fail(_ message: String) {
        lyricsTask?.cancel(); lyricsLoading = false
        pause()
        error = message
    }

    private func refreshTransport() {
        let status = player.timeControlStatus
        let wasBuffering = isBuffering, wasRunning = lyricClockRunning
        isBuffering = isPlaying && (status != .playing || player.currentItem == nil)
        lyricClockRunning = isPlaying && status == .playing && !seeking
        if isBuffering && !wasBuffering { DiagnosticsEvents.shared.record(.playbackStalled) }
        if lyricClockRunning && !wasRunning { DiagnosticsEvents.shared.record(.playbackStarted) }
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
