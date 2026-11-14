import SwiftUI
import WebKit

// The bundled desktop renderer receives song data once and bounded absolute clock corrections.
struct SonnetStage: View {
    let songID: String
    let title: String
    let artist: String
    let timeline: LyricTimeline
    let revision: UUID
    let position: Double
    let playing: Bool
    var style: String = "sonnet"
    var rendering: Bool = true
    var showsTranslation: Bool = true
    var translationAccent: Color = SyllumePalette.accent
    var diagnosticProbe: DiagnosticStageProbe? = nil
    var clockProbe: Binding<String>? = nil
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ready = false
    @State private var failed = false
    @AppStorage("Folia.EnergySavingAnimation") private var energySaving = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    var body: some View {
        ZStack(alignment: .bottom) {
            SonnetWebView(songID: songID, title: title, artist: artist, timeline: timeline, revision: revision,
                          time: position, playing: playing && scenePhase == .active, reduceMotion: reduceMotion,
                          style: style, energySaving: energySaving || lowPower, rendering: rendering && scenePhase == .active,
                          diagnosticProbe: diagnosticProbe, clockProbe: clockProbe, ready: $ready, failed: $failed)
            if failed { Text("動畫載入失敗，請切換歌詞清單。").font(.callout).foregroundStyle(.orange) }
            else if !ready { ProgressView("正在準備歌詞動畫").frame(maxHeight: .infinity) }
            if showsTranslation, let index = timeline.activeIndex(at: position), let translation = timeline.lines[index].translationText {
                let focus = LyricFocus(line: timeline.lines[index], position: position)
                Text(translation).font(SyllumeLyricFont.text(.callout, size: 16))
                    .foregroundStyle(translationAccent.opacity(reduceMotion || energySaving || lowPower ? 0.94 : 0.76 + 0.23 * focus.presence))
                    .multilineTextAlignment(.center).padding(.horizontal, 24).padding(.bottom, 18)
                    .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}

private struct SonnetWebView: UIViewRepresentable {
    let songID: String
    let title: String
    let artist: String
    let timeline: LyricTimeline
    var lines: [LyricLine] { timeline.lines }
    let revision: UUID
    let time: Double
    let playing: Bool
    let reduceMotion: Bool
    let style: String
    let energySaving: Bool
    let rendering: Bool
    let diagnosticProbe: DiagnosticStageProbe?
    let clockProbe: Binding<String>?
    @Binding var ready: Bool
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "stage")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true
        view.accessibilityLabel = style == "lumiere" ? "繪光歌詞舞台" : "商籟歌詞舞台"
        view.accessibilityIdentifier = style == "lumiere" ? "syllumeLumiereStage" : "syllumeSonnetStage"
        view.accessibilityValue = "載入中"
        context.coordinator.view = view
        diagnosticProbe?.webView = view
        if !context.coordinator.loadStage() { DispatchQueue.main.async { failed = true } }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self; context.coordinator.update()
        var state = failed ? "載入失敗：" + context.coordinator.failureDetail : ready ? "已就緒" : "載入中"
        #if DEBUG
        if ready, clockProbe != nil { context.coordinator.sampleClock() }
        if ready, ProcessInfo.processInfo.arguments.contains("--playback-probe") {
            state += " · " + context.coordinator.lyricFont
        }
        #endif
        view.accessibilityValue = state
        view.accessibilityIdentifier = style == "lumiere" ? "syllumeLumiereStage" : "syllumeSonnetStage"
        let label = style == "lumiere" ? "繪光歌詞舞台" : "商籟歌詞舞台"
        view.accessibilityLabel = timeline.activeIndex(at: time).map { label + "，" + lines[$0].fullText } ?? label
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        if coordinator.parent.diagnosticProbe?.webView === view { coordinator.parent.diagnosticProbe?.webView = nil }
        view.evaluateJavaScript("window.FoliaStage?.stop()", completionHandler: nil)
        view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "stage")
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: SonnetWebView
        weak var view: WKWebView?
        var loadStarted = Date()
        var loaded = false
        var hasRendered = false
        var attemptedRecoveryKey: String?
        var failureDetail = ""
        var lyricFont = ""
        var sentSong = ""
        var lastTime = 0.0
        var lastStamp = Date.distantPast
        var lastPlaying = false
        var lastRendering = true
        #if DEBUG
        private var lastClockProbe = ""
        private var samplingClock = false

        func sampleClock() {
            guard let view, let probe = parent.clockProbe, !samplingClock else { return }
            let key = "\(parent.revision)|\(parent.playing)|\(Int(parent.time * 2))|\(lyricFont)"
            guard key != lastClockProbe else { return }
            lastClockProbe = key
            samplingClock = true
            let songID = parent.songID
            let style = parent.style
            view.callAsyncJavaScript("return window.FoliaStage?.diagnostics() ?? null", arguments: [:],
                                     in: nil, in: .page) { [weak self] result in
                guard let self else { return }
                samplingClock = false
                guard parent.songID == songID, parent.style == style else { return }
                guard case .success(let value) = result, let state = value as? [String: Any],
                      state["canvas"] as? Bool == true, let time = state["time"] as? Double,
                      let playing = state["playing"] as? Bool else { lastClockProbe = ""; return }
                let sample = String(format: "%.3f|%@|%@", time, playing ? "playing" : "paused", lyricFont)
                if probe.wrappedValue != sample { probe.wrappedValue = sample }
            }
        }
        #endif
        init(_ parent: SonnetWebView) { self.parent = parent }
        func update() {
            guard loaded, let view else { return }
            // Covered/background stages receive one stop, then no lyric builds or seek redraws.
            guard parent.rendering else {
                if lastRendering {
                    lastRendering = false; lastPlaying = false; lastTime = parent.time; lastStamp = Date()
                    view.callAsyncJavaScript("window.FoliaStage.setClock(snapshot)", arguments: ["snapshot":
                        ["time": parent.time, "playing": false, "reduceMotion": parent.reduceMotion]],
                        in: nil, in: .page, completionHandler: nil)
                }
                return
            }
            let wasSuspended = !lastRendering
            lastRendering = true
            let key = [parent.songID, parent.revision.uuidString, parent.style, String(parent.energySaving), String(parent.reduceMotion), parent.title, parent.artist].joined(separator: "|")
            let songChanged = sentSong != key
            if songChanged {
                sentSong = key; failureDetail = ""
                DispatchQueue.main.async { self.parent.ready = false; self.parent.failed = false }
                let data = try? JSONEncoder().encode(parent.lines)
                let lines = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
                let song: [String: Any] = ["id": parent.songID, "title": parent.title, "artist": parent.artist,
                    "reduceMotion": parent.reduceMotion, "style": parent.style, "energySaving": parent.energySaving, "lines": lines]
                view.callAsyncJavaScript("window.FoliaStage.setSong(song)", arguments: ["song": song], in: nil, in: .page, completionHandler: nil)
                lastStamp = .distantPast
            }
            let elapsed = Date().timeIntervalSince(lastStamp)
            let expected = lastTime + (lastPlaying ? elapsed : 0)
            let needsTime = parent.playing ? elapsed >= 0.2 || abs(expected - parent.time) > 0.25 : abs(lastTime - parent.time) > 0.001
            if songChanged || wasSuspended || needsTime || lastPlaying != parent.playing {
                lastTime = parent.time; lastPlaying = parent.playing; lastStamp = Date()
                view.callAsyncJavaScript("window.FoliaStage.setClock(snapshot)", arguments: ["snapshot":
                    ["time": parent.time, "playing": parent.playing, "reduceMotion": parent.reduceMotion]],
                    in: nil, in: .page, completionHandler: nil)
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "loaded" { markLoaded() }
            else if type == "font" {
                lyricFont = body["detail"] as? String ?? ""
                if let probe = currentProbe { probe.font = lyricFont }
            } else if type == "ready" {
                hasRendered = true
                parent.ready = true; parent.failed = false
                if let probe = currentProbe { probe.readyCount += 1 }
                else if parent.diagnosticProbe == nil { DiagnosticsEvents.shared.record(.stageReady, source: stageSource, since: loadStarted) }
            } else if type == "error" {
                failureDetail = body["detail"] as? String ?? ""
                markFailure(canReload: true)
            }
        }

        func loadStage() -> Bool {
            guard let view, let file = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "SyllumeStage") else { return false }
            loadStarted = Date()
            view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
            return true
        }

        private func markLoaded() {
            guard !loaded else { return }
            loaded = true; update()
        }
        private var stageSource: DiagnosticSource { parent.style == "lumiere" ? .lumiere : .sonnet }
        private var currentProbe: DiagnosticStageProbe? {
            guard let probe = parent.diagnosticProbe, let view, probe.webView === view else { return nil }
            return probe
        }
        private func markFailure(canReload: Bool = false) {
            let problem = DiagnosticProblem(code: .engine)
            if parent.diagnosticProbe == nil { DiagnosticsEvents.shared.record(.stageError, source: stageSource, problem: problem) }
            if canReload, hasRendered, loaded, !sentSong.isEmpty, attemptedRecoveryKey != sentSong {
                // A failed renderer swap can leave the page in a partial state. Rebuild once
                // from the latest song and clock, then surface any repeat failure.
                attemptedRecoveryKey = sentSong
                loaded = false; sentSong = ""; lastStamp = .distantPast; lastRendering = true
                parent.ready = false
                if loadStage() {
                    currentProbe?.recoveries += 1
                    return
                }
            }
            parent.failed = true
            currentProbe?.fault = problem
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { markFailure(canReload: true) }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("typeof window.FoliaStage") { [weak self] result, _ in
                guard let self else { return }
                if result as? String == "object" { markLoaded() }
                else { markFailure() }
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { markFailure() }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { markFailure() }
        }
    }
}
