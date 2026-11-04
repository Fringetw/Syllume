import SwiftUI

// Native Folia-inspired stage with line transitions and word highlighting.
enum FoliaPalette {
    static let surface = Color(red: 0.042, green: 0.052, blue: 0.075)
    static let accent = Color(red: 0.63, green: 0.86, blue: 0.82)
}

struct FoliaAtmosphere: View {
    var body: some View {
        ZStack {
            FoliaPalette.surface
            RadialGradient(colors: [Color(red: 0.13, green: 0.33, blue: 0.34).opacity(0.80), .clear],
                           center: .topTrailing, startRadius: 2, endRadius: 430)
            RadialGradient(colors: [Color(red: 0.24, green: 0.18, blue: 0.36).opacity(0.75), .clear],
                           center: .bottomLeading, startRadius: 5, endRadius: 400)
        }
        .accessibilityHidden(true)
    }
}

struct LyricStage: View {
    let player: PlaybackModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let timeline = player.timeline
        if timeline.lines.isEmpty {
            if player.lyricsLoading {
                ProgressView("正在載入歌詞")
            } else {
                ContentUnavailableView {
                    Label("這首歌沒有同步歌詞", systemImage: "text.quote")
                } description: {
                    if player.current?.source == .local {
                        Text("在本機曲庫長按歌曲，即可附加 LRC 或 Folia .fia。")
                    } else {
                        Text("這個來源沒有提供可同步的歌詞。")
                    }
                }
            }
        } else {
            let index = timeline.activeIndex(at: player.position)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(timeline.lines.indices, id: \.self) { row in
                            let line = timeline.lines[row]
                            let active = row == index
                            Button {
                                player.seek(to: line.startTime)
                            } label: {
                                LyricRow(line: line, active: active, position: active ? player.position : 0)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("跳到這句歌詞")
                            .accessibilityAddTraits(active ? .isSelected : [])
                            .id(row)
                        }
                    }
                    .padding(.vertical, 25)
                }
                .defaultScrollAnchor(.top)
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
                    }
                    .allowsHitTesting(false)
                }
                .onChange(of: index, initial: true) { _, next in
                    guard let next else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.40)) {
                        reader.scrollTo(next, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct LyricRow: View {
    let line: LyricLine
    let active: Bool
    let position: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(lyricText)
                .font(.system(.title, design: .serif, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let romanization = line.romanization, !romanization.isEmpty {
                Text(romanization).font(.footnote).foregroundStyle(.secondary)
            }
            if let translation = line.translation, !translation.isEmpty {
                Text(translation).font(.callout).foregroundStyle(active ? FoliaPalette.accent : .secondary)
            }
        }
        .opacity(active ? 1 : 0.61)
        .offset(x: active && !reduceMotion ? 4 : 0)
        .padding(.trailing, 4)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: active)
    }

    private var lyricText: AttributedString {
        guard active, !line.words.isEmpty else {
            return AttributedString(line.fullText)
        }
        var result = AttributedString()
        for word in line.words {
            var part = AttributedString(word.text)
            if position >= word.startTime { part.foregroundColor = FoliaPalette.accent }
            result += part
        }
        return result
    }
}
