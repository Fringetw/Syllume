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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ready = false
    @State private var failed = false

    var body: some View {
        ZStack(alignment: .bottom) {
            SonnetWebView(songID: songID, title: title, artist: artist, timeline: timeline, revision: revision,
                          time: position, playing: playing && scenePhase == .active, reduceMotion: reduceMotion,
                          ready: $ready, failed: $failed)
            if failed { Text("動畫載入失敗，請切換歌詞清單。").font(.callout).foregroundStyle(.orange) }
            else if !ready { ProgressView("正在準備歌詞動畫").frame(maxHeight: .infinity) }
            if let index = timeline.activeIndex(at: position), let translation = timeline.lines[index].translation {
                Text(translation).font(.callout).foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center).padding(.horizontal, 24).padding(.bottom, 18)
                    .allowsHitTesting(false)
            }
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
        view.accessibilityLabel = "商籟歌詞舞台"
        view.accessibilityIdentifier = "foliaSonnetStage"
        view.accessibilityValue = "載入中"
        context.coordinator.view = view
        if let file = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "FoliaStage") {
            view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        } else { DispatchQueue.main.async { failed = true } }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self; context.coordinator.update()
        view.accessibilityValue = failed ? "載入失敗" : ready ? "已就緒" : "載入中"
        if let index = timeline.activeIndex(at: time) {
            view.accessibilityLabel = "商籟歌詞舞台，" + lines[index].fullText
        }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.evaluateJavaScript("window.FoliaStage?.stop()", completionHandler: nil)
        view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "stage")
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: SonnetWebView
        weak var view: WKWebView?
        var loaded = false
        var sentSong = ""
        var lastTime = 0.0
        var lastStamp = Date.distantPast
        var lastPlaying = false
        init(_ parent: SonnetWebView) { self.parent = parent }
        func update() {
            guard loaded, let view else { return }
            let key = [parent.songID, parent.revision.uuidString, String(parent.reduceMotion), parent.title, parent.artist].joined(separator: "|")
            if sentSong != key {
                sentSong = key
                DispatchQueue.main.async { self.parent.ready = false; self.parent.failed = false }
                let song: [String: Any] = ["id": parent.songID, "title": parent.title, "artist": parent.artist,
                    "reduceMotion": parent.reduceMotion, "lines": parent.lines.map { line -> [String: Any] in
                        ["startTime": line.startTime, "endTime": line.endTime, "fullText": line.fullText,
                         "words": line.words.map { ["text": $0.text, "startTime": $0.startTime, "endTime": $0.endTime] as [String: Any] }]
                    }]
                view.callAsyncJavaScript("window.FoliaStage.setSong(song)", arguments: ["song": song], in: nil, contentWorld: .page, completionHandler: nil)
                lastStamp = .distantPast
            }
            let elapsed = Date().timeIntervalSince(lastStamp)
            let expected = lastTime + (lastPlaying ? elapsed : 0)
            if elapsed >= 0.25 || lastPlaying != parent.playing || abs(expected - parent.time) > 0.35 {
                lastTime = parent.time; lastPlaying = parent.playing; lastStamp = Date()
                view.callAsyncJavaScript("window.FoliaStage.setClock(snapshot)", arguments: ["snapshot":
                    ["time": parent.time, "playing": parent.playing, "reduceMotion": parent.reduceMotion]],
                    in: nil, contentWorld: .page, completionHandler: nil)
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "loaded" { loaded = true; update() }
            else if type == "ready" { parent.ready = true; parent.failed = false }
            else if type == "error" { parent.failed = true }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { parent.failed = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("typeof window.FoliaStage") { [weak self] result, _ in
                if result as? String != "object" { self?.parent.failed = true }
            }
        }
    }
}
