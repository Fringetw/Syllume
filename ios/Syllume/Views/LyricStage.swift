import CoreText
import SwiftUI
import UIKit

@MainActor
enum SyllumeLyricFont {
    private static let name = "GenSenRounded2JP-M"
    static let registeredName: String? = {
        if UIFont(name: name, size: 16) != nil { return name }
        guard let url = Bundle.main.url(forResource: name, withExtension: "otf", subdirectory: "SyllumeStage") else { return nil }
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return UIFont(name: name, size: 16)?.fontName
    }()

    static func text(_ style: Font.TextStyle, size: CGFloat) -> Font {
        guard let registeredName else { return .system(style) }
        return .custom(registeredName, size: size, relativeTo: style)
    }
}

// Native Folia-inspired stage with line transitions and word highlighting.
enum SyllumePalette {
    static let surface = Color(red: 0.042, green: 0.052, blue: 0.075)
    static let accent = Color(red: 0.63, green: 0.86, blue: 0.82)
}

struct SyllumeAtmosphere: View {
    var body: some View {
        ZStack {
            SyllumePalette.surface
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
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(SyllumePalette.surface))
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
    var previewPosition: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("Folia.EnergySavingAnimation") private var energySaving = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

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
            let position = previewPosition ?? player.lyricPosition
            let index = timeline.activeIndex(at: position)
            GeometryReader { geometry in
              ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(timeline.lines.indices, id: \.self) { row in
                            let line = timeline.lines[row]
                            let active = row == index
                            Button {
                                player.seekToLyric(line.startTime)
                            } label: {
                                LyricRow(line: line, active: active, position: active ? position : 0,
                                         distance: index.map { abs(row - $0) } ?? 0,
                                         effectsEnabled: !energySaving && !lowPower)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("跳到這句歌詞")
                            .accessibilityAddTraits(active ? .isSelected : [])
                            .accessibilityIdentifier("lyricLine-\(row)")
                            #if DEBUG
                            .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--subtitle-fixture")
                                ? SyllumeLyricFont.registeredName ?? "system" : "")
                            #endif
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
                    withAnimation(reduceMotion || energySaving || lowPower || previewPosition != nil
                        ? nil : .spring(response: 0.7, dampingFraction: 0.84)) {
                        reader.scrollTo(next, anchor: .center)
                    }
                }
              }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }
}

