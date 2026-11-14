import SwiftUI

struct PlaybackProgressBar: View {
    let position: Double
    let duration: Double
    let isPlaying: Bool
    let isBuffering: Bool
    let isSeeking: Bool
    let canSeek: Bool
    let accent: Color
    var label = "播放進度"
    @Binding var preview: Double?
    let seek: (Double) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("Folia.EnergySavingAnimation") private var energySaving = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @GestureState private var dragging = false

    private var length: Double { duration.isFinite ? max(0, duration) : 0 }
    private var enabled: Bool { canSeek && length > 0 }
    private var displayedTime: Double { clamped(preview ?? position) }
    private var fraction: Double { length > 0 ? displayedTime / length : 0 }
    private var fromRight: Bool { layoutDirection == .rightToLeft }
    private var showGlow: Bool { !reduceMotion && !energySaving && !lowPower }
    private var animateClock: Bool {
        showGlow && isPlaying && !isBuffering && !isSeeking && preview == nil && scenePhase == .active
    }
    private var status: String? {
        if preview != nil { return "預覽" }
        if isSeeking { return "定位中" }
        return isBuffering ? "緩衝中" : nil
    }
    private var durationText: String { length > 0 ? playbackTime(length) : "—" }
    private var accessibilityTime: String {
        let time = "目前時間 \(playbackTime(displayedTime))，總長度 \(durationText)"
        return status.map { time + "，" + $0 } ?? time
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                PlaybackProgressTrack(fraction: fraction, accent: accent, fromRight: fromRight,
                                      enabled: enabled, glow: showGlow, increasedContrast: contrast == .increased)
                    .animation(animateClock ? .linear(duration: 0.18) : nil, value: fraction)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($dragging) { _, state, _ in state = true }
                            .onChanged { gesture in
                                guard enabled else { return }
                                preview = time(at: gesture.location.x, width: geometry.size.width)
                            }
                            .onEnded { gesture in
                                if enabled, geometry.size.width > 0 {
                                    seek(time(at: gesture.location.x, width: geometry.size.width))
                                }
                                preview = nil
                            },
                        including: enabled ? .all : .none
                    )
            }
            .frame(minHeight: 44, maxHeight: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(accessibilityTime)
            .accessibilityHint(enabled ? "向上或向下滑動可調整時間" : "目前無法調整時間")
            .accessibilityAdjustableAction { direction in
                guard enabled else { return }
                let step = min(5, max(1, length / 20))
                switch direction {
                case .increment: seek(clamped(position + step))
                case .decrement: seek(clamped(position - step))
                @unknown default: break
                }
            }
            .accessibilityIdentifier("playbackProgress")

            HStack(spacing: 6) {
                Text(playbackTime(displayedTime))
                    .foregroundStyle(preview == nil ? Color.secondary : accent)
                Spacer(minLength: 4)
                if let status { Text(status) }
                Spacer(minLength: 4)
                Text(durationText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .onChange(of: dragging) { _, active in if !active { preview = nil } }
        .onChange(of: enabled) { _, available in if !available { preview = nil } }
        .onDisappear { preview = nil }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private func clamped(_ time: Double) -> Double { time.isFinite ? min(max(time, 0), length) : 0 }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        guard x.isFinite, width > 0 else { return 0 }
        let location = fromRight ? width - x : x
        return clamped(Double(location / width) * length)
    }
}

private struct PlaybackProgressTrack: View {
    let fraction: Double
    let accent: Color
    let fromRight: Bool
    let enabled: Bool
    let glow: Bool
    let increasedContrast: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let filledWidth = width * CGFloat(min(max(fraction, 0), 1))
            let head = fromRight ? width - filledWidth : filledWidth
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(increasedContrast ? 0.36 : 0.18))
                    .frame(height: 4)
                Capsule().fill(LinearGradient(colors: [accent.opacity(0.6), accent, .white.opacity(0.94)],
                                               startPoint: .leading, endPoint: .trailing))
                    .frame(width: filledWidth, height: 4)
                if enabled && glow {
                    Ellipse().fill(RadialGradient(colors: [accent.opacity(0.57), accent.opacity(0.18), .clear],
                                                  center: .center, startRadius: 0, endRadius: 19))
                        .frame(width: 38, height: 24)
                        .position(x: head, y: geometry.size.height / 2)
                        .opacity(filledWidth > 0 ? 1 : 0)
                }
                if enabled {
                    Circle().fill(.white.opacity(0.96))
                        .frame(width: 7, height: 7)
                        .position(x: head, y: geometry.size.height / 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .accessibilityHidden(true)
    }
}
