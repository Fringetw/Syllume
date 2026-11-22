import SwiftUI
import WebKit

// The bundled desktop renderer receives song data once and bounded absolute clock corrections.
struct SonnetStage: View {
    static let initializationLimit: Duration = .seconds(36)

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
            if !ready {
                VStack(spacing: 12) {
                    if let index = timeline.activeIndex(at: position) {
                        Text(timeline.lines[index].fullText)
                            .font(SyllumeLyricFont.text(.title2, size: 26))
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("animatedLyricsFallback")
                    }
                    if failed {
                        Text("動畫載入失敗，改顯示同步歌詞。").font(.caption).foregroundStyle(.orange)
                    } else {
                        ProgressView("正在準備歌詞動畫").font(.caption)
                    }
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
        if ready, context.coordinator.didRetrySongCommand,
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
        private enum InitializationPhase: Int {
            case navigation, bridge, font

            var timeAllowance: Duration {
                switch self {
                case .navigation, .bridge: .seconds(18)
                case .font: .seconds(16)
                }
            }
        }

        var parent: SonnetWebView
        weak var view: WKWebView?
        private(set) var failureDetail = ""
        private(set) var lyricFont = ""
        private var state = State.loading
        private var navigation: WKNavigation?
        private var documentID: UUID?
        private var loaded = false
        private var activeSong = ""
        private var request: UUID?
        private(set) var didRetrySongCommand = false
        private var attemptedReload = false
        private var initializationTimeout: Task<Void, Never>?
        private var initializationDeadline: ContinuousClock.Instant?
        private var initializationPhase = InitializationPhase.navigation
        private var loadStarted = Date()
        private var lastTime = 0.0
        private var lastStamp = Date.distantPast
        private var lastPlaying = false
        private var lastRendering = false
        #if DEBUG
        private static let bootCheckpoints: Set<String> = [
            "runtime-create", "runtime-returned", "runtime-reuse", "runtime-reused",
            "program-start", "program-compiled", "pixi-import", "pixi-imported",
            "webgl-request", "webgl-created", "webgl-unavailable", "webgl-extensions-ready",
            "renderer-init", "renderer-initialized", "assets-start", "assets-ready", "scene-start",
            "shader-link", "shader-extension", "shader-candidates", "shader-polling",
            "shader-linked", "shader-deferred", "first-frame"
        ]
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
                didRetrySongCommand = false
                attemptedReload = false
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
            if sendSong || wasSuspended || lastPlaying != parent.playing || (state == .ready && needsTime) {
                sendClock(to: view, playing: parent.playing)
            }
        }

        private var songKey: String {
            [parent.songID, parent.revision.uuidString, parent.style, String(parent.energySaving), String(parent.reduceMotion),
             parent.title, parent.artist].joined(separator: "|")
        }

        private func initializeSong(in view: WKWebView) {
            guard let documentID else { return }
            advanceInitialization(to: .bridge)
            let request = UUID()
            self.request = request
            let data = try? JSONEncoder().encode(parent.lines)
            let lines = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
            var song: [String: Any] = ["id": parent.songID, "title": parent.title, "artist": parent.artist,
                "reduceMotion": parent.reduceMotion, "style": parent.style, "energySaving": parent.energySaving, "lines": lines]
            let traceID: String?
            var script = "await window.FoliaStage.setSong(song); return true;"
            #if DEBUG
            traceID = request.uuidString
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--stage-initialization-stall") {
                script = "window.syllumeInitializationFixture = new Promise(() => {}); return await window.syllumeInitializationFixture;"
            } else if arguments.contains("--stage-initialization-fails-once"), !injectedInitializationFailure {
                injectedInitializationFailure = true
                script = "throw new Error('Injected stage initialization failure')"
            }
            #else
            traceID = nil
            #endif
            if let traceID { song["traceID"] = traceID }
            stageCheckpoint("song-dispatch")
            let command = "if (window.syllumeStageDocumentID !== documentID) return false; " + script
            view.callAsyncJavaScript(command, arguments: ["documentID": documentID.uuidString, "song": song],
                                     in: nil, in: .page) { [weak self, weak view] result in
                guard let self, let view, view === self.view, self.request == request, self.documentID == documentID,
                      loaded, parent.rendering, activeSong == songKey, case .failure(let error) = result else { return }
                stageCheckpoint("song-rejected \((error as NSError).code)")
                // The document already has a verified bridge. Reissue the command without reloading it.
                if !didRetrySongCommand {
                    didRetrySongCommand = true
                    currentProbe?.recoveries += 1
                    stageCheckpoint("song-retry")
                    initializeSong(in: view)
                } else { markFailure("無法啟動歌詞動畫。", mayReload: false) }
            }
        }

        private func sendClock(to view: WKWebView, playing: Bool) {
            guard let documentID else { return }
            lastTime = parent.time; lastPlaying = playing; lastStamp = Date()
            view.callAsyncJavaScript("if (window.syllumeStageDocumentID === documentID) window.FoliaStage.setClock(snapshot)",
                arguments: ["documentID": documentID.uuidString, "snapshot":
                    ["time": parent.time, "playing": playing, "reduceMotion": parent.reduceMotion]],
                in: nil, in: .page, completionHandler: nil)
        }

