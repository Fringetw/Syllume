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
    @ObservationIgnored var recoveries = 0

    func reset() {
        input = nil; webView = nil; font = nil; fault = nil; readyCount = 0; recoveries = 0
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
            guard loaded["style"] as? String == style.rawValue, loaded["canvas"] as? Bool == true else {
                throw DiagnosticProblem(code: .engine)
            }
            results.append(DiagnosticCheck(key + ".init", style.title + "初始化", .passed, .bundledSample, since: began))
        } catch {
            return [DiagnosticCheck(key + ".init", style.title + "初始化", .failed, .bundledSample, since: began,
                problem: DiagnosticProblem.classify(error, fallback: .engine))]
        }

        let fontLoaded = font == "GenSenRounded2JP-M" && FoliaLyricFont.registeredName == "GenSenRounded2JP-M"
        results.append(DiagnosticCheck(key + ".font", style.title + "源泉圓體 JP", fontLoaded ? .passed : .failed,
            .bundledSample, problem: fontLoaded ? nil : DiagnosticProblem(code: .engine)))
        results.append(await inspectClock(key, title: style.title))
        if !Task.isCancelled {
            let start = Date()
            input?.playing = true
            do {
                let frames = try await frameSample()
                results.append(DiagnosticCheck(key + ".frames", style.title + "畫面更新取樣",
                    frames.isEmpty ? .unverifiable : .passed, .bundledSample, since: start,
                    problem: frames.isEmpty ? DiagnosticProblem(code: .noData) : nil,
                    note: "量測前景 WebKit 的畫面回呼與超過 33ms 的間隔。", metrics: frames))
            } catch {
                results.append(DiagnosticCheck(key + ".frames", style.title + "畫面更新取樣", .unverifiable,
                    .bundledSample, since: start, problem: DiagnosticProblem.classify(error, fallback: .engine)))
            }
        }
        return results
    }

    private func inspectClock(_ key: String, title: String) async -> DiagnosticCheck {
        let start = Date()
        let title = title + "播放、暫停、續播、拖曳與切歌時鐘"
        var checkpoint = "開始播放"
        do {
            input?.position = 2
            input?.playing = true
            _ = try await waitForClock { $0["playing"] as? Bool == true && number($0, "time") > 2 }
            checkpoint = "暫停"
            input?.position = 4
            input?.playing = false
            let paused = try await waitForClock { $0["paused"] as? Bool == true && abs(number($0, "time") - 4) < 0.15 }
            try await Task.sleep(for: .milliseconds(250))
            let settled = try await snapshot()
            guard abs(number(paused, "time") - number(settled, "time")) < 0.05 else { throw DiagnosticProblem(code: .timeline) }

            checkpoint = "拖曳"
            input?.position = 11.2
            let sought = try await waitForClock { abs(number($0, "time") - 11.2) < 0.15 }
            checkpoint = "續播"
            input?.playing = true
            _ = try await waitForClock { $0["playing"] as? Bool == true && number($0, "time") > 11.2 }
            checkpoint = "停止渲染"
            input?.rendering = false
            _ = try await waitForClock { $0["paused"] as? Bool == true && $0["playing"] as? Bool == false }

            checkpoint = "換歌與重新顯示"
            input?.rendering = true
            input?.position = 0
            input?.playing = false
            input?.songID = "diagnostics-tide-next"
            input?.revision = UUID()
            try await waitForReady(2)
            _ = try await waitForClock { $0["canvas"] as? Bool == true && abs(number($0, "time")) < 0.15 }
            return DiagnosticCheck(key + ".clock", title, .passed, .simulatedInput, since: start,
                note: "使用內建歌詞與控制時鐘，涵蓋暫停渲染及重新顯示。",
                metrics: ["seekError_s": abs(number(sought, "time") - 11.2), "rendererRecoveries": Double(recoveries)])
        } catch {
            return DiagnosticCheck(key + ".clock", title, .failed, .simulatedInput, since: start,
                problem: DiagnosticProblem.classify(error, fallback: .engine), note: "失敗階段：\(checkpoint)")
        }
    }

    private func waitForReady(_ count: Int) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 24
        while readyCount < count {
            try Task.checkCancellation()
            if let fault { throw fault }
            guard ProcessInfo.processInfo.systemUptime < end else { throw DiagnosticProblem(code: .timeout) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func waitForClock(_ matches: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let end = ProcessInfo.processInfo.systemUptime + 10
        repeat {
            try Task.checkCancellation()
            let state = try await snapshot()
            if matches(state) { return state }
            try await Task.sleep(for: .milliseconds(150))
        } while ProcessInfo.processInfo.systemUptime < end
        throw DiagnosticProblem(code: .timeline)
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
                    do { try await Task.sleep(for: .seconds(9)) }
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
