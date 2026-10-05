import SwiftUI
import UIKit
import WebKit
import AVKit

/// Search sources and add to library.
struct SourceSearchView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var results: [SourceSearchResult] = []
    @State private var searching = false
    @State private var error: String?
    @State private var selected: SourceSearchResult?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    if searching {
                        Spacer()
                        ProgressView()
                            .tint(.white)
                        Spacer()
                    } else if let error {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 40))
                                .foregroundStyle(.yellow)
                            Text(error)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                            Button("Retry") { Task { await doSearch() } }
                                .buttonStyle(.borderedProminent)
                        }
                        Spacer()
                    } else if results.isEmpty && !query.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundStyle(.white.opacity(0.4))
                            Text("No results for \"\(query)\"")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                    } else if results.isEmpty {
                        // Empty state with suggestions
                        Spacer()
                        VStack(spacing: 16) {
                            Image(systemName: "magnifyingglass.circle")
                                .font(.system(size: 60))
                                .foregroundStyle(Cinema.red)
                            Text("Search")
                                .font(.title.weight(.bold))
                                .foregroundStyle(.white)
                            Text("A movie or a show.")
                                .foregroundStyle(.white.opacity(0.6))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        Spacer()
                    } else {
                        List {
                            ForEach(results) { result in
                                resultRow(result)
                                    .listRowBackground(Color.black)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Movie or show")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $selected) { result in
                RiveCaptureView(library: library, result: result) {
                    selected = nil
                    dismiss()
                }
            }
            .onChange(of: query) { _, new in
                if new.hasPrefix("tt") && new.count >= 9 {
                    Task { await doSearch(imdb: new) }
                } else if new.count >= 2 {
                    Task { await doSearch() }
                } else {
                    results = []
                }
            }
        }
    }

    private func resultRow(_ result: SourceSearchResult) -> some View {
        HStack(spacing: 14) {
            // Poster
            AsyncImage(url: result.poster.flatMap(URL.init)) { phase in
                switch phase {
                case .empty:
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.1))
                        .overlay(ProgressView().tint(.white.opacity(0.3)))
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.1))
                        .overlay(Image(systemName: "film").foregroundStyle(.white.opacity(0.3)))
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 92, height: 138)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(result.displayTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let tmdb = result.tmdbId {
                    Text(result.type == "series" ? "TV \(tmdb) S1E1" : "TMDB \(tmdb)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text(libraryMovie(result) == nil ? "Online" : "In your library")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.white.opacity(0.4))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let movie = libraryMovie(result) {
                library.focusID = movie.id
                dismiss()
            } else {
                selected = result
            }
        }
    }

    private func libraryMovie(_ result: SourceSearchResult) -> Movie? {
        library.movie(matching: result)
    }

    private func doSearch(imdb: String? = nil) async {
        searching = true
        error = nil
        do {
            if let imdb {
                results = try await library.sourceSearchByImdb(imdbId: imdb, source: "meta")
            } else {
                results = try await library.sourceSearch(query: query, source: "meta")
            }
        } catch {
            let message = error.localizedDescription
            self.error = message.contains("tmdb_unconfigured") ? "TMDB is not configured on the worker." : message
            results = []
        }
        searching = false
    }

}

/// The Rive page sorts its servers; the first playlist it requests plays in the
/// native player. Nothing is saved unless the user adds the title to the library.
struct RiveCaptureView: View {
    let library: LibraryModel
    let result: SourceSearchResult
    let onFinished: () -> Void

