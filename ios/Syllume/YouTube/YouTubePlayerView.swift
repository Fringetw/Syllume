import SwiftUI
import WebKit

// The official player occupies its own visible area and receives no library credentials.
struct YouTubePlayerView: UIViewRepresentable {
    let player: YouTubePlayback
    // Explicit values make SwiftUI deliver every command even though the model identity is unchanged.
    let requestSession: UUID
    let requestPlayback: Bool
    let requestRevision: Int
    let requestSeek: UUID?
    let requestTime: Double
    let onUpdate: @MainActor () -> Void

    init(player: YouTubePlayback, onUpdate: @escaping @MainActor () -> Void = {}) {
        self.player = player; requestSession = player.session
        requestPlayback = player.wantsPlayback && player.visible
        requestRevision = player.playbackRevision
        requestSeek = player.seekRevision; requestTime = player.seekTime
        self.onUpdate = onUpdate
    }

    func makeCoordinator() -> Coordinator { Coordinator(input: self) }
    func makeUIView(context: Context) -> PlayerWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "youtube")
        let view = PlayerWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.isOpaque = false; view.backgroundColor = .black; view.scrollView.isScrollEnabled = false
        view.accessibilityIdentifier = "youtubeEmbeddedPlayer"
        context.coordinator.view = view
        view.viewportDidChange = { [weak coordinator = context.coordinator] in coordinator?.update() }
        return view
    }
    func updateUIView(_ view: PlayerWebView, context: Context) { context.coordinator.input = self; context.coordinator.update() }
    static func dismantleUIView(_ view: PlayerWebView, coordinator: Coordinator) {
        view.viewportDidChange = nil
        view.pauseAllMediaPlayback(completionHandler: nil)
        view.evaluateJavaScript("window.FoliaYouTube?.stop()", completionHandler: nil)
        view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "youtube")
        view.navigationDelegate = nil; view.uiDelegate = nil
    }

    final class PlayerWebView: WKWebView {
        var viewportDidChange: (@MainActor () -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            viewportDidChange?()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            viewportDidChange?()
        }

        var hasVisibleViewport: Bool {
            guard let window, !isHidden, alpha > 0, bounds.width >= 200, bounds.height >= 200 else { return false }
            let frame = convert(bounds, to: window)
            let visible = frame.intersection(window.bounds)
            return !visible.isNull && visible.width * visible.height > frame.width * frame.height / 2
        }
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var input: YouTubePlayerView
        var player: YouTubePlayback { input.player }
        weak var view: PlayerWebView?
        var session: UUID?
        var loaded = false
        var sentRevision: Int?
        var sentSeek: UUID?
        var pausedRevision: Int?
        init(input: YouTubePlayerView) { self.input = input }

        func update() {
            guard let view, let video = player.current,
                  input.requestSession == player.session, input.requestRevision == player.playbackRevision else { return }
            if session != input.requestSession {
                guard player.visible, view.hasVisibleViewport else { return }
                session = input.requestSession; loaded = false; sentRevision = nil; pausedRevision = nil
                // A new iframe can start from the retained position without seeking a paused, unloaded video.
                let start = Int(player.position.rounded(.down))
                sentSeek = input.requestSeek
                let bundle = (Bundle.main.bundleIdentifier ?? "org.folia.community.ios").lowercased()
                let origin = "https://" + bundle
                view.loadHTMLString(Self.html(video: video.id, session: input.requestSession.uuidString,
                                              origin: origin, start: start), baseURL: URL(string: origin))
                return
            }
            // WebKit pauses the actual media immediately, even before the IFrame API is ready.
            if sentRevision != nil, pausedRevision != input.requestRevision, !input.requestPlayback {
                let revision = input.requestRevision
                pausedRevision = revision
                view.pauseAllMediaPlayback { [weak self] in
                    guard let self else { return }
                    // A slow WebKit pause must not land after a newer resume and leave it silent.
                    if revision != player.playbackRevision, input.requestPlayback { sentRevision = nil; update() }
                    reportMediaState()
                }
            }
            guard loaded else { return }
            if input.requestPlayback, !view.hasVisibleViewport { return }
            if sentRevision != input.requestRevision {
                sentRevision = input.requestRevision
                view.callAsyncJavaScript("window.FoliaYouTube.setPlayback(wants, revision)",
                    arguments: ["wants": input.requestPlayback, "revision": input.requestRevision], in: nil, in: .page, completionHandler: nil)
            }
            if let seek = input.requestSeek, sentSeek != seek, player.visible, view.hasVisibleViewport {
                sentSeek = seek
                view.callAsyncJavaScript("window.FoliaYouTube.seek(time)", arguments: ["time": input.requestTime], in: nil, in: .page, completionHandler: nil)
            }
        }

        private func reportMediaState() {
            #if DEBUG
            let session = input.requestSession, revision = input.requestRevision
            view?.requestMediaPlaybackState { [weak self] state in
                let label: String
                switch state { case .paused: label = "paused"; case .playing: label = "playing"; case .suspended: label = "suspended"; case .none: label = "none"; @unknown default: label = "unknown" }
                self?.player.recordMediaState(label, session: session, revision: revision)
            }
            #endif
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                  let session = body["session"] as? String, session == player.session.uuidString,
                  let type = body["type"] as? String else { return }
            if type == "loaded" { loaded = true; update(); return }
            else if type == "blocked" { player.autoplayBlocked(revision: body["commandRevision"] as? Int) }
            else if type == "error" { player.failed(body["code"] as? Int ?? -1, session: session) }
            else if type == "snapshot", let data = try? JSONSerialization.data(withJSONObject: body),
                    let snapshot = try? JSONDecoder().decode(YouTubeSnapshot.self, from: data) { player.receive(snapshot) }
            input.onUpdate()
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            player.failed(-1, session: session?.uuidString ?? "")
            input.onUpdate()
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }
            return nil
        }

        private static let transportScript: String = {
            guard let url = Bundle.main.url(forResource: "player", withExtension: "js", subdirectory: "SyllumeYouTube"),
                  let script = try? String(contentsOf: url, encoding: .utf8) else { return "throw new Error('Player resource missing');" }
            return script
        }()

        private static var apiLoader: String {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--youtube-playback-fixture"),
               let url = Bundle.main.url(forResource: "tide", withExtension: "m4a"), let data = try? Data(contentsOf: url) {
                return """
                <script>
                window.YT={Player:class {
                  constructor(id,options){
                    this.o=options;this.a=new Audio();this.a.loop=true;this.a.preload='auto';
                    document.getElementById(id).textContent='本機播放測試';
                    this.a.addEventListener('error',()=>options.events.onError({data:-1}));
                    this.a.addEventListener('loadedmetadata',()=>{
                      const start=options.playerVars.start % this.a.duration;
                      if(start>0){
                        this.a.addEventListener('seeked',()=>options.events.onReady(),{once:true});
                        this.a.currentTime=start;
                      }else options.events.onReady();
                    },{once:true});
                    this.a.src='data:audio/mp4;base64,\(data.base64EncodedString())';
                  }
                  playVideo(){this.a.play().then(()=>this.o.events.onStateChange()).catch(()=>this.o.events.onAutoplayBlocked());}
                  pauseVideo(){this.a.pause();this.o.events.onStateChange();}
                  getVideoData(){return {video_id:videoID,title:'本機播放測試',author:'Syllume'};}
                  getPlayerState(){return this.a.paused?2:(this.a.seeking || this.a.readyState<3?3:1);}
                  getCurrentTime(){return this.a.currentTime;}
                  getDuration(){return {'6AR6Oc0-4NQ':236,'3NNhrqHZqlI':256,'z2tDtdHHAHg':188}[videoID] || (Number.isFinite(this.a.duration)?this.a.duration:30);}
                  seekTo(time){this.a.currentTime=time;} destroy(){this.a.pause();this.a.src='';}
                }};window.onYouTubeIframeAPIReady();
                </script>
                """
            }
            #endif
            return "<script src=\"https://www.youtube.com/iframe_api\" onerror=\"emit('error',{code:-1})\"></script>"
        }

        static func html(video: String, session: String, origin: String, start: Int) -> String {
            // The strings are validated identifiers, never free-form titles or lyrics.
            """
            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
            <meta name="referrer" content="strict-origin-when-cross-origin">
            <style>html,body,#player{margin:0;width:100%;height:100%;background:#000;overflow:hidden}</style></head><body>
            <div id="player"></div><script>
            const session='\(session)',videoID='\(video)',origin='\(origin)',startSeconds=\(start);
            \(transportScript)
            </script>\(apiLoader)</body></html>
            """
        }
    }
}
