import SwiftUI
import WebKit

// A visible official IFrame player stays inside Folia; no audio extraction or account tokens enter the page.
struct YouTubePlayerView: UIViewRepresentable {
    let player: YouTubePlayback

    func makeCoordinator() -> Coordinator { Coordinator(player: player) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "youtube")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.isOpaque = false; view.backgroundColor = .black; view.scrollView.isScrollEnabled = false
        view.accessibilityIdentifier = "youtubeEmbeddedPlayer"
        context.coordinator.view = view
        context.coordinator.update()
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.update() }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.evaluateJavaScript("window.FoliaYouTube?.stop()", completionHandler: nil)
        view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "youtube")
        view.navigationDelegate = nil; view.uiDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let player: YouTubePlayback
        weak var view: WKWebView?
        var session: UUID?
        var loaded = false
        var sentPlayback: Bool?
        var sentSeek: UUID?
        init(player: YouTubePlayback) { self.player = player }

        func update() {
            guard let view, let video = player.current else { return }
            if session != player.session {
                session = player.session; loaded = false; sentPlayback = nil; sentSeek = player.seekRevision
                let bundle = (Bundle.main.bundleIdentifier ?? "org.folia.community.ios").lowercased()
                let origin = "https://" + bundle
                view.loadHTMLString(Self.html(video: video.id, session: player.session.uuidString, origin: origin), baseURL: URL(string: origin))
                return
            }
            guard loaded else { return }
            let wants = player.wantsPlayback && player.visible
            if sentPlayback != wants {
                sentPlayback = wants
                view.callAsyncJavaScript("window.FoliaYouTube.setPlayback(wants)", arguments: ["wants": wants], in: nil, in: .page, completionHandler: nil)
            }
            if sentSeek != player.seekRevision {
                sentSeek = player.seekRevision
                view.callAsyncJavaScript("window.FoliaYouTube.seek(time)", arguments: ["time": player.seekTime], in: nil, in: .page, completionHandler: nil)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                  let session = body["session"] as? String, session == player.session.uuidString,
                  let type = body["type"] as? String else { return }
            if type == "loaded" { loaded = true; update() }
            else if type == "blocked" { player.autoplayBlocked() }
            else if type == "error" { player.failed(body["code"] as? Int ?? -1, session: session) }
            else if type == "snapshot", let data = try? JSONSerialization.data(withJSONObject: body),
                    let snapshot = try? JSONDecoder().decode(YouTubeSnapshot.self, from: data) { player.receive(snapshot) }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { player.failed(-1, session: session?.uuidString ?? "") }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }
            return nil
        }

        static func html(video: String, session: String, origin: String) -> String {
            // These three inputs are validated identifiers, never free-form titles or lyrics.
            """
            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>html,body,#player{margin:0;width:100%;height:100%;background:#000;overflow:hidden}</style></head><body>
            <div id="player"></div><script>
            const session='\(session)',videoID='\(video)';let player,ready=false,wants=false,pendingSeek=null;
            const emit=(type,extra={})=>window.webkit.messageHandlers.youtube.postMessage({type,session,...extra});
            const snapshot=()=>{if(!ready)return;const data=player.getVideoData()||{};
              emit('snapshot',{videoID:data.video_id||videoID,state:player.getPlayerState(),time:player.getCurrentTime()||0,
                duration:player.getDuration()||0,title:data.title||'',author:data.author||''});};
            window.FoliaYouTube={setPlayback(value){wants=value;if(ready){value?player.playVideo():player.pauseVideo();}},
              seek(time){if(ready)player.seekTo(time,true);else pendingSeek=time;},stop(){wants=false;if(ready)player.destroy();ready=false;clearInterval(timer);}};
            const timeout=setTimeout(()=>emit('error',{code:-1}),25000);
            window.onYouTubeIframeAPIReady=()=>{player=new YT.Player('player',{width:'100%',height:'100%',videoId:videoID,
              playerVars:{playsinline:1,controls:1,autoplay:0,origin:'\(origin)',widget_referrer:'\(origin)'},
              events:{onReady(){ready=true;clearTimeout(timeout);if(pendingSeek!==null)player.seekTo(pendingSeek,true);
                if(wants)player.playVideo();snapshot();},onStateChange:snapshot,onAutoplayBlocked(){emit('blocked');},onError(e){emit('error',{code:e.data});}}});};
            const timer=setInterval(snapshot,250);emit('loaded');
            document.addEventListener('visibilitychange',()=>{if(document.hidden){wants=false;if(ready)player.pauseVideo();}});
            </script><script src="https://www.youtube.com/iframe_api" onerror="emit('error',{code:-1})"></script></body></html>
            """
        }
    }
}
