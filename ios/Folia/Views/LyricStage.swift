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

// A low-frequency canvas runs only while the visible player is playing.
struct PlaybackAtmosphere: View {
    let playing: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !playing || reduceMotion || scenePhase != .active)) { timeline in
            Canvas(opaque: true, rendersAsynchronously: true) { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(FoliaPalette.surface))
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
                let colors: [Color] = [.init(red: 0.12, green: 0.46, blue: 0.43),
                                       .init(red: 0.31, green: 0.17, blue: 0.47),
                                       .init(red: 0.10, green: 0.24, blue: 0.40)]
                for index in colors.indices {
                    let phase = time * 0.23 + Double(index) * 2.1
                    let center = CGPoint(x: size.width * (0.5 + sin(phase) * 0.46),
                                         y: size.height * (0.45 + cos(phase * 0.83) * 0.38))
                    let radius = size.width * 0.92
                    let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                      width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect), with: .radialGradient(
                        Gradient(colors: [colors[index].opacity(0.65), .clear]), center: center,
                        startRadius: 0, endRadius: radius))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct LyricStage: View {
    let player: PlaybackModel
    var displayTimeline: LyricTimeline? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let timeline = displayTimeline ?? player.timeline
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
            GeometryReader { geometry in
              ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(timeline.lines.indices, id: \.self) { row in
                            let line = timeline.lines[row]
                            let active = row == index
                            Button {
                                player.seek(to: line.startTime)
                            } label: {
                                LyricRow(line: line, active: active, position: active ? player.position : 0,
                                         playing: player.isPlaying, distance: index.map { abs(row - $0) } ?? 0)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("跳到這句歌詞")
                            .accessibilityAddTraits(active ? .isSelected : [])
                            .accessibilityIdentifier("lyricLine-\(row)")
                            .id(row)
                        }
                    }
                    .padding(.top, geometry.size.height * 0.38)
                    .padding(.bottom, geometry.size.height * 0.48)
                }
                .scrollIndicators(.hidden)
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
                    withAnimation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.84)) {
                        reader.scrollTo(next, anchor: .center)
                    }
                }
              }
            }
        }
    }
}

struct LyricRow: View {
    let line: LyricLine
    let active: Bool
    let position: Double
    let playing: Bool
    let distance: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TimelineView(.animation(minimumInterval: 1.0 / 30,
                                    paused: !active || !playing || reduceMotion || scenePhase != .active)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2) / 3.2
                Text(lyricText)
                    .foregroundStyle(active && line.words.isEmpty ? FoliaPalette.accent : .white)
                    .overlay {
                        if active && !reduceMotion {
                            LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                                           startPoint: UnitPoint(x: phase * 2 - 1, y: 0),
                                           endPoint: UnitPoint(x: phase * 2, y: 1))
                                .mask(Text(line.fullText).frame(maxWidth: .infinity, alignment: .leading))
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .shadow(color: FoliaPalette.accent.opacity(active ? 0.26 : 0), radius: active ? 10 : 0)
            }
            .font(.system(.title, design: .serif, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            if let romanization = line.romanizationText, !romanization.isEmpty {
                Text(romanization).font(.footnote).foregroundStyle(.secondary)
            }
            if let translation = line.translationText, !translation.isEmpty {
                Text(translation).font(.callout).foregroundStyle(active ? FoliaPalette.accent : .secondary)
            }
            if case .array(let vocals)? = line.extra["backgroundVocals"] {
                ForEach(vocals.indices, id: \.self) { index in
                    if case .object(let vocal) = vocals[index], let text = vocal["text"]?.text {
                        Text(text).font(.callout).foregroundStyle(.secondary)
                        if let translation = vocal["translation"]?.text {
                            Text(translation).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .scaleEffect(active || reduceMotion ? 1 : 0.92, anchor: .leading)
        .blur(radius: reduceMotion || active ? 0 : distance > 1 ? 1.4 : 0.4)
        .opacity(active ? 1 : distance > 1 ? 0.35 : 0.58)
        .offset(x: active && !reduceMotion ? 10 : 0)
        .padding(.trailing, 12)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .spring(response: 0.58, dampingFraction: 0.78), value: active)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: distance)
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
