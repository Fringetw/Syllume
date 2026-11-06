import SwiftUI
import UniformTypeIdentifiers

// The official video stays visible above Folia's desktop lyric stage and native controls.
struct YouTubeNowPlayingScreen: View {
    let player: YouTubePlayback
    let subtitles: SubtitleController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSearch = false
    @State private var showingSubtitles = false
    @State private var showingImporter = false
    @AppStorage("Folia.LyricDisplayMode") private var mode: LyricDisplayMode = .sonnet
    @State private var importError: String?
    @State private var importSession: UUID?
    @State private var scrubTime = 0.0
    @State private var scrubbing = false

    var body: some View {
        if let track = player.current {
            VStack(spacing: 8) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 40) }
                        .accessibilityLabel("關閉 YouTube 播放畫面")
                    Spacer()
                    Text("YouTube · Folia").font(.subheadline.weight(.semibold))
                    Spacer()
                    Menu {
                        Button("繁體字幕設定") { player.pause(); showingSubtitles = true }
                        Button("尋找歌詞") { player.pause(); showingSearch = true }
                        Button("附加 LRC／FIA 歌詞", action: importLyrics)
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 40) }
                    .accessibilityLabel("YouTube 播放選項")
                }
                YouTubePlayerView(player: player)
                    .frame(height: 200).frame(minWidth: 200)
                    .padding(.horizontal, 12)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--youtube-playback-fixture") {
                    Text("播放狀態檢查").font(.system(size: 1)).frame(height: 1)
                        .accessibilityIdentifier("youtubeTransportProbe")
                        .accessibilityValue(String(format: "%.3f|%@", player.mediaSampleTime, player.mediaPlaybackState))
                }
                #endif

                Picker("播放畫面", selection: $mode) {
                    ForEach(LyricDisplayMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented).padding(.horizontal, 22)

                Group {
                    if !subtitles.timeline.lines.isEmpty {
                        if mode == .lyrics { YouTubeLyricList(player: player, timeline: subtitles.timeline) }
                        else if mode == .cover { Image(systemName: "music.note").font(.system(size: 80)).foregroundStyle(FoliaPalette.accent) }
                        else {
                            SonnetStage(songID: track.id, title: track.title, artist: track.artist,
                                        timeline: subtitles.timeline, revision: subtitles.revision,
                                        position: player.position, playing: player.isPlaying && !player.isBuffering, style: mode.rawValue)
                        }
                    } else if player.lyricsLoading { ProgressView("正在匹配同步歌詞") }
                    else {
                        VStack(spacing: 12) {
                            Image(systemName: "text.magnifyingglass").font(.title)
                            Text("尚未找到這個版本的同步歌詞").font(.callout)
                            Button("尋找歌詞") { player.pause(); showingSearch = true }.buttonStyle(.bordered)
                            Button("附加 LRC／FIA", action: importLyrics).font(.footnote)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 7) {
                    Text(track.title).font(.headline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    if let error = player.error {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                        Button("重新載入播放器") { player.retry() }
                    } else if player.isBuffering { ProgressView("正在載入 YouTube") }
                    Slider(value: Binding(get: { min(scrubbing ? scrubTime : player.position, max(1, player.duration)) },
                                          set: { value in if scrubbing { scrubTime = value } else { player.seek(to: value) } }),
                           in: 0...max(1, player.duration), onEditingChanged: { editing in
                               if editing { scrubTime = player.position; scrubbing = true }
                               else if scrubbing { scrubbing = false; player.seek(to: scrubTime) }
                           })
                        .disabled(player.duration <= 0).accessibilityLabel("YouTube 播放進度")
                    HStack {
                        Text(playbackTime(player.position)).font(.caption.monospacedDigit())
                        Spacer()
                        Button { player.previous() } label: { Image(systemName: "backward.end.fill").frame(width: 44, height: 40) }
                            .accessibilityLabel("YouTube 上一首")
                        Button { player.toggle() } label: {
                            Image(systemName: player.wantsPlayback ? "pause.fill" : "play.fill").frame(width: 44, height: 40)
                        }
                        .accessibilityLabel(player.wantsPlayback ? "暫停 YouTube" : "播放 YouTube")
                        Button { player.next() } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 40) }
                            .disabled(!player.canAdvance).accessibilityLabel("YouTube 下一首")
                        Spacer()
                        Text(playbackTime(player.duration)).font(.caption.monospacedDigit())
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 6)
            }
            .background(PlaybackAtmosphere(playing: player.isPlaying && !player.isBuffering).ignoresSafeArea())
            .buttonStyle(FoliaPressStyle())
            .onAppear { player.setVisible(true) }
            .onDisappear { player.setVisible(false) }
            .onChange(of: scenePhase) { _, phase in if phase != .active { player.pause() } }
            .onChange(of: SubtitleInput(song: SubtitleSong(id: track.id, source: "ytm", title: track.title,
                artist: track.artist, durationMs: player.duration * 1000),
                revision: player.timelineRevision, loading: player.lyricsLoading), initial: true) { _, next in
                subtitles.load(next, timeline: player.timeline)
            }
            .onChange(of: player.session) { _, _ in showingSearch = false; showingSubtitles = false }
            .sheet(isPresented: $showingSubtitles) { SubtitleSettingsScreen(subtitles: subtitles) }
            .sheet(isPresented: $showingSearch) {
                let selectedSession = player.session
                LyricSearchScreen(subtitles: subtitles, title: track.title, artist: track.artist.replacingOccurrences(of: " - Topic", with: "")) { record in
                    guard player.session == selectedSession else { return }
                    player.useLyrics(record)
                }
                .id(player.session)
            }
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [UTType(importedAs: "org.folia.lyrics.lrc"), UTType(importedAs: "org.folia.lyrics.fia")]) { result in
                guard importSession == player.session else { importError = "歌曲已切換，請重新選取要附加的歌詞。"; return }
                do { try player.attachLyrics(try result.get()) }
                catch { importError = "無法讀取這份歌詞，請選取含時間軸的 LRC 或 Folia FIA。" }
            }
            .alert("歌詞", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("好", role: .cancel) { importError = nil }
            } message: { Text(importError ?? "") }
        } else { Color.clear.onAppear { dismiss() } }
    }
    private func importLyrics() { player.pause(); importSession = player.session; showingImporter = true }
}

private struct YouTubeLyricList: View {
    let player: YouTubePlayback
    let timeline: LyricTimeline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let index = timeline.activeIndex(at: player.position)
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(timeline.lines.indices, id: \.self) { row in
                        Button { player.seek(to: timeline.lines[row].startTime) } label: {
                            LyricRow(line: timeline.lines[row], active: row == index, position: player.position,
                                     playing: player.isPlaying, distance: index.map { abs(row - $0) } ?? 0)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.id(row)
                    }
                }.padding(.horizontal, 26).padding(.vertical, 45)
            }
            .onChange(of: index, initial: true) { _, next in
                guard let next else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) { reader.scrollTo(next, anchor: .center) }
            }
        }
    }
}
