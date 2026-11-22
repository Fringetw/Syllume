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
        if ready, context.coordinator.attemptedRecovery,
           ProcessInfo.processInfo.arguments.contains("--stage-initialization-fails-once") {
            state += " · 已重試"
        }
        #endif
        view.accessibilityValue = state
        view.accessibilityIdentifier = style == "lumiere" ? "syllumeLumiereStage" : "syllumeSonnetStage"
        let label = style == "lumiere" ? "繪光歌詞舞台" : "商籟歌詞舞台"
        view.accessibilityLabel = timeline.activeIndex(at: time).map { label + "，" + lines[$0].fullText } ?? label
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        if coordinator.parent.diagnosticProbe?.webView === view { coordinator.parent.diagnosticProbe?.webView = nil }
        coordinator.dismantle(view)
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private enum State { case loading, ready, failed }

        var parent: SonnetWebView
        weak var view: WKWebView?
        private(set) var failureDetail = ""
        private(set) var lyricFont = ""
        private var state = State.loading
        private var navigation: WKNavigation?
        private var loaded = false
        private var activeSong = ""
        private var request: UUID?
        private(set) var attemptedRecovery = false
        private var initializationTimeout: Task<Void, Never>?
        private var loadStarted = Date()
        private var lastTime = 0.0
        private var lastStamp = Date.distantPast
        private var lastPlaying = false
        private var lastRendering = false
        #if DEBUG
        private var lastClockProbe = ""
        private var clockRequest: UUID?
        private var injectedInitializationFailure = false

        func sampleClock() {
            guard let view, let probe = parent.clockProbe, parent.rendering, state == .ready, clockRequest == nil else { return }
            let key = "\(parent.revision)|\(parent.playing)|\(Int(parent.time * 2))|\(lyricFont)"
            guard key != lastClockProbe else { return }
            lastClockProbe = key
            let request = UUID()
            clockRequest = request
            let song = activeSong
            view.callAsyncJavaScript("return window.FoliaStage?.diagnostics() ?? null", arguments: [:],
                                     in: nil, in: .page) { [weak self] result in
                guard let self, clockRequest == request else { return }
                clockRequest = nil
                guard parent.rendering, state == .ready, activeSong == song else { return }
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
            guard let view else { return }
            guard parent.rendering else {
                if lastRendering {
                    lastRendering = false
                    cancelInitialization()
                    if state == .loading { discardPage(in: view) }
                    else if loaded { sendClock(to: view, playing: false) }
                }
                return
            }
            let wasSuspended = !lastRendering
            lastRendering = true
            if activeSong != songKey {
                // A page still building the previous song can emit an untagged ready message.
                if request != nil { discardPage(in: view) }
                cancelInitialization()
                activeSong = songKey
                attemptedRecovery = false
                failureDetail = ""
                currentProbe?.fault = nil
                transition(to: .loading)
            } else if wasSuspended { transition(to: state) }
            guard state != .failed else { return }
            if state == .loading { startInitialization() }
            guard loaded else {
                if navigation == nil { loadStage(in: view) }
                return
            }
            let sendSong = state == .loading && request == nil
            if sendSong { initializeSong(in: view) }

            let elapsed = Date().timeIntervalSince(lastStamp)
            let expected = lastTime + (lastPlaying ? elapsed : 0)
            let needsTime = parent.playing ? elapsed >= 0.2 || abs(expected - parent.time) > 0.25 : abs(lastTime - parent.time) > 0.001
            if sendSong || wasSuspended || needsTime || lastPlaying != parent.playing {
                sendClock(to: view, playing: parent.playing)
            }
        }

        private var songKey: String {
            [parent.songID, parent.revision.uuidString, parent.style, String(parent.energySaving), String(parent.reduceMotion),
             parent.title, parent.artist].joined(separator: "|")
        }

        private func initializeSong(in view: WKWebView) {
            let request = UUID()
            self.request = request
            let data = try? JSONEncoder().encode(parent.lines)
            let lines = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
            let song: [String: Any] = ["id": parent.songID, "title": parent.title, "artist": parent.artist,
                "reduceMotion": parent.reduceMotion, "style": parent.style, "energySaving": parent.energySaving, "lines": lines]
            var script = "await window.FoliaStage.setSong(song); return true;"
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--stage-initialization-stall") {
                script = "window.syllumeInitializationFixture = new Promise(() => {}); return await window.syllumeInitializationFixture;"
            } else if arguments.contains("--stage-initialization-fails-once"), !injectedInitializationFailure {
                injectedInitializationFailure = true
                script = "throw new Error('Injected stage initialization failure')"
            }
            #endif
            view.callAsyncJavaScript(script, arguments: ["song": song], in: nil, in: .page) { [weak self] result in
                guard let self, self.request == request, parent.rendering, activeSong == songKey else { return }
                if case .failure = result { markFailure("無法啟動歌詞動畫。") }
            }
        }

        private func sendClock(to view: WKWebView, playing: Bool) {
            lastTime = parent.time; lastPlaying = playing; lastStamp = Date()
            view.callAsyncJavaScript("window.FoliaStage.setClock(snapshot)", arguments: ["snapshot":
                ["time": parent.time, "playing": playing, "reduceMotion": parent.reduceMotion]],
                in: nil, in: .page, completionHandler: nil)
        }

        private func startInitialization() {
            guard initializationTimeout == nil else { return }
            loadStarted = Date()
            // A reload shares the same visible deadline as the original attempt.
            initializationTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                self?.markFailure("等候歌詞動畫逾時。", code: .timeout, mayReload: false)
            }
        }

        private func cancelInitialization() {
            initializationTimeout?.cancel()
            initializationTimeout = nil
        }

        private func transition(to state: State) {
            self.state = state
            // updateUIView can request a transition while SwiftUI is updating its view tree.
            DispatchQueue.main.async { [weak self] in
                guard let self, view != nil, parent.rendering else { return }
                let ready = self.state == .ready
                let failed = self.state == .failed
                if parent.ready != ready { parent.ready = ready }
                if parent.failed != failed { parent.failed = failed }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.webView === view, message.frameInfo.isMainFrame, loaded, request != nil,
                  parent.rendering, state == .loading, activeSong == songKey,
                  let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "font" {
                lyricFont = body["detail"] as? String ?? ""
                if let probe = currentProbe { probe.font = lyricFont }
            } else if type == "ready" {
                request = nil
                cancelInitialization()
                transition(to: .ready)
                if let probe = currentProbe { probe.readyCount += 1 }
                else if parent.diagnosticProbe == nil { DiagnosticsEvents.shared.record(.stageReady, source: stageSource, since: loadStarted) }
            } else if type == "error" {
                markFailure(body["detail"] as? String ?? "無法啟動歌詞動畫。")
            }
        }

        private func loadStage(in view: WKWebView) {
            guard let file = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "SyllumeStage") else {
                markFailure("找不到歌詞動畫資源。", mayReload: false)
                return
            }
            navigation = view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
            if navigation == nil { markFailure("無法開啟歌詞動畫。", mayReload: false) }
        }

        private func discardPage(in view: WKWebView) {
            let wasLoaded = loaded
            navigation = nil
            loaded = false
            request = nil
            lastStamp = .distantPast
            lyricFont = ""
            #if DEBUG
            clockRequest = nil
            lastClockProbe = ""
            #endif
            if wasLoaded { view.evaluateJavaScript("window.FoliaStage?.stop()", completionHandler: nil) }
            view.stopLoading()
        }

        func dismantle(_ view: WKWebView) {
            self.view = nil
            cancelInitialization()
            discardPage(in: view)
            view.navigationDelegate = nil
            view.configuration.userContentController.removeScriptMessageHandler(forName: "stage")
        }

        private var stageSource: DiagnosticSource { parent.style == "lumiere" ? .lumiere : .sonnet }
        private var currentProbe: DiagnosticStageProbe? {
            guard let probe = parent.diagnosticProbe, let view, probe.webView === view else { return nil }
            return probe
        }

        private func markFailure(_ detail: String, code: DiagnosticCode = .engine, mayReload: Bool = true) {
            guard let view, parent.rendering, state != .failed, activeSong == songKey else { return }
            let problem = DiagnosticProblem(code: code)
            if parent.diagnosticProbe == nil { DiagnosticsEvents.shared.record(.stageError, source: stageSource, problem: problem) }
            discardPage(in: view)
            if mayReload, !attemptedRecovery {
                attemptedRecovery = true
                currentProbe?.recoveries += 1
                transition(to: .loading)
                startInitialization()
                loadStage(in: view)
                return
            }
            cancelInitialization()
            failureDetail = detail
            currentProbe?.fault = problem
            transition(to: .failed)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard webView === view else { return }
            if parent.rendering { markFailure("歌詞動畫程序已中止。") }
            else if state != .failed {
                discardPage(in: webView)
                transition(to: .loading)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard webView === view, let navigation, navigation === self.navigation, parent.rendering else { return }
            webView.evaluateJavaScript("typeof window.FoliaStage?.setSong") { [weak self] result, _ in
                guard let self, navigation === self.navigation, parent.rendering, state == .loading else { return }
                if result as? String == "function" {
                    loaded = true
                    update()
                } else { markFailure("找不到歌詞動畫橋接。") }
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard webView === view, let navigation, navigation === self.navigation,
                  (error as NSError).code != NSURLErrorCancelled else { return }
            markFailure("無法載入歌詞動畫。")
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.webView(webView, didFail: navigation, withError: error)
        }
    }
}
