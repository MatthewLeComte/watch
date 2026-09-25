import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import WebKit

struct LibraryView: View {
    @Environment(LibraryModel.self) private var library
    @State private var importing = false
    @State private var correcting: Movie?
    @State private var pendingImport: URL?
    @State private var pendingScoped = false
    @State private var bulkSheetPresented = false
    @State private var shelfID: String?
    @State private var posters: [String: URL] = [:]
    @State private var playing: Movie?
    @State private var heroMuted = true
    @State private var playerError: String?
    /// Resolved YouTube ids (Kinocheck) for movies with no trailer on the
    /// record. "" means looked-up-and-none — never resolve twice.
    @State private var trailerKeys: [String: String] = [:]

    private let cardW: CGFloat = 150
    private let cardH: CGFloat = 225

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                if library.movies.isEmpty { empty } else { home }
                controls
            }
            .toolbar { }
            .navigationDestination(for: Movie.self) { DetailView(movieID: $0.id) }
            .sheet(item: $correcting) { CorrectMatchView(movie: $0) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.mpeg4Movie, .quickTimeMovie, .movie], allowsMultipleSelection: true) { handleImport($0) }
            .overlay { if let url = pendingImport { ImportView(url: url, scoped: pendingScoped) { pendingImport = nil } } }
            .sheet(isPresented: $bulkSheetPresented) { BulkImportView(onClose: { if library.bulkAllFinished { library.clearFinishedBulk() }; bulkSheetPresented = false }) }
            .onChange(of: library.bulkItems.count) { _, c in if c > 0 { bulkSheetPresented = true } }
            .modifier(FullScreenPlayer(movie: $playing, onError: { playing = nil; playerError = $0 }))
            .alert("Couldn't play", isPresented: Binding(get: { playerError != nil }, set: { if !$0 { playerError = nil } })) {
                Button("OK") { playerError = nil }
            } message: {
                Text(playerError ?? "")
            }
            .refreshable { await library.refresh(); await loadPosters() }
            .onChange(of: library.openImport) { if let url = library.openImport { pendingImport = url; pendingScoped = library.openImportScoped; library.openImport = nil } }
            .onChange(of: shelves.map(\.id)) { _, ids in if let id = shelfID, !ids.contains(id) { shelfID = nil } }
            .onChange(of: library.movies.map(\.id)) { _, _ in Task { await loadPosters() } }
            .task { await loadPosters() }
            .task(id: heroMovie?.id) { await resolveTrailerKey() }
        }
    }

    private var shelves: [Shelf] {
        var r: [Shelf] = []
        let c = library.movies.filter { (library.positions[$0.id] ?? 0) > 30 }
        if !c.isEmpty { r.append(Shelf(id: "continue", title: "Continue Watching", movies: c)) }
        let s = library.movies.filter { (library.fractions[$0.id] ?? 0) >= 0.999 }
        if !s.isEmpty { r.append(Shelf(id: "device", title: "On This Device", movies: s)) }
        var bg: [String: [Movie]] = [:], loose: [Movie] = []
        for m in library.movies { if m.genres.isEmpty { loose.append(m) } else { for g in m.genres { bg[g, default: []].append(m) } } }
        for g in bg.keys.sorted() { r.append(Shelf(id: "genre-\(g)", title: g, movies: bg[g]!)) }
        if !loose.isEmpty { r.append(Shelf(id: "movies", title: "All Movies", movies: loose)) }
        else if r.isEmpty, !library.movies.isEmpty { r.append(Shelf(id: "movies", title: "All Movies", movies: library.movies)) }
        return r.filter { !$0.movies.isEmpty }
    }

    /// Hero follows the visible row — trailer never gets lost by scrolling.
    private var heroMovie: Movie? {
        let idx = shelves.firstIndex { $0.id == shelfID } ?? 0
        return shelves[safe: idx]?.movies.first ?? library.movies.first
    }

    private var home: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            if h > w {
                portraitHome(width: w, videoH: w * 9 / 16)
            } else if h < 700 {
                // Short landscape (phones sideways): one free scroll, true
                // 16:9 hero, compact rails. Nothing squeezed, nothing cropped.
                shortLandscapeHome(width: w)
            } else {
                tallLandscapeHome(width: w, height: h)
            }
        }
    }

    /// Portrait (iPhone held upright): billboard up top, plain vertical
    /// scroll of compact rails. No full-page pager — one shelf per screen
    /// with nowhere to scroll is what made portrait garbage.
    private func portraitHome(width: CGFloat, videoH: CGFloat) -> some View {
        VStack(spacing: 0) {
            billboard(width: width, videoH: videoH)
                .frame(width: width, height: videoH)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(shelves) { shelf in
                        compactRail(shelf, width: width)
                    }
                }
                .padding(.vertical, 14)
            }
        }
    }

    private func compactRail(_ s: Shelf, width: CGFloat) -> some View {
        let cw = min(150, max(104, width * 0.28))
        let ch = cw * 1.5
        return VStack(alignment: .leading, spacing: 8) {
            Text(s.title)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(s.movies) { m in
                        VStack(alignment: .leading, spacing: 5) {
                            PosterImage(url: posters[m.id] ?? URL(string: m.thumbnailUrl ?? ""), title: m.displayTitle)
                                .frame(width: cw, height: ch)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            if s.id == "continue", let frac = continueFraction(m) {
                                ProgressView(value: frac)
                                    .tint(.red)
                                    .frame(width: cw)
                            }
                        }
                        .onTapGesture { play(m) }
                        .contextMenu { posterMenu(m) }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /// Short landscape: everything scrolls, hero keeps true 16:9.
    private func shortLandscapeHome(width w: CGFloat) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 18) {
                billboard(width: w, videoH: w * 9 / 16)
                    .frame(width: w, height: w * 9 / 16)
                ForEach(shelves) { shelf in
                    compactRail(shelf, width: w)
                }
            }
            .padding(.bottom, 14)
        }
    }

    private func tallLandscapeHome(width w: CGFloat, height h: CGFloat) -> some View {
            // True 16:9 when it fits; capped so shelves keep ≥34% of height.
            // Capping crops backdrops, so the cap only bites on wide windows.
            let heroH = min(w * 9 / 16, h * 0.66)
            let pageH = max(200, h - heroH)
            return VStack(spacing: 0) {
                billboard(width: w, videoH: heroH)
                    .frame(width: w, height: heroH)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(shelves) { shelf in
                            shelfPage(shelf, pageH: pageH)
                                .containerRelativeFrame(.vertical)
                                .id(shelf.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $shelfID)
                .scrollIndicators(.hidden)
                .frame(height: pageH)
            }
    }

    /// Hero: the movie's own trailer, muted and looped under a bottom fade
    /// to black with the title on it. No play button — tap toggles mute,
    /// tap the title (or context menu) plays the movie. No trailer on the
    /// record, no video box: poster art instead of a black hole.
    private func billboard(width: CGFloat, videoH: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                Color.black
                if let movie = heroMovie {
                    if let clip = heroClip(movie) {
                        HeroTrailer(url: clip.url, apiKey: clip.apiKey, muted: heroMuted)
                            .id("file:\(clip.url.absoluteString)")
                            .allowsHitTesting(false)
                    } else if let key = youtubeKey(movie) {
                        YouTubeTrailer(key: key, muted: heroMuted)
                            .id("yt:\(key)")
                            .allowsHitTesting(false)
                    } else {
                        billboardArt(movie)
                    }
                }
            }
            .frame(width: width, height: videoH)
            .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            if let movie = heroMovie {
                VStack(alignment: .leading, spacing: 4) {
                    Text(movie.displayTitle)
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        if let p = movie.matchP, p > 0 {
                            Text("\(Int((p * 100).rounded()))% Match")
                                .foregroundStyle(.green)
                                .font(.subheadline.weight(.bold))
                        }
                        if !movie.yearText.isEmpty { Text(movie.yearText) }
                        if let rt = movie.runtimeText { Text(rt) }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .contentShape(Rectangle())
                .onTapGesture { play(movie) }
            }
        }
        .frame(width: width, height: videoH)
        .contentShape(Rectangle())
        .onTapGesture { heroMuted.toggle() }
        .contextMenu { if let m = heroMovie { posterMenu(m) } }
        .overlay(alignment: .bottomTrailing) {
            if heroMovie != nil {
                Button { heroMuted.toggle() } label: {
                    Image(systemName: heroMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(heroMuted ? "Unmute trailer" : "Mute trailer")
                .padding(.trailing, 14)
                .padding(.bottom, 12)
            }
        }
    }

    /// A real trailer from the record: server HD file first, then a direct
    /// non-YouTube file. Never resolved client-side — dead third-party URLs
    /// are what produced the black muted boxes.
    private func heroClip(_ movie: Movie) -> (url: URL, apiKey: String?)? {
        if let raw = movie.trailerFileUrl, let url = URL(string: raw), url.scheme == "https" {
            let key = url.host?.contains("cornerstonecoatings.com") == true ? library.api.key : nil
            return (url, key)
        }
        if movie.trailerSite != "youtube",
           let raw = movie.trailerUrl, let url = URL(string: raw), url.scheme == "https" {
            return (url, nil)
        }
        return nil
    }

    private func youtubeKey(_ movie: Movie) -> String? {
        if movie.trailerSite == "youtube", let key = movie.trailerKey, !key.isEmpty { return key }
        if let resolved = trailerKeys[movie.id], !resolved.isEmpty { return resolved }
        return nil
    }

    /// No trailer on the record: ask Kinocheck (by IMDb id) for the English
    /// pure trailer and embed it. Ends at the YouTube id — no MP4 resolution,
    /// no third-party stream URLs, no black boxes.
    private func resolveTrailerKey() async {
        guard let movie = heroMovie,
              heroClip(movie) == nil,
              youtubeKey(movie) == nil,
              trailerKeys[movie.id] == nil,
              let imdb = movie.imdbId, !imdb.isEmpty,
              let metaURL = URL(string: "https://api.kinocheck.com/movies?imdb_id=\(imdb)&language=en")
        else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: metaURL)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            trailerKeys[movie.id] = Self.pickTrailer(obj) ?? ""
        } catch {
            trailerKeys[movie.id] = ""
        }
    }

    /// English pure trailer with the most views. Clips, talks, and specials
    /// are not trailers.
    private static func pickTrailer(_ obj: [String: Any]) -> String? {
        var cands: [[String: Any]] = []
        if let t = obj["trailer"] as? [String: Any] { cands.append(t) }
        cands.append(contentsOf: (obj["videos"] as? [[String: Any]]) ?? [])
        var best: String?
        var bestViews = -1
        for v in cands {
            guard let yt = v["youtube_video_id"] as? String, !yt.isEmpty else { continue }
            if let lang = v["language"] as? String, lang != "en" { continue }
            let cats = (v["categories"] as? [String]) ?? []
            guard cats.contains("Trailer"),
                  !cats.contains("Clip"), !cats.contains("Talk"), !cats.contains("Special")
            else { continue }
            let views = (v["views"] as? Int) ?? 0
            if views > bestViews { bestViews = views; best = yt }
        }
        return best
    }

    private func billboardArt(_ movie: Movie) -> some View {
        PosterImage(url: billboardURL(movie), title: movie.displayTitle)
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }

    private func billboardURL(_ movie: Movie) -> URL? {
        if let raw = movie.backdropUrl, let url = URL(string: raw) { return url }
        if let raw = movie.thumbnailUrl, let url = URL(string: raw) { return url }
        return posters[movie.id]
    }

    /// Big paged shelf, top-aligned with cards fitted to the page.
    /// The old centered spacers left a dead black gap on tall pages.
    private func shelfPage(_ s: Shelf, pageH: CGFloat) -> some View {
        // Shrink cards to fit short pages instead of clipping them in half.
        let cw = min(cardW, max(96, (pageH - 80) / 1.5))
        let ch = cw * 1.5
        return VStack(alignment: .leading, spacing: 10) {
            Text(s.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.top, 10)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(s.movies) { m in
                        VStack(alignment: .leading, spacing: 6) {
                            PosterImage(url: posters[m.id] ?? URL(string: m.thumbnailUrl ?? ""), title: m.displayTitle)
                                .frame(width: cw, height: ch)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            if s.id == "continue", let frac = continueFraction(m) {
                                ProgressView(value: frac)
                                    .tint(.red)
                                    .frame(width: cw)
                            }
                        }
                        .onTapGesture { play(m) }
                        .contextMenu { posterMenu(m) }
                    }
                }
                .padding(.horizontal, 20)
            }
            Spacer(minLength: 0)
        }
        .frame(height: pageH, alignment: .top)
    }

    private func continueFraction(_ m: Movie) -> Double? {
        let pos = library.positions[m.id] ?? 0
        guard pos > 1 else { return nil }
        if let mins = m.runtimeMin, mins > 0 {
            return min(1, max(0, pos / Double(mins * 60)))
        }
        return nil
    }

    @ViewBuilder private func posterMenu(_ m: Movie) -> some View {
        Button { play(m) } label: { Label("Play", systemImage: "play.fill") }
        if (library.fractions[m.id] ?? 0) >= 0.999 { Button { Task { await library.removeLocal(m) } } label: { Label("Remove Download", systemImage: "trash") } }
        else { Button { library.download(m) } label: { Label("Save to Device", systemImage: "arrow.down") } }
        Button { correcting = m } label: { Label("Correct Match", systemImage: "pencil") }
        Button { Task { await library.rematch(m) } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
        Button(role: .destructive) { Task { await library.delete(m) } } label: { Label("Delete", systemImage: "trash.fill") }
    }

    private var controls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack { Spacer()
                Button { importing = true } label: { Image(systemName: "plus").font(.system(size: 20, weight: .bold)).frame(width: 48, height: 48) }
                .buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel("Add a movie")
            }
            // Auth / network failures are otherwise invisible on home:
            // the list renders from disk cache while refresh fails.
            if let msg = library.message {
                Text(msg)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { Task { await library.refresh() } }
            }
        }.padding(.horizontal, 14).padding(.top, 6)
    }

    private var empty: some View {
        VStack(spacing: 18) {
            Text("WATCH").font(.system(size: 42, weight: .black)).tracking(2).foregroundStyle(Cinema.red)
            Text("Nothing here yet").font(.title2.weight(.bold))
            Button { importing = true } label: { Label("Add a movie", systemImage: "plus").font(.headline.weight(.bold)).padding(.horizontal, 22).padding(.vertical, 12).background(.white, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.black) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
    }

    private func handleImport(_ r: Result<[URL], Error>) {
        guard case .success(let urls) = r else { return }
        var items: [(URL, Bool)] = []
        for u in urls { let ext = u.pathExtension.lowercased(); guard ["mp4","m4v","mov"].contains(ext) else { continue }; items.append((u, u.startAccessingSecurityScopedResource())) }
        guard !items.isEmpty else { return }
        if items.count == 1, let only = items.first { pendingImport = only.0; pendingScoped = only.1 }
        else { library.importBulk(items) }
    }

    private func loadPosters() async {
        await withTaskGroup(of: (String, URL?).self) { group in
            for m in library.movies where posters[m.id] == nil {
                group.addTask { (m.id, await library.posterURL(for: m.id)) }
            }
            for await (id, url) in group { if let url { posters[id] = url } }
        }
    }

    private func play(_ m: Movie) { playing = m }
}

/// Native muted looping trailer. Poster stays underneath until first frame.
/// Muted because it's ambience — tap the hero to unmute.
private struct HeroTrailer: View {
    var url: URL
    var apiKey: String?
    var muted: Bool
    @State private var player: AVPlayer?
    @State private var ready = false
    @State private var tick: Any?
    @State private var endObserver: (any NSObjectProtocol)?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                HeroPlayerLayer(player: player)
                    .opacity(ready ? 1 : 0)
                    .animation(.easeIn(duration: 0.3), value: ready)
            }
        }
        .onAppear { start() }
        .onDisappear { stop() }
        .onChange(of: muted) { _, m in player?.isMuted = m }
    }

    private func start() {
        stop()
        ready = false
        var finalURL = url
        if let apiKey, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "key", value: apiKey)]
            finalURL = comps.url ?? url
        }
        let asset: AVURLAsset
        if let apiKey {
            asset = AVURLAsset(url: finalURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(apiKey)"]])
        } else {
            asset = AVURLAsset(url: finalURL)
        }
        let next = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        next.isMuted = muted
        next.allowsExternalPlayback = false
        next.actionAtItemEnd = .none
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: next.currentItem, queue: .main) { _ in
            next.seek(to: .zero)
            next.play()
        }
        tick = next.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
            if time.seconds > 0.05 { Task { @MainActor in ready = true } }
        }
        player = next
        next.play()
    }

    private func stop() {
        if let player, let tick { player.removeTimeObserver(tick) }
        tick = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        ready = false
        player?.pause()
        player = nil
    }
}

