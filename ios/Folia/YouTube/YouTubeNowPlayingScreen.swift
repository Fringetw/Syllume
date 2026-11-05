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
    @State private var showList = false
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
                        Button(showList ? "使用商籟動畫" : "使用歌詞清單") { showList.toggle() }
                        Button("尋找歌詞") { player.pause(); showingSearch = true }
                        Button("附加 LRC／FIA 歌詞", action: importLyrics)
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 40) }
                    .accessibilityLabel("YouTube 播放選項")
                }
                YouTubePlayerView(player: player)
                    .frame(height: 200).frame(minWidth: 200)
                    .padding(.horizontal, 12)

                Group {
                    if !subtitles.timeline.lines.isEmpty {
                        if showList { YouTubeLyricList(player: player, timeline: subtitles.timeline) }
                        else {
                            SonnetStage(songID: track.id, title: track.title, artist: track.artist,
                                        timeline: subtitles.timeline, revision: subtitles.revision,
                                        position: player.position, playing: player.isPlaying && !player.isBuffering)
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
            .buttonStyle(.plain)
            .onAppear { player.setVisible(true) }
            .onDisappear { player.setVisible(false) }
            .onChange(of: scenePhase) { _, phase in if phase != .active { player.pause() } }
            .onChange(of: SubtitleInput(song: SubtitleSong(id: track.id, source: "ytm", title: track.title,
                artist: track.artist, durationMs: player.duration * 1000),
                revision: player.timelineRevision, loading: player.lyricsLoading), initial: true) { _, next in
                subtitles.load(next, timeline: player.timeline)
            }
            .sheet(isPresented: $showingSubtitles) { SubtitleSettingsScreen(subtitles: subtitles) }
            .sheet(isPresented: $showingSearch) {
                OnlineLyricSearchScreen(title: track.title, artist: track.artist.replacingOccurrences(of: " - Topic", with: "")) { record in
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

private struct OnlineLyricSearchScreen: View {
    @State var title: String
    @State var artist: String
    let choose: (LyricSearchRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var records: [LyricSearchRecord] = []
    @State private var loading = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("以歌曲資料尋找同步歌詞") {
                    TextField("歌名", text: $title)
                    TextField("歌手", text: $artist)
                    Button(loading ? "正在尋找…" : "搜尋 LRCLIB") { search() }.disabled(loading || title.isEmpty)
                    if let error { Text(error).foregroundStyle(.orange) }
                }
                Section("選擇與目前音訊相同的版本") {
                    ForEach(records) { record in
                        Button {
                            choose(record); dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.trackName).foregroundStyle(.primary)
                                Text("\(record.artistName) · \(record.albumName) · \(playbackTime(record.duration))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(record.syncedLyrics?.split(separator: "\n").prefix(2).joined(separator: "\n") ?? "")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("尋找歌詞").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } } }
        }
        .onDisappear { task?.cancel() }
    }
    private func search() {
        task?.cancel(); loading = true; error = nil
        let title = title, artist = artist
        task = Task {
            do {
                let found = try await OnlineLyrics.shared.search(title: title, artist: artist)
                guard !Task.isCancelled else { return }
                records = found; loading = false
                if found.isEmpty { error = "找不到同步歌詞，可調整歌名或歌手，或附加自己的 LRC／FIA。" }
            } catch {
                guard !Task.isCancelled else { return }
                loading = false; self.error = "歌詞服務未回應，請稍後再試。"
            }
        }
    }
}
