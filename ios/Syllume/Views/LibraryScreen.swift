import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Native music library, document picker and server entry point.
struct LibraryScreen: View {
    let library: LocalLibrary
    let player: PlaybackModel
    let navidrome: NavidromeConnection
    @Environment(\.scenePhase) private var scenePhase

    @State private var spotify = PlatformConnection(.spotify)
    @State private var youtube = PlatformConnection(.youtube)
    @State private var youtubeSync = YouTubeSyncController()
    @State private var subtitles = SubtitleController()
    @State private var showingSettings = false

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

                switch source {
                case .local: localLibrary
                case .navidrome:
                    NavidromeSearch(account: navidrome.account, configure: { showingServer = true }) { track, tracks, client in
                        player.play(tracks, from: track, client: client)
                        presentPlayer()
                    }
                case .spotify:
                    PlatformLibraryScreen(connection: spotify, pauseLocalPlayback: pauseForPlatform, playYouTube: { _, _ in })
                case .youtube:
                    YouTubeMusicScreen(connection: youtube, sync: youtubeSync, library: library,
                        account: navidrome.account, player: player, openPlayer: presentPlayer, refresh: refreshYouTubePlaylist)
                }
            }
            .background(SyllumePalette.surface.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let track = player.current {
                    MiniPlayer(track: track, player: player, open: presentPlayer)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            SubtitleEngineAnchor(controller: subtitles).frame(width: 1, height: 1)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .fullScreenCover(isPresented: $showingPlayer, onDismiss: {
            DiagnosticsEvents.shared.record(.playerClosed)
            refreshYouTubePlaylist()
        }) {
            NowPlayingScreen(player: player, subtitles: subtitles)
                #if DEBUG
                .overlay(alignment: .topLeading) {
                    if ProcessInfo.processInfo.arguments.contains("--youtube-slow-source-fixture") {
                        Text("歌單同步狀態檢查").font(.system(size: 1)).frame(height: 1)
                            .accessibilityIdentifier("youtubePlaylistSyncProbe")
                            .accessibilityValue(youtubeSync.busy ? "同步中" : "已暫停")
                    }
                }
                #endif
        }
        .sheet(isPresented: $showingSettings) {
            SyllumeSettingsScreen(subtitles: subtitles, navidrome: navidrome, youtube: youtube, library: library, player: player)
        }
        .sheet(isPresented: $showingServer) { NavidromeSettings(connection: navidrome) }
        .onAppear {
            DiagnosticsEvents.shared.firstViewAppeared()
            subtitles.sources(library: library, account: navidrome.account)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                DiagnosticsEvents.shared.record(.foreground)
                subtitles.synchronize()
                player.refreshArtworkIfNeeded()
                refreshYouTubePlaylist()
            }
            if phase == .background {
                DiagnosticsEvents.shared.record(.background)
                youtubeSync.cancel()
            }
        }
        .onChange(of: youtube.sessionID, initial: true) { _, _ in youtubeSync.activate(youtube) }
        .onChange(of: navidrome.account) { _, _ in
            player.clearNavidrome(); subtitles.sources(library: library, account: navidrome.account)
            youtubeSync.cancel()
            refreshYouTubePlaylist()
        }
        .onChange(of: player.subtitleInput, initial: true) { _, next in
            subtitles.load(next, timeline: player.timeline)
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: lyricTarget == nil ? [.audio] + Self.lyricTypes : Self.lyricTypes,
                      allowsMultipleSelection: lyricTarget == nil, onCompletion: handleImport)
        .alert("Syllume", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
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

    private func presentPlayer() {
        DiagnosticsEvents.shared.record(.playerOpened)
        youtubeSync.cancel()
        showingPlayer = true
    }

    private func refreshYouTubePlaylist(force: Bool = false) {
        guard source == .youtube, scenePhase == .active, !showingPlayer else { return }
        youtubeSync.synchronize(connection: youtube, force: force)
    }

    private var masthead: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("L Y R I C S   R E I M A G I N E D")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SyllumePalette.accent)
                    .accessibilityHidden(true)
                Text("Syllume").font(.system(.largeTitle, design: .serif, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3).frame(width: 44, height: 44)
                    .background(.white.opacity(0.06), in: Circle())
            }
            .accessibilityLabel("Syllume 設定")
            Button {
                lyricTarget = nil
                showingImporter = true
            } label: {
                Image(systemName: "plus").font(.title3.weight(.medium))
                    .frame(width: 44, height: 44).background(SyllumePalette.accent, in: Circle())
                    .foregroundStyle(SyllumePalette.surface)
            }
            .accessibilityLabel("匯入音樂")
            .disabled(library.importInProgress)
        }
        .buttonStyle(SyllumePressStyle())
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private var visibleTracks: [Track] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? library.tracks : library.tracks.filter {
            $0.title.localizedStandardContains(text) || $0.subtitle.localizedStandardContains(text)
        }
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
                        TrackRow(track: track, active: player.current?.source == .local && player.current?.id == track.id,
                                 artworkFile: library.artworkURL(for: track)) {
                            player.play(visibleTracks, from: track)
                            presentPlayer()
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
            player.play([.demo], from: .demo)
            presentPlayer()
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("S Y L L U M E   S E S S I O N   /   0 1").font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(SyllumePalette.accent)
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
                SyllumeAtmosphere().clipShape(.rect(cornerRadius: 20))
            }
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.10)) }
        }
        .buttonStyle(SyllumePressStyle())
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
                Task { if let warning = await library.importFiles(urls).warning { message = warning } }
            }
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError { message = "無法從「檔案」讀取選取的內容。" }
        }
    }

    private func pauseForPlatform() { player.pauseForExternalPlayback() }
}

struct TrackRow: View {
    let track: Track
    var active = false
    var artworkFile: URL? = nil
    @State private var hasArtwork = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SongArtworkView(source: SongArtworkSource(file: artworkFile,
                                    videoID: track.playlistSong?.videoID ?? track.recording?.originVideoID,
                                    candidates: track.playlistSong?.artworkURLs ?? []),
                                placeholder: active ? "waveform" : "music.note",
                                tint: active ? SyllumePalette.accent : .secondary, size: 42, cornerRadius: 10,
                                loaded: { hasArtwork = $0 })
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).foregroundStyle(active ? SyllumePalette.accent : .primary).lineLimit(2)
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
        .buttonStyle(SyllumePressStyle())
        #if DEBUG
        .accessibilityIdentifier("trackRow-" + track.id)
        .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--syllume-recording-regression") && hasArtwork ? "已載入歌曲封面" : "")
        #endif
    }
}

struct SongArtworkView: View {
    let source: SongArtworkSource
    var placeholder = "music.note"
    let tint: Color
    let size: CGFloat
    let cornerRadius: CGFloat
    var loaded: (Bool) -> Void = { _ in }
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var imageSource: SongArtworkSource?

    private struct Request: Hashable {
        let source: SongArtworkSource
        let active: Bool
    }

    var body: some View {
        Group {
            if imageSource == source, let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: placeholder).font(.callout.weight(.semibold)).foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: cornerRadius))
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
        .task(id: Request(source: source, active: scenePhase == .active), priority: .utility) {
            guard scenePhase == .active else { return }
            if imageSource != source { image = nil; loaded(false) }
            guard image == nil else { return }
            let data = await YouTubeArtworkStore.shared.image(for: source)
            guard !Task.isCancelled else { return }
            image = data.flatMap(UIImage.init(data:))
            imageSource = source
            loaded(image != nil)
        }
    }
}
