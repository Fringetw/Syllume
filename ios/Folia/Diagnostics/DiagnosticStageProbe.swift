import SwiftUI
import WebKit

@MainActor @Observable
final class DiagnosticStageProbe {
    struct Input {
        let style: DiagnosticSource
        let timeline: LyricTimeline
        var songID = "diagnostics-tide"
        var revision = UUID()
        var position: Double = 0
        var playing = false
        var rendering = true
    }

    var input: Input?
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored var fault: DiagnosticProblem?
    @ObservationIgnored var font: String?
    @ObservationIgnored var readyCount = 0

    func reset() {
        input = nil; webView = nil; font = nil; fault = nil; readyCount = 0
    }

    func inspect(_ style: DiagnosticSource, timeline: LyricTimeline) async -> [DiagnosticCheck] {
        reset()
        let began = Date()
        input = Input(style: style, timeline: timeline)
        defer { reset() }
        let key = "animation." + style.rawValue
        var results: [DiagnosticCheck] = []
        do {
            try await waitForReady(1)
            let loaded = try await snapshot()
            let rightRenderer = loaded["style"] as? String == style.rawValue && loaded["canvas"] as? Bool == true
            results.append(DiagnosticCheck(key + ".init", style.title + "初始化", rightRenderer ? .passed : .failed,
                .bundledSample, since: began, problem: rightRenderer ? nil : DiagnosticProblem(code: .engine)))
            let fontLoaded = font == "GenSenRounded2JP-M" && FoliaLyricFont.registeredName == "GenSenRounded2JP-M"
            results.append(DiagnosticCheck(key + ".font", style.title + "源泉圓體 JP", fontLoaded ? .passed : .failed,
                .bundledSample, problem: fontLoaded ? nil : DiagnosticProblem(code: .engine)))
            if !rightRenderer { return results }
            let beganClock = Date()
            input?.position = 2
            input?.playing = true
            try await Task.sleep(for: .milliseconds(350))
            let moving = try await snapshot()
            let frames = try await frameSample()
            input?.position = 4
            input?.playing = false
            try await Task.sleep(for: .milliseconds(180))
            let paused = try await snapshot()
            try await Task.sleep(for: .milliseconds(230))
            let settled = try await snapshot()
            input?.position = 11.2
            try await Task.sleep(for: .milliseconds(220))
            let sought = try await snapshot()
            input?.playing = true
            try await Task.sleep(for: .milliseconds(180))
            let resumed = try await snapshot()
            input?.rendering = false
            try await Task.sleep(for: .milliseconds(180))
            let suspended = try await snapshot()
            input?.rendering = true
            input?.position = 0
            input?.playing = false
            input?.songID = "diagnostics-tide-next"
            input?.revision = UUID()
            try await waitForReady(2)
            let next = try await snapshot()
            let pausedClock = abs(number(paused, "time") - number(settled, "time")) < 0.05
            let matches = moving["playing"] as? Bool == true && number(moving, "time") > 2
                && paused["paused"] as? Bool == true && pausedClock
                && abs(number(sought, "time") - 11.2) < 0.15 && number(resumed, "time") > 11.2
                && suspended["paused"] as? Bool == true && next["canvas"] as? Bool == true
                && abs(number(next, "time")) < 0.15
            results.append(DiagnosticCheck(key + ".clock", style.title + "播放、暫停、續播、拖曳與切歌時鐘",
                matches ? .passed : .failed, .simulatedInput, since: beganClock,
                problem: matches ? nil : DiagnosticProblem(code: .timeline),
                note: "使用內建歌詞與控制時鐘，涵蓋暫停渲染及重新顯示。",
                metrics: ["seekError_s": abs(number(sought, "time") - 11.2)]))
            results.append(DiagnosticCheck(key + ".frames", style.title + "畫面更新取樣", frames.isEmpty ? .unverifiable : .passed,
                .bundledSample, problem: frames.isEmpty ? DiagnosticProblem(code: .noData) : nil,
                note: "量測前景 WebKit 的畫面回呼與超過 33ms 的間隔，GPU 實際呈現幀數由系統掌握。", metrics: frames))
        } catch {
            results.append(DiagnosticCheck(key + ".runtime", style.title + "渲染與時鐘", .failed, .bundledSample, since: began,
                problem: DiagnosticProblem.classify(error, fallback: .engine)))
        }
        return results
    }