        private func startInitialization() {
            guard initializationDeadline == nil else { return }
            loadStarted = Date()
            initializationPhase = .navigation
            initializationDeadline = ContinuousClock.now.advanced(by: SonnetStage.initializationLimit)
            scheduleInitializationTimeout()
        }

        private func advanceInitialization(to phase: InitializationPhase) {
            guard initializationDeadline != nil, phase.rawValue > initializationPhase.rawValue else { return }
            initializationPhase = phase
            scheduleInitializationTimeout()
        }

        private func scheduleInitializationTimeout() {
            guard let initializationDeadline else { return }
            // WebKit milestones earn time for the next step. Retries share the absolute cap.
            let phaseDeadline = ContinuousClock.now.advanced(by: initializationPhase.timeAllowance)
            let deadline = min(phaseDeadline, initializationDeadline)
            initializationTimeout?.cancel()
            initializationTimeout = Task { [weak self] in
                do { try await ContinuousClock().sleep(until: deadline) }
                catch { return }
                self?.markFailure("等候歌詞動畫逾時。", code: .timeout, mayReload: false)
            }
        }

        private func cancelInitialization() {
            initializationTimeout?.cancel()
            initializationTimeout = nil
            initializationDeadline = nil
        }

        private func stageCheckpoint(_ event: String) {
            #if DEBUG
            let elapsed = Date().timeIntervalSince(loadStarted)
            NSLog("[SyllumeStage] %@ %@ %.3fs", stageSource.rawValue, event, elapsed)
            #endif
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
            guard message.webView === view, message.frameInfo.isMainFrame, let documentID,
                  parent.rendering, state == .loading, activeSong == songKey,
                  let body = message.body as? [String: Any], body["documentID"] as? String == documentID.uuidString,
                  let type = body["type"] as? String else { return }
            if type == "loaded" {
                guard !loaded else { return }
                stageCheckpoint("bridge-ready")
                loaded = true
                update()
                return
            }
            guard loaded, request != nil else { return }
            #if DEBUG
            if type == "boot", let request, let detail = body["detail"] as? String {
                let parts = detail.split(separator: "|")
                guard parts.count == 3, UUID(uuidString: String(parts[0])) == request,
                      Self.bootCheckpoints.contains(String(parts[1])), let milliseconds = Int(parts[2]),
                      (0...60_000).contains(milliseconds) else { return }
                stageCheckpoint("boot-\(parts[1]) js=\(milliseconds)ms")
                return
            }
            #endif
            if type == "font" {
                lyricFont = body["detail"] as? String ?? ""
                stageCheckpoint(lyricFont == "GenSenRounded2JP-M" ? "font-bundled" : "font-fallback")
                advanceInitialization(to: .font)
                if let probe = currentProbe { probe.font = lyricFont }
            } else if type == "ready" {
                stageCheckpoint("ready")
                request = nil
                cancelInitialization()
                transition(to: .ready)
                if let view { sendClock(to: view, playing: parent.playing) }
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
            let documentID = UUID()
            self.documentID = documentID
            let content = view.configuration.userContentController
            content.removeAllUserScripts()
            content.addUserScript(WKUserScript(source: "window.syllumeStageDocumentID = '\(documentID.uuidString)';",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            stageCheckpoint("navigation-start")
            navigation = view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
            if navigation == nil { markFailure("無法開啟歌詞動畫。", mayReload: false) }
        }

        private func discardPage(in view: WKWebView) {
            let closedDocument = loaded ? documentID : nil
            navigation = nil
            documentID = nil
            loaded = false
            request = nil
            lastStamp = .distantPast
            lyricFont = ""
            #if DEBUG
            clockRequest = nil
            lastClockProbe = ""
            #endif
            if let closedDocument {
                // This command can still be queued when the replacement page starts.
                view.callAsyncJavaScript("if (window.syllumeStageDocumentID === documentID) window.FoliaStage?.stop()",
                    arguments: ["documentID": closedDocument.uuidString], in: nil, in: .page, completionHandler: nil)
            }
            view.stopLoading()
        }

        func dismantle(_ view: WKWebView) {
            self.view = nil
            cancelInitialization()
            discardPage(in: view)
            view.navigationDelegate = nil
            view.configuration.userContentController.removeAllUserScripts()
            view.configuration.userContentController.removeScriptMessageHandler(forName: "stage")
        }

        private var stageSource: DiagnosticSource { parent.style == "lumiere" ? .lumiere : .sonnet }
        private var currentProbe: DiagnosticStageProbe? {
            guard let probe = parent.diagnosticProbe, let view, probe.webView === view else { return nil }
            return probe
        }

        private func markFailure(_ detail: String, code: DiagnosticCode = .engine, mayReload: Bool = true) {
            guard let view, parent.rendering, state != .failed, activeSong == songKey else { return }
            stageCheckpoint(code == .timeout ? "timeout" : "failure")
            let problem = DiagnosticProblem(code: code)
            if parent.diagnosticProbe == nil { DiagnosticsEvents.shared.record(.stageError, source: stageSource, problem: problem) }
            discardPage(in: view)
            if mayReload, !attemptedReload {
                attemptedReload = true
                currentProbe?.recoveries += 1
                stageCheckpoint("navigation-reload")
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
            stageCheckpoint("navigation-finished")
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