    init(library: LibraryModel, result: SourceSearchResult, onFinished: @escaping () -> Void) {
        self.library = library
        self.result = result
        self.onFinished = onFinished
        let parts = result.id.split(separator: ":")
        let tv = result.type == "series" || result.id.hasPrefix("meta:tv:")
        _season = State(initialValue: tv && parts.count > 3 ? Int(parts[3]) ?? 1 : 1)
        _episode = State(initialValue: tv && parts.count > 4 ? Int(parts[4]) ?? 1 : 1)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var playlist: URL?
    @State private var playing = false
    @State private var season = 1
    @State private var episode = 1
    @State private var saveJob: RelaySaveJob?
    @State private var saveTask: Task<Void, Never>?
    @State private var saveError: String?

    private var isTV: Bool { result.type == "series" || result.id.hasPrefix("meta:tv:") }
    private var saving: Bool { saveTask != nil }
    private var saved: Bool { saveJob?.isDone == true }

    var body: some View {
        NavigationStack {
            ZStack {
                if playlist == nil {
                    if let url = pageURL() {
                        RiveWebView(url: url) { found in
                            guard playlist == nil else { return }
                            playlist = found
                            play(found)
                        }
                        .id("\(season)-\(episode)")
                        .opacity(0)
                        .allowsHitTesting(false)
                        .ignoresSafeArea(edges: .bottom)
                        ProgressView("Finding the stream")
                            .tint(.white)
                            .foregroundStyle(.white)
                    } else {
                        ContentUnavailableView("No TMDB id", systemImage: "film", description: Text(result.title))
                    }
                } else {
                    ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle(result.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var ready: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text(result.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                if isTV {
                    Text("Season \(season) · Episode \(episode)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Button { if let playlist { play(playlist) } } label: {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            if isTV {
                HStack(spacing: 12) {
                    Button { shift(episode: -1) } label: {
                        Label("Previous", systemImage: "backward.end.fill").frame(maxWidth: .infinity)
                    }
                    .disabled(season == 1 && episode == 1)
                    Button { shift(episode: 1) } label: {
                        Label("Next", systemImage: "forward.end.fill").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            // The same download button the library uses: label, ring and states.
            Button { startServerSave() } label: {
                Label(saved ? "Downloaded" : saving ? "Saving" : "Download", systemImage: saved ? "checkmark" : "arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(saving || saved)
            .overlay { SaveRing(progress: saving ? max(0.02, saveJob?.progress ?? 0) : nil) }

            if let saveError {
                Text(saveError)
                    .font(.footnote)
                    .foregroundStyle(.yellow)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 32)
        .frame(maxWidth: Cinema.playColumn)
    }

    private func pageURL() -> URL? {
        guard let tmdb = result.tmdbId else { return nil }
        if isTV {
            return URL(string: "https://www.rivestream.app/embed?type=tv&id=\(tmdb)&season=\(season)&episode=\(episode)")
        }
        return URL(string: "https://www.rivestream.app/embed?type=movie&id=\(tmdb)")
    }

    private func shift(episode delta: Int) {
        let next = episode + delta
        if next < 1 {
            guard season > 1 else { return }
            season -= 1
            episode = 1
        } else {
            episode = next
        }
        playlist = nil
        saveTask?.cancel()
        saveTask = nil
        saveJob = nil
        saveError = nil
    }

    /// Streams the playlist in the system player, so Done, transport, PiP and
    /// AirPlay are all native and hide together. Done returns to this screen.
    private func play(_ url: URL) {
        guard !playing else { return }
        playing = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        var headers = ["User-Agent": "Watch/1"]
        if let referer = pageURL()?.absoluteString { headers["Referer"] = referer }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        // Movies often list a 4K variant first; opening on it is what makes them slow to start.
        // Capping at 1080p (what a saved copy keeps) lets playback begin on a variant that downloads fast.
        item.preferredMaximumResolution = CGSize(width: 1920, height: 1080)
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true

        let vc = DismissablePlayerVC()
        vc.player = player
        vc.modalPresentationStyle = .fullScreen
        vc.allowsPictureInPicturePlayback = true
        vc.updatesNowPlayingInfoCenter = true
        vc.onDone = {
            player.pause()
            playing = false
        }
        guard let top = topViewController() else {
            playing = false
            return
        }
        top.present(vc, animated: true) { player.play() }
    }

    /// Save the captured playlist to R2 via the worker (chunked save) as a rental,
    /// then pull the new title into the library.
    private func startServerSave() {
        guard saveTask == nil, let playlist, let tmdb = result.tmdbId else { return }
        saveError = nil
        let referer = pageURL()
        let mediaType = isTV ? "tv" : "movie"
        let season = season
        let episode = episode
        let library = library
        saveTask = Task {
            do {
                var job = try await library.relaySave(
                    playlist: playlist, referer: referer,
                    tmdbId: tmdb, mediaType: mediaType,
                    season: season, episode: episode
                )
                saveJob = job
                while !Task.isCancelled, !job.isDone, !job.isFailed {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    job = try await library.relaySaveStatus(id: job.id)
                    saveJob = job
                }
                if job.isFailed {
                    saveError = "Couldn't add to your library."
                    saveJob = nil
                } else if job.isDone {
                    await library.refresh()
                }
            } catch {
                if !Task.isCancelled {
                    saveError = "Couldn't add to your library."
                    saveJob = nil
                }
            }
            saveTask = nil
        }
    }

}

private func rivePageURL(_ result: SourceSearchResult) -> URL? {
    guard let tmdb = result.tmdbId else { return nil }
    if result.id.hasPrefix("meta:tv:") {
        let parts = result.id.split(separator: ":")
        let season = parts.count > 3 ? parts[3] : "1"
        let episode = parts.count > 4 ? parts[4] : "1"
        return URL(string: "https://www.rivestream.app/embed?type=tv&id=\(tmdb)&season=\(season)&episode=\(episode)")
    }
    return URL(string: "https://www.rivestream.app/embed?type=movie&id=\(tmdb)")
}

private func bestVariant(_ playlist: URL) async throws -> URL {
    let (data, response) = try await URLSession.shared.data(from: playlist)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
        return playlist
    }
    guard text.contains("#EXT-X-STREAM-INF") else { return playlist }
    var bestBandwidth = -1
    var bestURI: String?
    var pending: Int?
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#EXT-X-STREAM-INF"), let range = line.range(of: "BANDWIDTH=") {
            pending = Int(line[range.upperBound...].prefix { $0.isNumber })
        } else if !line.isEmpty, !line.hasPrefix("#"), let bandwidth = pending {
            if bandwidth > bestBandwidth {
                bestBandwidth = bandwidth
                bestURI = line
            }
            pending = nil
        }
    }
    guard let bestURI, let url = URL(string: bestURI, relativeTo: playlist)?.absoluteURL else { return playlist }
    return url
}

private struct RiveWebView: UIViewRepresentable {
    var url: URL
    var onPlaylist: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPlaylist: onPlaylist) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let script = WKUserScript(source: Self.hook, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        config.userContentController.add(context.coordinator, name: "playlist")
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.scrollView.minimumZoomScale = 1
        web.scrollView.maximumZoomScale = 1
        web.scrollView.bouncesZoom = false
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        context.coordinator.web = web
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static let hook = """
    (function() {
      var last = "";
      function lockZoom() {
        var meta = document.querySelector('meta[name="viewport"]');
        if (!meta) {
          meta = document.createElement('meta');
          meta.name = 'viewport';
          (document.head || document.documentElement).appendChild(meta);
        }
        meta.content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no';
      }
      lockZoom();
      document.addEventListener('DOMContentLoaded', lockZoom);
      document.addEventListener('gesturestart', function(e) { e.preventDefault(); }, { passive: false });
      document.addEventListener('dblclick', function(e) { e.preventDefault(); }, true);
      function playlist(u) {
        var s = String(u || "");
        return /\\.m3u8|mpegurl/i.test(s);
      }
      function note(u) {
        try {
          if (!playlist(u)) return;
          last = String(u);
          window.webkit.messageHandlers.playlist.postMessage(last);
        } catch (e) {}
      }
      var ofetch = window.fetch;
      if (ofetch) window.fetch = function(input) {
        try { note(typeof input === "string" ? input : (input && input.url)); } catch (e) {}
        return ofetch.apply(this, arguments);
      };
      var open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        try { note(url); } catch (e) {}
        return open.apply(this, arguments);
      };
      document.addEventListener("playing", function(e) {
        var src = e.target && (e.target.currentSrc || e.target.src);
        if (!src || !playlist(src)) src = last;
        if (src && playlist(src)) {
          window.webkit.messageHandlers.playlist.postMessage(String(src));
        }
      }, true);
    })();
    """

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onPlaylist: (URL) -> Void
        weak var web: WKWebView?
        private var sent = false
        init(onPlaylist: @escaping (URL) -> Void) { self.onPlaylist = onPlaylist }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !sent, let raw = message.body as? String, let url = URL(string: raw) else { return }
            sent = true
            let store = web?.configuration.websiteDataStore.httpCookieStore
            store?.getAllCookies { cookies in
                for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
                DispatchQueue.main.async { self.onPlaylist(url) }
            }
        }
    }
}