struct LyricRow: View {
    let line: LyricLine
    let active: Bool
    let position: Double
    let distance: Int
    var accent = SyllumePalette.accent
    var effectsEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let effects = effectsEnabled && !reduceMotion
        VStack(alignment: .leading, spacing: 5) {
            if active {
                FocusedLyricText(line: line, position: position, accent: accent, effects: effects)
                    .font(SyllumeLyricFont.text(.title, size: 28))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(line.fullText).font(SyllumeLyricFont.text(.title, size: 28))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let romanization = line.romanizationText, !romanization.isEmpty {
                Text(romanization).font(SyllumeLyricFont.text(.footnote, size: 13)).foregroundStyle(.secondary)
            }
            if let translation = line.translationText, !translation.isEmpty {
                Text(translation).font(SyllumeLyricFont.text(.callout, size: 16)).foregroundStyle(active ? accent : .secondary)
            }
            if case .array(let vocals)? = line.extra["backgroundVocals"] {
                ForEach(vocals.indices, id: \.self) { index in
                    if case .object(let vocal) = vocals[index], let text = vocal["text"]?.text {
                        Text(text).font(SyllumeLyricFont.text(.callout, size: 16)).foregroundStyle(.secondary)
                        if let translation = vocal["translation"]?.text {
                            Text(translation).font(SyllumeLyricFont.text(.caption, size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .scaleEffect(active || !effects ? 1 : 0.92, anchor: .leading)
        .blur(radius: !effects || active ? 0 : distance > 1 ? 1.4 : 0.4)
        .opacity(active ? 1 : distance > 1 ? 0.35 : 0.58)
        .offset(x: active && effects ? 10 : 0)
        .padding(.trailing, 12)
        .contentShape(Rectangle())
        .animation(effects ? .spring(response: 0.58, dampingFraction: 0.78) : nil, value: active)
        .animation(effects ? .easeOut(duration: 0.5) : nil, value: distance)
    }
}

struct MistLyricStage: View {
    let timeline: LyricTimeline
    let position: Double
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("Folia.EnergySavingAnimation") private var energySaving = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        let next = timeline.nextIndex(after: position)
        let index = timeline.activeIndex(at: position)
        let current = index.map { timeline.lines[$0] }
        let effects = !reduceMotion && !energySaving && !lowPower
        let presence = current.map { LyricFocus(line: $0, position: position).presence } ?? 0
        ViewThatFits(in: .vertical) {
            if !dynamicTypeSize.isAccessibilitySize, let current {
                VStack(spacing: 20) {
                    if let index, index > 0 { neighboringLine(timeline.lines[index - 1], opacity: 0.35) }
                    focusedLine(current, presence: presence, effects: effects)
                    if next < timeline.lines.count { neighboringLine(timeline.lines[next], opacity: 0.48) }
                }
            }
            primaryLine(current, next: next, presence: presence, effects: effects)
            ScrollView {
                primaryLine(current, next: next, presence: presence, effects: effects)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if !reduceTransparency {
                RadialGradient(colors: [accent.opacity(effects ? 0.08 + 0.12 * presence : 0.10), .clear],
                               center: .center, startRadius: 6, endRadius: 190)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mistLyricStage")
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    @ViewBuilder
    private func primaryLine(_ current: LyricLine?, next: Int, presence: Double, effects: Bool) -> some View {
        if let current {
            focusedLine(current, presence: presence, effects: effects)
        } else if next < timeline.lines.count {
            Text(timeline.lines[next].fullText)
                .font(SyllumeLyricFont.text(.title2, size: 23))
                .foregroundStyle(.white.opacity(0.56))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }

    private func focusedLine(_ line: LyricLine, presence: Double, effects: Bool) -> some View {
        VStack(spacing: 8) {
            FocusedLyricText(line: line, position: position, accent: accent, effects: effects)
                .font(SyllumeLyricFont.text(.largeTitle, size: 34))
            if let translation = line.translationText, !translation.isEmpty {
                Text(translation)
                    .font(SyllumeLyricFont.text(.title3, size: 18))
                    .foregroundStyle(accent)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .opacity(effects ? 0.62 + 0.38 * presence : 1)
        .offset(y: effects ? 5 * (1 - presence) : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(line.fullText))
        .accessibilityValue(Text(line.translationText ?? ""))
        .accessibilityIdentifier("mistLyricCurrentLine")
    }

    private func neighboringLine(_ line: LyricLine, opacity: Double) -> some View {
        Text(line.fullText)
            .font(SyllumeLyricFont.text(.callout, size: 17))
            .foregroundStyle(.white.opacity(opacity))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .accessibilityHidden(true)
    }
}

/// One flowing text layout preserves wrapping and punctuation while focusing the timed word.
private struct FocusedLyricText: View {
    let line: LyricLine
    let position: Double
    let accent: Color
    let effects: Bool

    var body: some View {
        let focus = LyricFocus(line: line, position: position)
        if #available(iOS 18, *), effects, let index = focus.wordIndex {
            let before = Text(line.words[..<index].map(\.text).joined())
                .foregroundColor(accent.opacity(0.84))
            let word = Text(line.words[index].text).foregroundColor(accent)
                .customAttribute(CurrentLyricWord())
            let after = Text(line.words[(index + 1)...].map(\.text).joined())
                .foregroundColor(.white.opacity(0.72))
            Text("\(before)\(word)\(after)")
                .textRenderer(LyricWordShimmer(progress: focus.wordProgress, accent: accent))
        } else {
            Text(attributedText)
                .foregroundStyle(line.words.isEmpty ? accent : .white.opacity(0.80))
        }
    }

    private var attributedText: AttributedString {
        guard !line.words.isEmpty else { return AttributedString(line.fullText) }
        var result = AttributedString()
        for word in line.words {
            var part = AttributedString(word.text)
            if position >= word.startTime { part.foregroundColor = accent }
            result += part
        }
        return result
    }
}

@available(iOS 18, *)
private struct CurrentLyricWord: TextAttribute {}

@available(iOS 18, *)
private struct LyricWordShimmer: TextRenderer {
    let progress: Double
    let accent: Color

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                context.draw(run)
                guard run[CurrentLyricWord.self] != nil else { continue }
                let bounds = run.typographicBounds.rect
                guard bounds.width > 0 else { continue }
                let width = max(5, bounds.width * 0.42)
                let center = bounds.minX + bounds.width * progress
                var glow = context
                glow.clipToLayer { $0.draw(run) }
                glow.fill(Path(bounds), with: .linearGradient(
                    Gradient(colors: [.clear, accent.opacity(0.30), .white.opacity(0.74), .clear]),
                    startPoint: CGPoint(x: center - width, y: bounds.midY),
                    endPoint: CGPoint(x: center + width, y: bounds.midY)))
            }
        }
    }
}
