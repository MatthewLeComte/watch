import SwiftUI
import WebKit

/// Muted inline trailer from the IMDb match. Poster stays underneath until the page loads.
/// Single WKWebView per hero — created once per URL via .id() in the caller.
struct TrailerView: UIViewRepresentable {
    var url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        web.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loaded: URL?
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
