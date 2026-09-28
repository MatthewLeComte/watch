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

/// The Rive page sorts its servers, then the playlist it requests is handed to
/// AVAssetDownloadURLSession. That downloader keeps the highest-bandwidth variant.
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
    @State private var native = false
    @State private var bufferMovie: Movie?
    @State private var bufferTask: Task<URL?, Never>?
    @State private var localPlay: URL?
    @State private var bufferProgress: Double = 0
    @State private var season = 1
    @State private var episode = 1

    private var isTV: Bool { result.type == "series" || result.id.hasPrefix("meta:tv:") }

    var body: some View {
        NavigationStack {
            ZStack {
                if let url = pageURL() {
                    RiveWebView(url: url) { found in
                        guard playlist == nil else { return }
                        playlist = found
                        startBuffer()
                        native = true
                    }
                    .id("\(season)-\(episode)")
                    .opacity(0)
                    .allowsHitTesting(false)
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("No TMDB id", systemImage: "film", description: Text(result.title))
                }
                if playlist == nil {
                    ProgressView("Finding the stream")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            .background(Color.black)
            .navigationTitle(result.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        startBuffer()
                    } label: {
                        if bufferTask != nil, localPlay == nil {
                            Text(bufferProgress > 0 ? "\(Int(bufferProgress * 100))%" : "…")
                                .font(.caption.weight(.semibold))
                        } else {
                            Image(systemName: localPlay == nil ? "arrow.down.to.line" : "checkmark")
                        }
                    }
                    .disabled(playlist == nil || localPlay != nil)
                    .accessibilityLabel("Buffer on this device")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        native = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(playlist == nil)
                    .accessibilityLabel("Play fullscreen on this device")
                }
            }
            .fullScreenCover(isPresented: $native) {
                if let playlist {
                    NativeStreamScreen(
                        url: localPlay ?? playlist,
                        referer: pageURL()?.absoluteString,
                        episodeLabel: isTV ? "S\(season) E\(episode)" : nil,
                        onPrevious: isTV ? { shift(episode: -1) } : nil,
                        onNext: isTV ? { shift(episode: 1) } : nil
                    ) {
                        await saveUnified()
                    }
                }
            }
            .task(id: bufferMovie?.id) { await watchBuffer() }
        }
    }

    private func pageURL() -> URL? {
        guard let tmdb = result.tmdbId else { return nil }
        if isTV {
            return URL(string: "https://www.rivestream.app/watch?type=tv&id=\(tmdb)&season=\(season)&episode=\(episode)")
        }
        return URL(string: "https://www.rivestream.app/watch?type=movie&id=\(tmdb)")
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
        bufferTask?.cancel()
        bufferTask = nil
        bufferMovie = nil
        localPlay = nil
        playlist = nil
        bufferProgress = 0
        native = false
    }

    private func watchBuffer() async {
        while !Task.isCancelled, let id = bufferMovie?.id, localPlay == nil {
            if let progress = await library.media.hlsDownloadProgress(id: id) {
                bufferProgress = progress
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private func startBuffer() {
        guard bufferTask == nil, let playlist else { return }
        let movie = localMovie(result, playlist: playlist)
        bufferMovie = movie
        let headers = pageURL().map { ["Referer": $0.absoluteString] } ?? [:]
        bufferTask = Task {
            let file = try? await library.media.downloadHLS(api: library.api, movie: movie, hlsURL: playlist, headers: headers)
            localPlay = file
            bufferProgress = file == nil ? bufferProgress : 1
            return file
        }
    }

    /// Waits for the on-device HLS package, then writes one mp4 from it.
    private func saveUnified() async -> URL? {
        startBuffer()
        guard let movpkg = await bufferTask?.value else { return nil }
        return try? await library.media.exportUnifiedVideo(movpkg: movpkg, name: result.title)
    }

}

private struct NativeStreamScreen: View {
    let url: URL
    let referer: String?
    var episodeLabel: String?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onSave: () async -> URL?
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var saving = false
    @State private var savedFile: URL?
    @State private var chrome = true
    @State private var hideChrome: Task<Void, Never>?

    var body: some View {
        SystemPlayer(player: player)
            .ignoresSafeArea()
            .background(Color.black)
            .overlay(alignment: .top) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Close")
                    if let episodeLabel {
                        Button { onPrevious?() } label: { Image(systemName: "backward.end.fill") }
                            .buttonStyle(.glass)
                            .disabled(onPrevious == nil)
                        Text(episodeLabel)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .glassEffect(.regular, in: Capsule())
                        Button { onNext?() } label: { Image(systemName: "forward.end.fill") }
                            .buttonStyle(.glass)
                            .disabled(onNext == nil)
                    }
                    Button {
                        saving = true
                        Task {
                            savedFile = await onSave()
                            saving = false
                        }
                    } label: {
                        if saving { ProgressView() } else { Image(systemName: savedFile == nil ? "square.and.arrow.down" : "checkmark") }
                    }
                    .buttonStyle(.glass)
                    .disabled(saving)
                    .accessibilityLabel("Save")
                }
                .padding(.top, 8)
                .opacity(chrome ? 1 : 0)
                .allowsHitTesting(chrome)
                .animation(.easeInOut(duration: 0.25), value: chrome)
            }
            .simultaneousGesture(TapGesture().onEnded { reveal() })
            .onAppear { reveal() }
            .sheet(isPresented: Binding(get: { savedFile != nil }, set: { if !$0 { savedFile = nil } })) {
                if let savedFile {
                    ActivityShare(url: savedFile)
                }
            }
            .onAppear {
                var headers = ["User-Agent": "Watch/1"]
                if let referer { headers["Referer"] = referer }
                let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                player.play()
            }
            .onDisappear { player.pause() }
    }

    private func reveal() {
        chrome = true
        hideChrome?.cancel()
        hideChrome = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            chrome = false
        }
    }
}

private struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.allowsPictureInPicturePlayback = true
        vc.updatesNowPlayingInfoCenter = true
        vc.speeds = [AVPlaybackSpeed(rate: 1, localizedName: "1×")]
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}

private struct ActivityShare: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private func rivePageURL(_ result: SourceSearchResult) -> URL? {
    guard let tmdb = result.tmdbId else { return nil }
    if result.id.hasPrefix("meta:tv:") {
        let parts = result.id.split(separator: ":")
        let season = parts.count > 3 ? parts[3] : "1"
        let episode = parts.count > 4 ? parts[4] : "1"
        return URL(string: "https://www.rivestream.app/watch?type=tv&id=\(tmdb)&season=\(season)&episode=\(episode)")
    }
    return URL(string: "https://www.rivestream.app/watch?type=movie&id=\(tmdb)")
}

private func localMovie(_ result: SourceSearchResult, playlist: URL) -> Movie {
    let now = ISO8601DateFormatter().string(from: Date())
    return Movie(
        id: UUID().uuidString,
        filename: "\(result.title).movpkg",
        byteSize: 0,
        contentType: "application/vnd.apple.mpegurl",
        ext: "movpkg",
        title: result.title,
        originalTitle: nil,
        year: result.year,
        overview: "",
        runtimeMin: nil,
        genres: [],
        imdbId: result.imdbId,
        tmdbId: result.tmdbId,
        osHash: nil,
        streamId: nil,
        hlsUrl: playlist.absoluteString,
        thumbnailUrl: result.poster,
        downloadUrl: nil,
        readyToStream: true,
        posterUrl: result.poster,
        backdropUrl: nil,
        trailerSite: nil,
        trailerKey: nil,
        trailerUrl: nil,
        trailer: nil,
        trailerFileUrl: nil,
        trailerFile: nil,
        trailerCaptions: nil,
        status: "ready",
        matchSource: "rive",
        matchP: nil,
        matchNote: result.id,
        subtitles: [],
        createdAt: now,
        updatedAt: now
    )
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

/// Resolve movie page → show qualities & subtitles.
struct SourceResolveView: View {
    let library: LibraryModel
    let result: SourceSearchResult
    let source: String
    let onDownload: (SourceStreamInfo, SourceQuality, SourceSubtitle?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var streamInfo: SourceStreamInfo?
    @State private var resolving = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if resolving {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("Loading stream info…")
                            .foregroundStyle(.white.opacity(0.8))
                    }
                } else if let error {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundStyle(.yellow)
                        Text(error)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button("Retry") { Task { await resolve() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if let stream = streamInfo {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            // Header
                            HStack(spacing: 16) {
                                AsyncImage(url: stream.poster.flatMap(URL.init)) { phase in
                                    switch phase {
                                    case .empty:
                                        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1))
                                    case .success(let img):
                                        img.resizable().scaledToFill()
                                    case .failure:
                                        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1))
                                            .overlay(Image(systemName: "film").foregroundStyle(.white.opacity(0.3)))
                                    @unknown default:
                                        EmptyView()
                                    }
                                }
                                .frame(width: 100, height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(stream.title)
                                        .font(.title2.weight(.bold))
                                        .foregroundStyle(.white)
                                    if let year = stream.year {
                                        Text("\(year)")
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                    if let imdb = stream.imdbId {
                                        Text(imdb)
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.5))
                                    }
                                }
                            }

                            // Qualities
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Quality")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(.white)

                                ForEach(stream.qualities) { q in
                                    Button {
                                        onDownload(stream, q, nil)
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("\(q.height)p")
                                                    .font(.headline.weight(.semibold))
                                                    .foregroundStyle(.white)
                                                Text("\(q.bandwidth / 1_000_000) Mbps • \(q.codecs)")
                                                    .font(.caption)
                                                    .foregroundStyle(.white.opacity(0.6))
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .foregroundStyle(.white.opacity(0.4))
                                        }
                                        .padding()
                                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            // Subtitles
                            if !stream.subtitles.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Subtitles")
                                        .font(.headline.weight(.bold))
                                        .foregroundStyle(.white)

                                    ForEach(stream.subtitles) { s in
                                        Button {
                                            onDownload(stream, stream.qualities.first!, s)
                                        } label: {
                                            HStack {
                                                Text(s.label)
                                                    .font(.headline.weight(.semibold))
                                                    .foregroundStyle(.white)
                                                if s.forced {
                                                    Text("FORCED")
                                                        .font(.caption2.weight(.bold))
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Cinema.red, in: Capsule())
                                                }
                                                Spacer()
                                                Image(systemName: "chevron.right")
                                                    .foregroundStyle(.white.opacity(0.4))
                                            }
                                            .padding()
                                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    // None option
                                    Button {
                                        onDownload(stream, stream.qualities.first!, nil)
                                    } label: {
                                        HStack {
                                            Text("None")
                                                .font(.headline.weight(.semibold))
                                                .foregroundStyle(.white)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .foregroundStyle(.white.opacity(0.4))
                                        }
                                        .padding()
                                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle(result.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await resolve() }
        }
    }

    private func resolve() async {
        resolving = true
        error = nil
        do {
            streamInfo = try await library.sourceResolve(source: source, id: result.id)
        } catch {
            self.error = error.localizedDescription
        }
        resolving = false
    }
}

/// Confirm download with quality & subtitle selection.
struct SourceDownloadConfirmView: View {
    let stream: SourceStreamInfo
    let quality: SourceQuality
    let subtitle: SourceSubtitle?
    let onConfirm: (SourceQuality, SourceSubtitle?) -> Void
    let onCancel: () -> Void

    @State private var selectedQuality: SourceQuality
    @State private var selectedSubtitle: SourceSubtitle?

    init(stream: SourceStreamInfo, quality: SourceQuality, subtitle: SourceSubtitle?, onConfirm: @escaping (SourceQuality, SourceSubtitle?) -> Void, onCancel: @escaping () -> Void) {
        self.stream = stream
        self.quality = quality
        self.subtitle = subtitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self._selectedQuality = State(initialValue: quality)
        self._selectedSubtitle = State(initialValue: subtitle)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Movie info
                        HStack(spacing: 16) {
                            AsyncImage(url: stream.poster.flatMap(URL.init)) { phase in
                                switch phase {
                                case .empty:
                                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1))
                                case .success(let img):
                                    img.resizable().scaledToFill()
                                case .failure:
                                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1))
                                        .overlay(Image(systemName: "film").foregroundStyle(.white.opacity(0.3)))
                                @unknown default:
                                    EmptyView()
                                }
                            }
                            .frame(width: 80, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(stream.title)
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(.white)
                                if let year = stream.year {
                                    Text("\(year)")
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                            }
                        }

                        // Quality picker
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Quality")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)

                            ForEach(stream.qualities) { q in
                                Button {
                                    selectedQuality = q
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(q.height)p")
                                                .font(.headline.weight(.semibold))
                                                .foregroundStyle(.white)
                                            Text("\(q.bandwidth / 1_000_000) Mbps • \(q.codecs)")
                                                .font(.caption)
                                                .foregroundStyle(.white.opacity(0.6))
                                        }
                                        Spacer()
                                        if selectedQuality.id == q.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(Cinema.red)
                                                .font(.title2)
                                        }
                                    }
                                    .padding()
                                    .background(
                                        selectedQuality.id == q.id ?
                                        Color.white.opacity(0.15) : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(selectedQuality.id == q.id ? Cinema.red : Color.clear, lineWidth: 2)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Subtitle picker
                        if !stream.subtitles.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Subtitles")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(.white)

                                Button {
                                    selectedSubtitle = nil
                                } label: {
                                    subtitleRow(label: "None", selected: selectedSubtitle == nil)
                                }
                                .buttonStyle(.plain)

                                ForEach(stream.subtitles) { s in
                                    Button {
                                        selectedSubtitle = s
                                    } label: {
                                        subtitleRow(label: s.label, forced: s.forced, selected: selectedSubtitle?.id == s.id)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Confirm Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        onConfirm(selectedQuality, selectedSubtitle)
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }

    private func subtitleRow(label: String, forced: Bool = false, selected: Bool) -> some View {
        HStack {
            Text(label)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            if forced {
                Text("FORCED")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Cinema.red, in: Capsule())
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Cinema.red)
                    .font(.title2)
            }
        }
        .padding()
        .background(
            selected ? Color.white.opacity(0.15) : Color.white.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Cinema.red : Color.clear, lineWidth: 2)
        )
    }
}