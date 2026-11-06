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

    var current: Track? { index.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    var canAdvance: Bool { index.map { $0 + 1 < queue.count || repeatQueue } ?? false }
    #if DEBUG
    var mediaProbe: String {
        // Keep the real AVPlayer sample observable in every display style.
        _ = position; _ = isPlaying
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
    @ObservationIgnored private var resumeAfterInterruption = false

    init(library: LocalLibrary) {
        self.library = library
        player.automaticallyWaitsToMinimizeStalling = true
        system = PlaybackSystem(model: self, player: player)
    }

    func play(_ tracks: [Track], from selected: Track, client: NavidromeClient? = nil, startingAt position: Int? = nil) {
        let selectedIndex = position ?? tracks.firstIndex(of: selected)
        guard let index = selectedIndex, tracks.indices.contains(index), tracks[index] == selected else { return }
        externalPlayback = false
        self.client = client
        queue = tracks
        load(index)
    }

    func toggle() { isPlaying ? pause() : resume() }

    func resume() {
        guard !externalPlayback else { return }
        if let index, error != nil, player.currentItem?.status == .failed || player.currentItem == nil {
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
        resumeAfterInterruption = false
        player.pause()
        isPlaying = false
        refreshTransport()
    }

    func useLyrics(_ record: LyricSearchRecord) {
        guard current != nil, let text = record.syncedLyrics else { return }
        lyricsTask?.cancel(); lyricsLoading = false
        timeline = LyricTimeline(lrc: text)
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

    func seek(to time: Double) {
        guard let item = player.currentItem, time.isFinite else { return }
        let target = duration > 0 ? min(duration, max(0, time)) : max(0, time)
        let revision = UUID()
        seekGeneration = revision
        seeking = true
        position = target
        let precise = CMTime(seconds: target, preferredTimescale: 600)
        item.seek(to: precise, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, seekGeneration == revision else { return }
                seeking = false
                let actual = player.currentTime().seconds
                if actual.isFinite { position = max(0, actual) }
                publishNowPlaying()
            }
        }
        publishNowPlaying()
    }

    func removeFromQueue(_ id: String) {
        guard let index else { return }
        if current?.source == .local, current?.id == id {
            clear()
            return
        }
        let before = queue.prefix(index).filter { $0.source == .local && $0.id == id }.count
        queue.removeAll { $0.source == .local && $0.id == id }
        self.index = index - before
        system?.updateCommands(model: self)
    }

    func clearNavidrome() {
        if current?.source == .navidrome { clear() }
    }

    func reloadLocalLyrics(_ track: Track) {
        let selected = current?.source == .local && current?.id == track.id
        for position in queue.indices where queue[position].source == .local && queue[position].id == track.id { queue[position] = track }
        guard selected else { return }
        lyricsTask?.cancel()
        timeline = LyricTimeline(lines: [])
        lyricsLoading = track.lyricFile != nil
        guard lyricsLoading else { return }
        let revision = generation
        lyricsTask = Task { [weak self, library] in
            let parsed = try? await library.lyrics(for: track)
            guard let self, generation == revision, !Task.isCancelled else { return }
            timeline = parsed ?? LyricTimeline(lines: [])
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
        fail(current?.source == .navidrome
             ? "無法串流這首歌。請檢查連線、音訊格式或伺服器轉碼設定。"
             : "無法播放這個音訊檔。")
    }

    func interrupt(began: Bool, shouldResume: Bool) {
        if began {
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
        let track = queued.source == .local ? (library.track(queued.id) ?? queued) : queued
        duration = track.duration ?? 0
        error = nil
        let url: URL?
        switch track.source {
        case .local:
            url = library.assetURL(for: track)
            artwork = library.artwork(for: track).flatMap { UIImage(data: $0) }
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
        let item = AVPlayerItem(url: url)
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

    private func loadRemoteDetails(_ track: Track, client: NavidromeClient) {
        let revision = generation
        lyricsLoading = true
        lyricsTask = Task { [weak self] in
            let timeline = await client.lyrics(for: track)
            guard let self, generation == revision, !Task.isCancelled else { return }
            self.timeline = timeline ?? LyricTimeline(lines: [])
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
        generation = UUID()
        seekGeneration = UUID()
        seeking = false
        resumeAfterInterruption = false
        statusObservation?.invalidate()
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
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
        pause()
        error = message
    }

    private func refreshTransport() {
        isBuffering = isPlaying && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying && !isBuffering ? 1.0 : 0.0,
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
