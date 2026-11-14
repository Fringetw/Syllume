import SwiftUI
import UIKit

// Playback controls and lyric stage are separate clock consumers.
struct NowPlayingScreen: View {
    let player: PlaybackModel
    let subtitles: SubtitleController

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("Folia.LyricDisplayMode") private var mode: LyricDisplayMode = .sonnet
    @State private var controlsVisible = true
    @State private var showingQueue = false
    @State private var queueCoversVideo = false

    @State private var showingSearch = false
    @State private var scrubPreview: Double?
    #if DEBUG
    @State private var sonnetClockProbe = ""
    @State private var lumiereClockProbe = ""
    #endif

    private func stageClockProbe(_ style: String) -> Binding<String>? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--syllume-recording-regression") {
            return style == "lumiere" ? $lumiereClockProbe : $sonnetClockProbe
        }
        #endif
        return nil
    }

    private var luminous: Bool { mode == .lumiere }
    private var accent: Color {
        if luminous { return Color(red: 1, green: 0.83, blue: 0.58) }
        if mode == .mist { return Color(red: 0.77, green: 0.78, blue: 0.99) }
        return SyllumePalette.accent
    }
    private var lyricPreview: Double? {
        scrubPreview.map { LyricTimingOffset.displayed(position: $0, offset: player.lyricOffset) }
    }
    private var stageTime: Double { lyricPreview ?? player.lyricPosition }
    private var stagePlaying: Bool { scrubPreview == nil && player.lyricClockRunning }
    private var videoVisible: Bool { scenePhase == .active && !queueCoversVideo && !showingSearch }

    var body: some View {
        if let track = player.current {
            VStack(spacing: player.embeddedVideo == nil ? 14 : 8) {
              if controlsVisible {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                        .accessibilityLabel("關閉播放畫面")
                    Spacer()
                    Text("現正播放").font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { showingSearch = true } label: { Image(systemName: "text.magnifyingglass").frame(width: 44, height: 44) }
                        .accessibilityLabel("尋找歌詞")
                    Button { controlsVisible = false } label: { Image(systemName: "viewfinder").frame(width: 44, height: 44) }
                        .accessibilityLabel("進入沉浸模式")
                    Button { queueCoversVideo = true; showingQueue = true } label: {
                        Image(systemName: "list.bullet").frame(width: 44, height: 44)
                    }
                        .accessibilityLabel("播放佇列")
                }
                .buttonStyle(SyllumePressStyle(luminous: luminous))

                PlaybackStylePicker(mode: $mode)
                    .frame(maxWidth: 340)
              }

                if let video = player.embeddedVideo {
                    YouTubePlayerView(player: video, onUpdate: player.refreshEmbeddedVideo)
                        .frame(minWidth: 200, maxWidth: .infinity, minHeight: 200, maxHeight: 200)
                        .id(ObjectIdentifier(video))
                        .onAppear {
                            if player.embeddedVideo === video { player.setEmbeddedVideoVisible(videoVisible) }
                        }
                        .onDisappear {
                            if player.embeddedVideo === video { player.setEmbeddedVideoVisible(false) }
                        }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--youtube-playback-fixture") {
                        Text("YouTube 時間軸檢查").font(.system(size: 1)).frame(height: 1)
                            .accessibilityIdentifier("youtubeTransportProbe")
                            .accessibilityValue(String(format: "%.3f|%@", video.mediaSampleTime, player.isPlaying ? "playing" : "paused"))
                    }
                    #endif
                }

                Group {
                    switch mode {
                    case .lumiere:
                        if subtitles.timeline.lines.isEmpty { LyricStage(player: player, displayTimeline: subtitles.timeline, previewPosition: lyricPreview) }
                        else if let index = subtitles.timeline.activeIndex(at: stageTime),
                                let translation = subtitles.timeline.lines[index].translationText {
                            let focus = LyricFocus(line: subtitles.timeline.lines[index], position: stageTime)
                            VStack {
                                Spacer()
                                Text(translation).font(SyllumeLyricFont.text(.callout, size: 16)).multilineTextAlignment(.center)
                                    .padding(.horizontal, 16).padding(.vertical, 7)
                                    .background(.black.opacity(0.45), in: Capsule())
                                    .foregroundStyle(accent.opacity(reduceMotion ? 1 : 0.78 + 0.22 * focus.presence))
                            }.allowsHitTesting(false)
                        } else { Color.clear }
                    case .sonnet:
                        if subtitles.timeline.lines.isEmpty { LyricStage(player: player, displayTimeline: subtitles.timeline, previewPosition: lyricPreview) }
                        else {
                            SonnetStage(songID: track.id, title: track.title, artist: track.artist ?? "",
                                        timeline: subtitles.timeline, revision: subtitles.revision,
                                        position: stageTime, playing: stagePlaying,
                                        style: mode.rawValue, rendering: !showingSearch && !showingQueue, translationAccent: accent,
                                        clockProbe: stageClockProbe(mode.rawValue))
                        }
                    case .mist:
                        if subtitles.timeline.lines.isEmpty {
                            LyricStage(player: player, displayTimeline: subtitles.timeline, previewPosition: lyricPreview)
                        } else {
                            MistLyricStage(timeline: subtitles.timeline, position: stageTime, accent: accent).id(track.id)
                        }
                    case .lyrics: LyricStage(player: player, displayTimeline: subtitles.timeline, previewPosition: lyricPreview).id(track.id)
                    case .cover: artwork
                    }
                }
                .frame(maxHeight: .infinity)
                .layoutPriority(1)

              if controlsVisible {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        if mode != .cover, let image = player.artwork {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: 42, height: 42).clipShape(.rect(cornerRadius: 8))
                                .accessibilityLabel("目前歌曲封面")
                                .accessibilityIdentifier("nowPlayingThumbnail")
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).font(.system(.title2, design: .rounded, weight: .bold)).lineLimit(2)
                                .accessibilityAddTraits(.isHeader)
                            if !track.subtitle.isEmpty {
                                Text(track.subtitle).foregroundStyle(.secondary).font(.subheadline).lineLimit(1)
                            }
                        }
                    }
                    if let error = player.error {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                        if player.offersVideoFallback, player.embeddedVideo == nil {
                            Button("在 Syllume 播放 YouTube 原片", action: player.requestVideoPlayback)
                                .font(.footnote.weight(.semibold)).foregroundStyle(accent)
                                .accessibilityIdentifier("playYouTubeFallback")
                        }
                        if let videoID = track.playlistSong?.videoID, let url = YouTubeVideo.musicURL(for: videoID) {
                            Link("在 YouTube Music 開啟", destination: url)
                                .font(.footnote).foregroundStyle(accent)
                                .accessibilityIdentifier("openYouTubeMusic")
                        }
                    } else if player.isBuffering, player.audioSource == nil, track.source == .catalogue {
                        Text("正在尋找可播放的音源…")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if let source = player.audioSource {
                        Text(source).font(.caption).foregroundStyle(accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TransportControls(player: player, luminous: luminous, accent: accent, preview: $scrubPreview).id(track.id)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .background { transportPanel }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--playback-probe") {
                    LocalTransportProbe(player: player)
                }
                if ProcessInfo.processInfo.arguments.contains("--syllume-recording-regression") ||
                    ProcessInfo.processInfo.arguments.contains("--youtube-unavailable-audio-fixture") {
                    Text("鎖定畫面資訊檢查").font(.system(size: 1)).frame(height: 1)
                        .accessibilityIdentifier("systemNowPlayingProbe").accessibilityValue(player.nowPlayingProbe)
                }
                if ProcessInfo.processInfo.arguments.contains("--syllume-recording-regression") {
                    Text("商籟動畫時鐘").font(.system(size: 1)).frame(height: 1)
                        .accessibilityIdentifier("syllumeSonnetClockProbe").accessibilityValue(sonnetClockProbe)
                    Text("繪光動畫時鐘").font(.system(size: 1)).frame(height: 1)
                        .accessibilityIdentifier("syllumeLumiereClockProbe").accessibilityValue(lumiereClockProbe)
                }
                #endif
              }
            }
            .padding(.horizontal, player.embeddedVideo == nil || dynamicTypeSize.isAccessibilitySize ? 18 : 14)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .frame(maxWidth: 630)
            .frame(maxWidth: .infinity)
            .background { playbackBackground(for: track) }
            .tint(accent)
            .onChange(of: videoVisible, initial: true) { _, visible in player.setVideoSurfaceVisible(visible) }
            .onDisappear { player.setVideoSurfaceVisible(false) }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: luminous)
            .overlay(alignment: .bottomTrailing) {
                if !controlsVisible {
                    Button { controlsVisible = true } label: {
                        Image(systemName: "slider.horizontal.3").frame(width: 48, height: 48)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("顯示播放控制").padding(18)
                }
            }
            .sheet(isPresented: $showingQueue, onDismiss: { queueCoversVideo = false }) {
                PlaybackQueue(player: player)
            }
            .sheet(isPresented: $showingSearch) {
                let metadata = player.subtitleInput?.song
                LyricSearchScreen(subtitles: subtitles, title: metadata?.title ?? track.title,
                                  artist: metadata?.artist ?? track.artist ?? "", player: player) { record in
                    guard player.current?.id == track.id, player.current?.source == track.source else { return }
                    player.useLyrics(record)
                }
                    .id(track.id)
            }
            .onChange(of: track.id) { _, _ in
                scrubPreview = nil
                showingSearch = false
                #if DEBUG
                sonnetClockProbe = ""; lumiereClockProbe = ""
                #endif
            }
            #if DEBUG
            .onChange(of: mode) { _, _ in
                sonnetClockProbe = ""; lumiereClockProbe = ""
            }
            #endif
            .onChange(of: controlsVisible) { _, visible in
                DiagnosticsEvents.shared.record(visible ? .immersiveOff : .immersiveOn)
            }
            .onChange(of: player.subtitleInput, initial: true) { _, input in
                subtitles.load(input, timeline: player.timeline)
            }
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    @ViewBuilder
    private var transportPanel: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        Group {
            if reduceTransparency {
                shape.fill(SyllumePalette.surface)
            } else {
                #if compiler(>=6.2)
                if #available(iOS 26, *) {
                    Color.clear.glassEffect(.regular, in: shape)
                } else {
                    shape.fill(.regularMaterial)
                }
                #else
                shape.fill(.regularMaterial)
                #endif
            }
        }
        .overlay { shape.strokeBorder(accent.opacity(reduceTransparency ? 0.28 : 0.19)) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func playbackBackground(for track: Track) -> some View {
        if luminous {
            ZStack {
                SyllumePalette.surface
                RadialGradient(colors: [.indigo.opacity(0.64), .clear], center: .topTrailing, startRadius: 0, endRadius: 530)
                if !subtitles.timeline.lines.isEmpty {
                    SonnetStage(songID: track.id, title: track.title, artist: track.artist ?? "",
                        timeline: subtitles.timeline, revision: subtitles.revision, position: stageTime,
                        playing: stagePlaying, style: "lumiere", rendering: !showingSearch && !showingQueue,
                        showsTranslation: false, clockProbe: stageClockProbe("lumiere"))
                }
                LinearGradient(stops: [.init(color: .black.opacity(0.76), location: 0),
                    .init(color: .clear, location: 0.24), .init(color: .clear, location: 0.65),
                    .init(color: .black.opacity(0.91), location: 1)], startPoint: .top, endPoint: .bottom)
                    .accessibilityHidden(true)
            }
            .ignoresSafeArea().allowsHitTesting(false)
        } else {
            ZStack {
                PlaybackAtmosphere(playing: stagePlaying && mode != .mist && !showingSearch && !showingQueue)
                if mode == .mist {
                    RadialGradient(colors: [accent.opacity(0.16), .clear], center: .top,
                                   startRadius: 0, endRadius: 440)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var artwork: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            Group {
                if let image = player.artwork {
                    Image(uiImage: image).resizable().scaledToFit()
                        .accessibilityLabel("歌曲封面")
                        .accessibilityIdentifier("playerArtwork")
                } else {
                    ZStack {
                        SyllumeAtmosphere()
                        Image(systemName: "waveform")
                            .font(.system(size: 54, weight: .ultraLight))
                            .foregroundStyle(SyllumePalette.accent)
                    }
                    .accessibilityHidden(true)
                }
            }
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.13)) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PlaybackStylePicker: View {
    @Binding var mode: LyricDisplayMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker("歌詞樣式", selection: $mode) {
                options
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
        } else {
            Picker("歌詞樣式", selection: $mode) {
                options
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
        }
    }

    private var options: some View {
        ForEach(LyricDisplayMode.allCases) { option in
            Text(option.title).tag(option)
        }
    }
}

#if DEBUG
private struct LocalTransportProbe: View {
    let player: PlaybackModel
    var body: some View {
        Text("播放狀態檢查").font(.system(size: 1)).frame(height: 1)
            .accessibilityIdentifier("localTransportProbe").accessibilityValue(player.mediaProbe)
    }
}
#endif

private struct TransportControls: View {
    let player: PlaybackModel
    let luminous: Bool
    let accent: Color
    @Binding var preview: Double?

    var body: some View {
        let trackID = player.current?.id
        VStack(spacing: 9) {
            PlaybackProgressBar(position: player.position, duration: player.duration,
                                isPlaying: player.isPlaying, isBuffering: player.isBuffering, isSeeking: player.isSeeking,
                                canSeek: player.canSeek, accent: accent, preview: $preview) { time in
                guard player.current?.id == trackID, player.canSeek else { return }
                player.seek(to: time)
            }

            HStack(spacing: 0) {
                Button { player.toggleRepeat() } label: {
                    Image(systemName: "repeat").foregroundStyle(player.repeatQueue ? accent : .secondary)
                        .frame(width: 44, height: 48)
                }
                .accessibilityLabel("循環佇列")
                .accessibilityAddTraits(player.repeatQueue ? .isSelected : [])

                Spacer(minLength: 0)
                Button { player.previous() } label: {
                    Image(systemName: "backward.end.fill").font(.title2).frame(width: 48, height: 48)
                }
                .accessibilityLabel("上一首或回到開頭")

                Button { player.toggle(inApp: true) } label: {
                    Image(systemName: player.transportIcon)
                        .font(.title2.weight(.semibold))
                        .frame(width: 62, height: 62)
                        .foregroundStyle(SyllumePalette.surface)
                        .background(accent, in: Circle())
                        .shadow(color: luminous ? accent.opacity(0.4) : .clear, radius: 12)
                }
                .accessibilityLabel(player.transportLabel)
                .accessibilityIdentifier("playerToggle")
                .padding(.horizontal, 6)

                Button { player.next() } label: {
                    Image(systemName: "forward.end.fill").font(.title2).frame(width: 48, height: 48)
                }
                .accessibilityLabel("下一首")
                .disabled(!player.canAdvance)
                Spacer(minLength: 0)
                Color.clear.frame(width: 44, height: 1).accessibilityHidden(true)
            }
            .buttonStyle(SyllumePressStyle(luminous: luminous))
        }
    }
}

struct MiniPlayer: View {
    let track: Track
    let player: PlaybackModel
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    if let image = player.artwork {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: 38, height: 38).clipped().clipShape(.rect(cornerRadius: 8))
                            .accessibilityIdentifier("miniPlayerArtwork")
                    } else {
                        Image(systemName: "waveform").foregroundStyle(SyllumePalette.accent)
                            .frame(width: 38, height: 38).background(.white.opacity(0.07), in: .rect(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).lineLimit(1).font(.subheadline.weight(.semibold))
                        Text(track.artist ?? "現正播放").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .accessibilityHint("打開完整播放畫面")
            .accessibilityIdentifier("openMiniPlayer")
            #if DEBUG
            .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--syllume-recording-regression") && player.artwork != nil
                ? "已載入歌曲封面" : "")
            #endif
            Button {
                if !player.wantsPlayback, player.embeddedVideo != nil || player.offersVideoFallback { open() }
                player.toggle(inApp: true)
            } label: {
                Image(systemName: player.transportIcon).frame(width: 44, height: 44)
            }
            .accessibilityLabel(player.transportLabel)
            .accessibilityIdentifier("miniPlayerToggle")
        }
        .buttonStyle(SyllumePressStyle())
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .libraryControlSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }
}

private struct PlaybackQueue: View {
    let player: PlaybackModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(player.queue.indices, id: \.self) { index in
                let track = player.queue[index]
                TrackRow(track: track, active: player.index == index, artworkFile: player.artworkSource(for: track).file) {
                    player.selectQueueItem(index)
                    dismiss()
                }
            }
            .navigationTitle("播放佇列")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

func playbackTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
    let whole = Int(seconds)
    return "\(whole / 60):" + String(format: "%02d", whole % 60)
}