private struct HeroPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        (view.layer.sublayers?.first as? AVPlayerLayer)?.frame = view.bounds
    }
}

private struct Shelf: Identifiable { let id: String; let title: String; let movies: [Movie] }

/// Last-resort hero: the movie's own YouTube key, muted loop. Only used when
/// there is no server trailer file. The mute toggle is forwarded in.
private struct YouTubeTrailer: UIViewRepresentable {
    var key: String
    var muted: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.loadHTMLString(Self.page(key: key), baseURL: nil)
        context.coordinator.key = key
        context.coordinator.muted = muted
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.key != key {
            context.coordinator.key = key
            web.loadHTMLString(Self.page(key: key), baseURL: nil)
        } else if context.coordinator.muted != muted {
            context.coordinator.muted = muted
            web.evaluateJavaScript(muted ? "window.__p&&window.__p.mute()" : "window.__p&&window.__p.unMute()", completionHandler: nil)
        }
    }

    final class Coordinator {
        var key: String?
        var muted = true
    }

    static func page(key: String) -> String {
        """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"></head>
        <body style="margin:0;background:#000;overflow:hidden">
        <div id="p" style="position:absolute;top:0;left:0;width:100%;height:100%"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        function onYouTubeIframeAPIReady(){
          window.__p=new YT.Player('p',{videoId:'\(key)',playerVars:{autoplay:1,mute:1,controls:0,playsinline:1,rel:0,loop:1,playlist:'\(key)',modestbranding:1},events:{onReady:function(e){e.target.playVideo();}}});
        }
        </script></body></html>
        """
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
