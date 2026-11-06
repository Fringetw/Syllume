import SwiftUI
import UIKit

// Playback controls and lyric stage are separate clock consumers.
struct NowPlayingScreen: View {
    let player: PlaybackModel
    let subtitles: SubtitleController

    @Environment(\.dismiss) private var dismiss
    @AppStorage("Folia.LyricDisplayMode") private var mode: LyricDisplayMode = .sonnet
    @State private var controlsVisible = true
    @State private var showingQueue = false

    @State private var showingSearch = false

    var body: some View {
        if let track = player.current {
            VStack(spacing: 16) {
              if controlsVisible {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                        .accessibilityLabel("關閉播放畫面")
                    Spacer()
                    Text("N O W   P L A Y I N G").font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(FoliaPalette.accent)
                        .accessibilityLabel("現正播放")
                    Spacer()
                    Button { showingSearch = true } label: { Image(systemName: "text.magnifyingglass").frame(width: 44, height: 44) }
                        .accessibilityLabel("尋找歌詞")
                    Button { controlsVisible = false } label: { Image(systemName: "viewfinder").frame(width: 44, height: 44) }
                        .accessibilityLabel("進入沉浸模式")
                    Button { showingQueue = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }
                        .accessibilityLabel("播放佇列")
                }
                .buttonStyle(FoliaPressStyle())

                Picker("播放畫面", selection: $mode) {
                    ForEach(LyricDisplayMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)
              }

                Group {
                    switch mode {
                    case .sonnet, .lumiere:
                        if subtitles.timeline.lines.isEmpty { LyricStage(player: player, displayTimeline: subtitles.timeline) }
                        else {
                            SonnetStage(songID: track.id, title: track.title, artist: track.artist ?? "",
                                        timeline: subtitles.timeline, revision: subtitles.revision,
                                        position: player.position, playing: player.isPlaying && !player.isBuffering,
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
                        .accessibilityIdentifier("nowPlayingTrackTitle")
                        .accessibilityValue(player.index.map { "播放佇列第 \($0 + 1) 首，共 \(player.queue.count) 首" } ?? "")
                        .accessibilityAddTraits(.isHeader)
                    if !track.subtitle.isEmpty {
                        Text(track.subtitle).foregroundStyle(.secondary).font(.subheadline).lineLimit(1)
                    }
                    if let error = player.error {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    } else if player.isBuffering {
                        Text("音訊緩衝中…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TransportControls(player: player).id(track.id)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--playback-probe") {
                    Text("播放狀態檢查").font(.system(size: 1)).frame(height: 1)
                        .accessibilityIdentifier("localTransportProbe").accessibilityValue(player.mediaProbe)
                }
                #endif
              }
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .frame(maxWidth: 630)
            .frame(maxWidth: .infinity)
            .background(PlaybackAtmosphere(playing: player.isPlaying && !showingSearch && !showingQueue).ignoresSafeArea())
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
                LyricSearchScreen(subtitles: subtitles, title: track.title, artist: track.artist ?? "") { record in
                    guard player.current?.id == track.id, player.current?.source == track.source else { return }
                    player.useLyrics(record)
                }
                    .id(track.id)
            }
            .onChange(of: track.id) { _, _ in showingSearch = false }
            .onChange(of: SubtitleInput(song: SubtitleSong(id: track.id, source: track.source.rawValue,
                title: track.title, artist: track.artist ?? "", durationMs: player.duration * 1000),
                revision: player.timelineRevision, loading: player.lyricsLoading), initial: true) { _, next in
                subtitles.load(next, timeline: player.timeline)
            }
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    private var artwork: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            Group {
                if let image = player.artwork {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ZStack {
                        FoliaAtmosphere()
                        Image(systemName: "waveform")
                            .font(.system(size: 54, weight: .ultraLight))
                            .foregroundStyle(FoliaPalette.accent)
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.13)) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
        }
    }
}

private struct TransportControls: View {
    let player: PlaybackModel

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
                .disabled(player.duration <= 0)
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
                    Image(systemName: "repeat").foregroundStyle(player.repeatQueue ? FoliaPalette.accent : .secondary)
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
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2.weight(.semibold))
                        .frame(width: 62, height: 62)
                        .foregroundStyle(FoliaPalette.surface)
                        .background(FoliaPalette.accent, in: Circle())
                }
                .accessibilityLabel(player.isPlaying ? "暫停" : "播放")
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
            .buttonStyle(FoliaPressStyle())
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
                    } else {
                        Image(systemName: "waveform").foregroundStyle(FoliaPalette.accent)
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
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
            }
            .accessibilityLabel(player.isPlaying ? "暫停" : "播放")
        }
        .buttonStyle(FoliaPressStyle())
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
                TrackRow(track: player.queue[index], active: player.index == index) {
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
