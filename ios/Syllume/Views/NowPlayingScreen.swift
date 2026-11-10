import SwiftUI
import UIKit

// Playback controls and lyric stage are separate clock consumers.
struct NowPlayingScreen: View {
    let player: PlaybackModel
    let subtitles: SubtitleController

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("Folia.LyricDisplayMode") private var mode: LyricDisplayMode = .sonnet
    @State private var controlsVisible = true
    @State private var showingQueue = false

    @State private var showingSearch = false

    private var luminous: Bool { mode == .lumiere }
    private var accent: Color { luminous ? Color(red: 1, green: 0.83, blue: 0.58) : SyllumePalette.accent }
    private var videoVisible: Bool { scenePhase == .active && !showingQueue && !showingSearch }

    var body: some View {
        if let track = player.current {
            VStack(spacing: 16) {
              if controlsVisible {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                        .accessibilityLabel("關閉播放畫面")
                    Spacer()
                    Text("N O W   P L A Y I N G").font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                        .accessibilityLabel("現正播放")
                    Spacer()
                    Button { showingSearch = true } label: { Image(systemName: "text.magnifyingglass").frame(width: 44, height: 44) }
                        .accessibilityLabel("尋找歌詞")
                    Button { controlsVisible = false } label: { Image(systemName: "viewfinder").frame(width: 44, height: 44) }
                        .accessibilityLabel("進入沉浸模式")
                    Button { showingQueue = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }
                        .accessibilityLabel("播放佇列")
                }
                .buttonStyle(SyllumePressStyle(luminous: luminous))

                Picker("播放畫面", selection: $mode) {
                    ForEach(LyricDisplayMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)
              }

                if let video = player.embeddedVideo {
                    YouTubePlayerView(player: video, onUpdate: player.refreshEmbeddedVideo)
                        .frame(minWidth: 200, minHeight: 200, maxHeight: 200)
                        .onChange(of: videoVisible, initial: true) { _, visible in
                            if player.embeddedVideo === video { player.setEmbeddedVideoVisible(visible) }
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
                        if subtitles.timeline.lines.isEmpty { LyricStage(player: player, displayTimeline: subtitles.timeline) }
                        else if let index = subtitles.timeline.activeIndex(at: player.lyricPosition),
                                let translation = subtitles.timeline.lines[index].translationText {
                            VStack {
                                Spacer()
                                Text(translation).font(SyllumeLyricFont.text(.callout, size: 16)).multilineTextAlignment(.center)
                                    .padding(.horizontal, 16).padding(.vertical, 7)
                                    .background(.black.opacity(0.45), in: Capsule())
                            }.allowsHitTesting(false)
                        } else { Color.clear }
                    case .sonnet:
                        if subtitles.timeline.lines.isEmpty { LyricStage(player: player, displayTimeline: subtitles.timeline) }
                        else {
                            SonnetStage(songID: track.id, title: track.title, artist: track.artist ?? "",
                                        timeline: subtitles.timeline, revision: subtitles.revision,
                                        position: player.lyricPosition, playing: player.lyricClockRunning,
                                        style: mode.rawValue, rendering: !showingSearch && !showingQueue)
                        }
                    case .lyrics: LyricStage(player: player, displayTimeline: subtitles.timeline).id(track.id)
                    case .cover: artwork
                    }
                }
                .frame(maxHeight: .infinity)
                .layoutPriority(1)

              if controlsVisible {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(.system(.title2, design: .serif, weight: .bold)).lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    if !track.subtitle.isEmpty {
                        Text(track.subtitle).foregroundStyle(.secondary).font(.subheadline).lineLimit(1)
                    }
                    if let error = player.error {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                        if player.offersVideoFallback, player.embeddedVideo == nil {
                            Button("在 Syllume 播放 YouTube 原片", action: player.playYouTubeFallback)
                                .font(.footnote.weight(.semibold)).foregroundStyle(accent)
                                .accessibilityIdentifier("playYouTubeFallback")
                        }
                        if let videoID = track.playlistSong?.videoID, let url = YouTubeVideo.musicURL(for: videoID) {
                            Link("在 YouTube Music 開啟", destination: url)
                                .font(.footnote).foregroundStyle(accent)
                                .accessibilityIdentifier("openYouTubeMusic")
                        }
                    } else if player.isBuffering {
                        Text(player.audioSource == nil && track.source == .catalogue ? "正在尋找可播放的音源…" : "音訊緩衝中…")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if let source = player.audioSource {
                        Text(source).font(.caption).foregroundStyle(accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TransportControls(player: player, luminous: luminous, accent: accent).id(track.id)
                    .padding(.horizontal, luminous ? 12 : 0)
                    .padding(.vertical, luminous ? 8 : 0)
                    .background {
                        if luminous {
                            RoundedRectangle(cornerRadius: 24).fill(.black.opacity(0.38))
                                .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(accent.opacity(0.28)) }
                        }
                    }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--playback-probe") {
                    LocalTransportProbe(player: player)
                }
                if ProcessInfo.processInfo.arguments.contains("--syllume-recording-regression") {
                    Text("鎖定畫面資訊檢查").font(.system(size: 1)).frame(height: 1)
                        .accessibilityIdentifier("systemNowPlayingProbe").accessibilityValue(player.nowPlayingProbe)
                }
                #endif
              }
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .frame(maxWidth: 630)
            .frame(maxWidth: .infinity)
            .background { playbackBackground(for: track) }
            .tint(accent)
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
            .sheet(isPresented: $showingQueue) { PlaybackQueue(player: player) }
            .sheet(isPresented: $showingSearch) {
                let metadata = player.subtitleInput?.song
                LyricSearchScreen(subtitles: subtitles, title: metadata?.title ?? track.title,
                                  artist: metadata?.artist ?? track.artist ?? "", player: player) { record in
                    guard player.current?.id == track.id, player.current?.source == track.source else { return }
                    player.useLyrics(record)
                }
                    .id(track.id)
            }
            .onChange(of: track.id) { _, _ in showingSearch = false }
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
    private func playbackBackground(for track: Track) -> some View {
        if luminous {
            ZStack {
                SyllumePalette.surface
                RadialGradient(colors: [.indigo.opacity(0.64), .clear], center: .topTrailing, startRadius: 0, endRadius: 530)
                if !subtitles.timeline.lines.isEmpty {
                    SonnetStage(songID: track.id, title: track.title, artist: track.artist ?? "",
                        timeline: subtitles.timeline, revision: subtitles.revision, position: player.lyricPosition,
                        playing: player.lyricClockRunning, style: "lumiere", rendering: !showingSearch && !showingQueue,
                        showsTranslation: false)
                }
                LinearGradient(stops: [.init(color: .black.opacity(0.76), location: 0),
                    .init(color: .clear, location: 0.24), .init(color: .clear, location: 0.65),
                    .init(color: .black.opacity(0.91), location: 1)], startPoint: .top, endPoint: .bottom)
                    .accessibilityHidden(true)
            }
            .ignoresSafeArea().allowsHitTesting(false)
        } else {
            PlaybackAtmosphere(playing: player.lyricClockRunning && !showingSearch && !showingQueue).ignoresSafeArea()
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

    @State private var scrubPosition = 0.0
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 9) {
            Slider(value: Binding(get: { min(isScrubbing ? scrubPosition : player.position, upperBound) },
                                  set: { value in
                                      if isScrubbing { scrubPosition = value }
                                      else { player.seek(to: value) }
                                  }),
                   in: 0...upperBound, onEditingChanged: scrub)
                .disabled(!player.canSeek)
                .accessibilityLabel("播放進度")
                .accessibilityValue(playbackTime(isScrubbing ? scrubPosition : player.position))
            HStack {
                Text(playbackTime(isScrubbing ? scrubPosition : player.position))
                Spacer()
                Text(playbackTime(player.duration))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .accessibilityHidden(true)

            HStack(spacing: 0) {
                Button { player.toggleRepeat() } label: {
                    Image(systemName: "repeat").foregroundStyle(player.repeatQueue ? accent : .secondary)
                        .frame(width: 44, height: 48)
                }
                .accessibilityLabel("循環佇列")
                .accessibilityAddTraits(player.repeatQueue ? .isSelected : [])

                Spacer()
                Button { player.previous() } label: {
                    Image(systemName: "backward.end.fill").font(.title2).frame(width: 48, height: 48)
                }
                .accessibilityLabel("上一首或回到開頭")

                Button { player.toggle() } label: {
                    Image(systemName: player.transportIcon)
                        .font(.title2.weight(.semibold))
                        .frame(width: 62, height: 62)
                        .foregroundStyle(SyllumePalette.surface)
                        .background(accent, in: Circle())
                        .shadow(color: luminous ? accent.opacity(0.4) : .clear, radius: 12)
                }
                .accessibilityLabel(player.transportLabel)
                .accessibilityIdentifier("playerToggle")
                .padding(.horizontal, 10)

                Button { player.next() } label: {
                    Image(systemName: "forward.end.fill").font(.title2).frame(width: 48, height: 48)
                }
                .accessibilityLabel("下一首")
                .disabled(!player.canAdvance)
                Spacer()
                Color.clear.frame(width: 44, height: 1).accessibilityHidden(true)
            }
            .buttonStyle(SyllumePressStyle(luminous: luminous))
        }
    }

    private var upperBound: Double { max(1, player.duration) }

    private func scrub(_ editing: Bool) {
        if editing {
            scrubPosition = player.position
            isScrubbing = true
        } else if isScrubbing {
            isScrubbing = false
            player.seek(to: scrubPosition)
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
                if player.embeddedVideo != nil { open() }
                else { player.toggle() }
            } label: {
                Image(systemName: player.transportIcon).frame(width: 44, height: 44)
            }
            .accessibilityLabel(player.embeddedVideo == nil ? player.transportLabel : "開啟 YouTube 播放畫面")
        }
        .buttonStyle(SyllumePressStyle())
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.10)) }
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
