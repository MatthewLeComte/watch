import SwiftUI
import WebKit
import AVFoundation
import AVKit

/// Muted inline trailer from the IMDb match. Poster stays underneath until the page loads.
#if os(iOS)
struct TrailerView: UIViewRepresentable {
    var url: URL

    func makeUIView(context: Context) -> WKWebView {
        return makeWebView(context: context)
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        updateWebView(web, context: context)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}
#else
struct TrailerView: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> WKWebView {
        return makeWebView(context: context)
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        updateWebView(web, context: context)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}
#endif

extension TrailerView {
    final class Coordinator {
        var loaded: URL?
    }

    func makeWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        let web = WKWebView(frame: .zero, configuration: config)
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        #endif
        return web
    }

    func updateWebView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        web.load(URLRequest(url: url))
    }
}

enum Trailer {
    /// YouTube key when the match has one.
    static func key(for movie: Movie) -> String? {
        guard movie.trailerSite == "youtube", let key = movie.trailerKey, !key.isEmpty else { return nil }
        return key
    }

    /// Direct trailer file (non-YouTube) when the match carries one.
    static func fileURL(for movie: Movie) -> URL? {
        guard movie.trailerSite != "youtube",
              let raw = movie.trailerUrl, let url = URL(string: raw), url.scheme == "https"
        else { return nil }
        return url
    }

    static func url(for movie: Movie) -> URL? {
        if movie.trailerSite == "youtube", let key = movie.trailerKey, !key.isEmpty {
            var parts = URLComponents(string: "https://www.youtube-nocookie.com/embed/\(key)")
            parts?.queryItems = [
                URLQueryItem(name: "autoplay", value: "1"),
                URLQueryItem(name: "mute", value: "1"),
                URLQueryItem(name: "controls", value: "0"),
                URLQueryItem(name: "playsinline", value: "1"),
                URLQueryItem(name: "rel", value: "0"),
                URLQueryItem(name: "loop", value: "1"),
                URLQueryItem(name: "playlist", value: key),
                URLQueryItem(name: "modestbranding", value: "1"),
            ]
            return parts?.url
        }
        if let raw = movie.trailerUrl, let url = URL(string: raw), url.scheme == "https" {
            return url
        }
        return nil
    }
}

/// Featured-shelf trailer: YouTube key looped muted-autoplay, or a direct
/// mp4 trailer looped the same way. Never the full movie. `muted` is owned
/// by the parent — tapping the trailer toggles it there.
struct TrailerPlayer: View {
    var key: String?
    var mp4: URL?
    var muted: Bool

    var body: some View {
        Group {
            if let key {
                TrailerWeb(key: key, muted: muted)
            } else if let mp4 {
                TrailerLoop(url: mp4, muted: muted)
            }
        }
    }
}

private enum TrailerHTML {
    static func page(key: String) -> String {
        """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"></head>
        <body style="margin:0;background:#000;overflow:hidden">
        <div id="p" style="position:absolute;top:0;left:0;width:100%;height:100%"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        var player=null;
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('p',{videoId:'\(key)',playerVars:{autoplay:1,mute:1,controls:0,playsinline:1,rel:0,loop:1,playlist:'\(key)',modestbranding:1},events:{onReady:function(e){e.target.playVideo();}}});
        }
        </script></body></html>
        """
    }
}

/// Unified YouTube trailer web view
#if os(iOS)
private struct TrailerWeb: UIViewRepresentable {
    var key: String
    var muted: Bool

    func makeUIView(context: Context) -> WKWebView {
        return makeWebView(context: context)
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        updateWebView(web, context: context)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}
#else
private struct TrailerWeb: NSViewRepresentable {
    var key: String
    var muted: Bool

    func makeNSView(context: Context) -> WKWebView {
        return makeWebView(context: context)
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        updateWebView(web, context: context)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}
#endif

private extension TrailerWeb {
    final class Coordinator {
        var key: String?
        var muted = true
    }

    func makeWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        let web = WKWebView(frame: .zero, configuration: config)
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        #endif
        web.loadHTMLString(TrailerHTML.page(key: key), baseURL: nil)
        context.coordinator.key = key
        context.coordinator.muted = muted
        return web
    }

    func updateWebView(_ web: WKWebView, context: Context) {
        if context.coordinator.key != key {
            context.coordinator.key = key
            web.loadHTMLString(TrailerHTML.page(key: key), baseURL: nil)
        }
        if context.coordinator.muted != muted {
            context.coordinator.muted = muted
            web.evaluateJavaScript(muted ? "if(window.player){player.mute();}" : "if(window.player){player.unMute();}", completionHandler: nil)
        }
    }
}

/// Direct-mp4 trailer loop (used when the match carries a file URL).
private struct TrailerLoop: View {
    var url: URL
    var muted: Bool
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                Color.black
            }
        }
        .onAppear {
            let item = AVPlayerItem(url: url)
            let next = AVPlayer(playerItem: item)
            next.isMuted = muted
            next.actionAtItemEnd = .none
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                next.seek(to: .zero)
                next.play()
            }
            player = next
            next.play()
        }
        .onChange(of: muted) { _, value in player?.isMuted = value }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}