    private func waitForReady(_ count: Int) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 13
        while readyCount < count {
            try Task.checkCancellation()
            if let fault { throw fault }
            guard ProcessInfo.processInfo.systemUptime < end else { throw DiagnosticProblem(code: .timeout) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func snapshot() async throws -> [String: Any] {
        if let fault { throw fault }
        let data = try await evaluate("return JSON.stringify(window.FoliaStage?.diagnostics() ?? {});")
        guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DiagnosticProblem(code: .engine)
        }
        return snapshot
    }

    private func frameSample() async throws -> [String: Double] {
        let raw = try await evaluate("""
            return JSON.stringify(await new Promise(resolve => {
              let start = performance.now(), last = 0, count = 0, slow = 0, done = false, id;
              function finish() {
                if (done) return;
                done = true;
                cancelAnimationFrame(id);
                clearTimeout(timer);
                resolve(count > 1 ? {callbackFPS: 1000 * count / (performance.now() - start), gapsOver33ms: slow} : {});
              }
              const timer = setTimeout(finish, 1300);
              function frame(now) {
                if (last && now - last > 33) slow++;
                last = now;
                count++;
                if (performance.now() - start >= 700) finish();
                else id = requestAnimationFrame(frame);
              }
              id = requestAnimationFrame(frame);
            }));
            """)
        return ((try JSONSerialization.jsonObject(with: raw)) as? [String: NSNumber] ?? [:]).mapValues(\.doubleValue)
    }

    private func evaluate(_ script: String) async throws -> Data {
        guard let webView else { throw DiagnosticProblem(code: .engine) }
        return try await StageEvaluation().run(script, in: webView)
    }

    private func number(_ value: [String: Any], _ key: String) -> Double { value[key] as? Double ?? .infinity }
}

@MainActor
private final class StageEvaluation {
    private var waiting: CheckedContinuation<Data, Error>?
    private var timer: Task<Void, Never>?

    func run(_ script: String, in view: WKWebView) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiting = continuation
                timer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(4)) }
                    catch { return }
                    self?.complete(.failure(DiagnosticProblem(code: .timeout)))
                }
                view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
                    let data = result.flatMap { reply -> Result<Data, Error> in
                        guard let json = reply as? String, json.utf8.count <= 16_000 else {
                            return .failure(DiagnosticProblem(code: .engine))
                        }
                        return .success(Data(json.utf8))
                    }
                    self?.complete(data)
                }
            }
        } onCancel: {
            Task { @MainActor in self.complete(.failure(CancellationError())) }
        }
    }

    private func complete(_ result: Result<Data, Error>) {
        guard let waiting else { return }
        self.waiting = nil
        timer?.cancel(); timer = nil
        waiting.resume(with: result)
    }
}

struct DiagnosticStagePreview: View {
    let probe: DiagnosticStageProbe

    var body: some View {
        if let sample = probe.input {
            SonnetStage(songID: sample.songID, title: "潮汐之間", artist: "Folia",
                        timeline: sample.timeline, revision: sample.revision, position: sample.position,
                        playing: sample.playing, style: sample.style.rawValue, rendering: sample.rendering,
                        showsTranslation: false, diagnosticProbe: probe)
                .id(sample.style)
                .frame(height: 185)
                .background(FoliaPalette.surface)
                .clipShape(.rect(cornerRadius: 16))
                .accessibilityHidden(true)
        }
    }
}
