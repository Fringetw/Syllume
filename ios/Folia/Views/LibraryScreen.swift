import SwiftUI
import UniformTypeIdentifiers

// Native music library, document picker and server entry point.
struct LibraryScreen: View {
    let library: LocalLibrary
    let player: PlaybackModel
    let navidrome: NavidromeConnection
    @Environment(\.scenePhase) private var scenePhase

    @State private var spotify = PlatformConnection(.spotify)
    @State private var youtube = PlatformConnection(.youtube)
    @State private var youtubePlayer = YouTubePlayback()
    @State private var subtitles = SubtitleController()
    @State private var showingSettings = false
    @State private var showingYouTubePlayer = false
    @State private var youtubeLink = ""

    @State private var showingPlayer = false
    @State private var showingServer = false
    @State private var showingImporter = false
    @State private var lyricTarget: Track?
    @State private var deletionTarget: Track?
    @State private var message: String?
    @State private var query = ""
    @State private var source: Source = .local

    private enum Source: Hashable { case local, navidrome, spotify, youtube }
    private static let lyricTypes: [UTType] = [
        UTType(importedAs: "org.folia.lyrics.lrc"), UTType(importedAs: "org.folia.lyrics.fia")
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                masthead
                Picker("音樂來源", selection: $source) {
                    Text("本機").tag(Source.local)
                    Text("Navidrome").tag(Source.navidrome)
                    Text("Spotify").tag(Source.spotify)
                    Text("YouTube").tag(Source.youtube)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 22)
                .padding(.bottom, 8)

                if source == .youtube {
                    HStack {
                        TextField("貼上 YouTube／YouTube Music 連結", text: $youtubeLink)
                            .font(.footnote).textFieldStyle(.roundedBorder).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.go).onSubmit(playYouTubeLink)
                        Button("播放", action: playYouTubeLink).disabled(youtubeLink.isEmpty)
                    }
                    .padding(.horizontal, 22).padding(.bottom, 6)
                }

                switch source {
                case .local: localLibrary
                case .navidrome:
                    NavidromeSearch(account: navidrome.account, configure: { showingServer = true }) { track, tracks, client in
                        youtubePlayer.stop()
                        player.play(tracks, from: track, client: client)
                        showingPlayer = true
                    }
                case .spotify:
                    PlatformLibraryScreen(connection: spotify, pauseLocalPlayback: pauseForPlatform, playYouTube: playYouTubeEntry)
                case .youtube:
                    PlatformLibraryScreen(connection: youtube, pauseLocalPlayback: pauseForPlatform, playYouTube: playYouTubeEntry)
                }
            }
            .background(FoliaPalette.surface.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let video = youtubePlayer.current {
                    HStack {
                        Button { showingYouTubePlayer = true } label: {
                            Label(video.title, systemImage: "play.rectangle").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button {
                            if youtubePlayer.isPlaying { youtubePlayer.pause() }
                            else { youtubePlayer.prepareToPlay(); showingYouTubePlayer = true }
                        } label: { Image(systemName: youtubePlayer.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel("打開 YouTube 播放畫面")
                    }
                    .buttonStyle(FoliaPressStyle()).padding(.horizontal, 14).background(.regularMaterial, in: .rect(cornerRadius: 16))
                    .padding(.horizontal, 14).padding(.bottom, 6)
                } else if let track = player.current {
                    MiniPlayer(track: track, player: player, open: { showingPlayer = true })
                }
            }
        }
        .overlay(alignment: .topLeading) {
            SubtitleEngineAnchor(controller: subtitles).frame(width: 1, height: 1)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .fullScreenCover(isPresented: $showingPlayer) { NowPlayingScreen(player: player, subtitles: subtitles) }
        .fullScreenCover(isPresented: $showingYouTubePlayer) { YouTubeNowPlayingScreen(player: youtubePlayer, subtitles: subtitles) }
        .sheet(isPresented: $showingSettings) { FoliaSettingsScreen(subtitles: subtitles, navidrome: navidrome) }
        .sheet(isPresented: $showingServer) { NavidromeSettings(connection: navidrome) }
        .onAppear { subtitles.sources(library: library, account: navidrome.account) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { subtitles.synchronize() } }
        .onChange(of: navidrome.account) { _, _ in
            player.clearNavidrome(); subtitles.sources(library: library, account: navidrome.account)
        }
        .onChange(of: subtitleInput, initial: true) { _, next in
            subtitles.load(next, timeline: player.externalPlayback ? youtubePlayer.timeline : player.timeline)
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: lyricTarget == nil ? [.audio] + Self.lyricTypes : Self.lyricTypes,
                      allowsMultipleSelection: lyricTarget == nil, onCompletion: handleImport)
        .alert("Folia", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
        .confirmationDialog("從本機曲庫移除歌曲？",
                            isPresented: Binding(get: { deletionTarget != nil }, set: { if !$0 { deletionTarget = nil } }),
                            titleVisibility: .visible, presenting: deletionTarget) { track in
            Button("移除", role: .destructive) {
                do { try library.remove(track.id); player.removeFromQueue(track.id) }
                catch { message = "無法更新本機曲庫。" }
            }
        } message: { track in Text(track.title) }
    }

    private var masthead: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("L Y R I C S   R E I M A G I N E D")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(FoliaPalette.accent)
                    .accessibilityHidden(true)
                Text("Folia").font(.system(.largeTitle, design: .serif, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3).frame(width: 44, height: 44)
                    .background(.white.opacity(0.06), in: Circle())
            }
            .accessibilityLabel("Folia 設定")
            Button {
                lyricTarget = nil
                showingImporter = true
            } label: {
                Image(systemName: "plus").font(.title3.weight(.medium))
                    .frame(width: 44, height: 44).background(FoliaPalette.accent, in: Circle())
                    .foregroundStyle(FoliaPalette.surface)
            }
            .accessibilityLabel("匯入音樂")
            .disabled(library.importInProgress)
        }
        .buttonStyle(FoliaPressStyle())
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private var visibleTracks: [Track] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? library.tracks : library.tracks.filter {
            $0.title.localizedStandardContains(text) || $0.subtitle.localizedStandardContains(text)
        }
    }

    private var subtitleInput: SubtitleInput? {
        if player.externalPlayback {
            guard let track = youtubePlayer.current else { return nil }
            return SubtitleInput(song: SubtitleSong(id: track.id, source: "ytm", title: track.title,
                artist: track.artist, durationMs: youtubePlayer.duration * 1000),
                revision: youtubePlayer.timelineRevision, loading: youtubePlayer.lyricsLoading)
        }
        guard let track = player.current else { return nil }
        return SubtitleInput(song: SubtitleSong(id: track.id, source: track.source.rawValue, title: track.title,
            artist: track.artist ?? "", durationMs: player.duration * 1000),
            revision: player.timelineRevision, loading: player.lyricsLoading)
    }

    private var localLibrary: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 13) {
                demoCard
                HStack {
                    Text("我的音樂").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if library.importInProgress { ProgressView().accessibilityLabel("正在匯入") }
                    else { Text("\(library.tracks.count) 首").font(.footnote).foregroundStyle(.secondary) }
                }
                if let error = library.storageError { Text(error).foregroundStyle(.secondary) }
                if library.tracks.isEmpty {
                    Text("使用右上角 ＋ 從「檔案」匯入音樂。若有同名的 .lrc 或 .fia，選取音檔時可一起匯入。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    TextField("搜尋本機曲庫", text: $query)
                        .textFieldStyle(.roundedBorder).submitLabel(.search)
                    if visibleTracks.isEmpty { Text("沒有符合的歌曲。").foregroundStyle(.secondary) }
                    ForEach(visibleTracks) { track in
                        TrackRow(track: track, active: player.current?.source == .local && player.current?.id == track.id) {
                            youtubePlayer.stop()
                            player.play(visibleTracks, from: track)
                            showingPlayer = true
                        }
                        .contextMenu {
                            Button("附加歌詞", systemImage: "text.badge.plus") {
                                lyricTarget = track
                                showingImporter = true
                            }
                            Button("移除歌曲", systemImage: "trash", role: .destructive) { deletionTarget = track }
                        }
                    }
                }
            }
            .padding(22)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var demoCard: some View {
        Button {
            youtubePlayer.stop()
            player.play([.demo], from: .demo)
            showingPlayer = true
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("F O L I A   S E S S I O N   /   0 1").font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(FoliaPalette.accent)
                    Text("潮汐之間").font(.system(.title2, design: .serif, weight: .semibold))
                    Text("試看商籟動畫 · 30 秒音樂示範").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .padding(18)
            .background {
                FoliaAtmosphere().clipShape(.rect(cornerRadius: 20))
            }
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.10)) }
        }
        .buttonStyle(FoliaPressStyle())
        .accessibilityLabel("試聽潮汐之間，30 秒同步歌詞示範")
        .accessibilityIdentifier("demoTrack")
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        let target = lyricTarget
        lyricTarget = nil
        switch result {
        case .success(let urls):
            if let target, let url = urls.first {
                Task {
                    do {
                        try await library.attachLyrics(url, to: target.id)
                        if let track = library.tracks.first(where: { $0.id == target.id }) { player.reloadLocalLyrics(track) }
                    } catch { message = "無法附加這份歌詞。請選取含時間軸的 LRC 或 Folia .fia 檔案。" }
                }
            } else {
                Task { if let warning = await library.importFiles(urls) { message = warning } }
            }
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError { message = "無法從「檔案」讀取選取的內容。" }
        }
    }

    private func pauseForPlatform() { youtubePlayer.pause(); player.pauseForExternalPlayback() }
    private func playYouTubeEntry(_ entry: LibraryEntry, _ entries: [LibraryEntry]) {
        let videos = entries.compactMap { entry -> YouTubeVideo? in
            guard let id = YouTubeVideo.identifier(from: entry.url.absoluteString) else { return nil }
            return YouTubeVideo(id: id, title: entry.title, artist: entry.subtitle, queueID: entry.id)
        }
        guard let selected = videos.first(where: { $0.queueID == entry.id }) else {
            message = "這個項目沒有可播放的 YouTube 影片。"; return
        }
        player.pauseForExternalPlayback(); youtubePlayer.play(videos, selected: selected); showingYouTubePlayer = true
    }
    private func playYouTubeLink() {
        guard let id = YouTubeVideo.identifier(from: youtubeLink) else {
            message = "請貼上 YouTube 或 YouTube Music 的單支影片連結。"; return
        }
        let video = YouTubeVideo(id: id, title: "YouTube 影片", artist: "")
        player.pauseForExternalPlayback(); youtubePlayer.play([video], selected: video)
        youtubeLink = ""; showingYouTubePlayer = true
    }
}

struct TrackRow: View {
    let track: Track
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: active ? "waveform" : "music.note")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(active ? FoliaPalette.accent : .secondary)
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.06), in: .rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).foregroundStyle(active ? FoliaPalette.accent : .primary).lineLimit(2)
                    if !track.subtitle.isEmpty { Text(track.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if let duration = track.duration, duration > 0 {
                    Text(playbackTime(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(FoliaPressStyle())
    }
}
