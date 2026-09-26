import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct LibraryView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @State private var importing = false
    @State private var showSourceSearch = false
    @State private var correcting: Movie?
    @State private var pendingImport: URL?
    @State private var pendingScoped = false
    @State private var bulkSheetPresented = false
    @State private var shelfID: String?
    @State private var posters: [String: URL] = [:]
    @State private var playing: Movie?
    @State private var streamTrailers: [String: URL] = [:]

    private var isCompact: Bool { hSize == .compact }
    private var isRegular: Bool { hSize == .regular }

    /// Adaptive card width: ~150pt on iPhone, ~180pt on iPad/Mac
    private var cardWidth: CGFloat { isCompact ? 150 : 180 }
    private var cardHeight: CGFloat { cardWidth * 1.5 }

    /// Hero trailer: server HD file wins; else resolve direct MP4
    /// (Kinocheck match → Piped stream URL), streamed natively.
    private var heroStreamURL: URL? {
        guard let movie = heroMovie else { return nil }
        if let raw = movie.trailerFileUrl, let url = URL(string: raw) { return url }
        return streamTrailers[movie.id]
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                if library.movies.isEmpty { empty } else { home }
                if isCompact { controls }
            }
            .toolbar { if !isCompact { controls } }
            .navigationDestination(for: Movie.self) { DetailView(movieID: $0.id) }
            .sheet(item: $correcting) { CorrectMatchView(movie: $0) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.mpeg4Movie, .quickTimeMovie, .movie], allowsMultipleSelection: true) { handleImport($0) }
            .overlay { if let url = pendingImport { ImportView(url: url, scoped: pendingScoped) { pendingImport = nil } } }
            .sheet(isPresented: $bulkSheetPresented) { BulkImportView(onClose: { if library.bulkAllFinished { library.clearFinishedBulk() }; bulkSheetPresented = false }) }
            .onChange(of: library.bulkItems.count) { _, c in if c > 0 { bulkSheetPresented = true } }
            .modifier(FullScreenPlayer(movie: $playing))
            .refreshable { await library.refresh(); await loadPosters() }
            .onChange(of: library.openImport) { if let url = library.openImport { pendingImport = url; pendingScoped = library.openImportScoped; library.openImport = nil } }
            .onChange(of: shelves.map(\.id)) { _, ids in if let id = shelfID, !ids.contains(id) { shelfID = nil } }
            .task { await loadPosters() }
            .task(id: heroMovie?.id) { await resolveStreamTrailer() }
        }
        .navigationSplitViewStyle(.balanced)
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
            let videoH = min(w * 9 / 16, isCompact ? h * 0.4 : h * 0.35)
            let infoH: CGFloat = isCompact ? 160 : 140
            let heroH = videoH + infoH
            let pageH = max(200, h - heroH)

            if isRegular && !isCompact {
                NavigationSplitView {
                    sidebar(shelves: shelves, pageH: pageH)
                        .navigationTitle("Library")
                } detail: {
                    detailContent(w: w, h: h, videoH: videoH, infoH: infoH, heroH: heroH, pageH: pageH)
                }
            } else {
                detailContent(w: w, h: h, videoH: videoH, infoH: infoH, heroH: heroH, pageH: pageH)
            }
        }
    }

    private func sidebar(shelves: [Shelf], pageH: CGFloat) -> some View {
        List(shelves, selection: $shelfID) { shelf in
            NavigationLink(value: shelf.id) {
                Text(shelf.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 350)
    }

    private func detailContent(w: CGFloat, h: CGFloat, videoH: CGFloat, infoH: CGFloat, heroH: CGFloat, pageH: CGFloat) -> some View {
        VStack(spacing: 0) {
            billboard(width: w, videoH: videoH, infoH: infoH)
                .frame(width: w, height: heroH)
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(shelves) { shelf in
                        shelfRow(shelf, pageH: pageH)
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

    private func billboard(width: CGFloat, videoH: CGFloat, infoH: CGFloat) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if playing == nil,
                   let movie = heroMovie,
                   let url = heroStreamURL {
                    HeroTrailer(url: url, apiKey: url.host?.contains("cornerstonecoatings.com") == true ? library.api.key : nil)
                        .id(url.absoluteString)
                        .allowsHitTesting(false)
                } else if let movie = heroMovie {
                    billboardArt(movie)
                }
            }
            .frame(width: width, height: videoH)
            .clipped()
            if let movie = heroMovie {
                VStack(alignment: .leading, spacing: 10) {
                    Text(movie.displayTitle)
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    HStack(spacing: 10) {
                        if let p = movie.matchP, p > 0 {
                            Text("\(Int((p * 100).rounded()))% Match")
                                .foregroundStyle(.green)
                                .font(.subheadline.weight(.bold))
                        }
                        if !movie.yearText.isEmpty { Text(movie.yearText) }
                        if let rt = movie.runtimeText { Text(rt) }
                        Text("HD")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.7), lineWidth: 1))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    Button { play(movie) } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(width: width, height: infoH, alignment: .leading)
                .background(Color.black)
            }
        }
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

    private func shelfRow(_ s: Shelf, pageH: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer(minLength: 0)
            Text(s.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(s.movies) { m in
                        VStack(alignment: .leading, spacing: 6) {
                            PosterImage(url: posters[m.id] ?? URL(string: m.thumbnailUrl ?? ""), title: m.displayTitle)
                                .frame(width: cardW, height: cardH)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            if s.id == "continue", let frac = continueFraction(m) {
                                ProgressView(value: frac)
                                    .tint(.red)
                                    .frame(width: cardW)
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
        .frame(height: pageH)
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
        HStack { Spacer()
            Menu {
                Button {
                    importing = true
                } label: {
                    Label("Import File", systemImage: "square.and.arrow.down")
                }
                Button {
                    showSourceSearch = true
                } label: {
                    Label("Search 67movies", systemImage: "magnifyingglass")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Add a movie")
        }.padding(.horizontal, 14).padding(.top, 6)
        .sheet(isPresented: $showSourceSearch) {
            SourceSearchView()
        }
    }

    private var empty: some View {
        VStack(spacing: 18) {
            Text("WATCH").font(.system(size: 42, weight: .black)).tracking(2).foregroundStyle(Cinema.red)
            Text("Nothing here yet").font(.title2.weight(.bold))
            VStack(spacing: 12) {
                Button { importing = true } label: {
                    Label("Import File", systemImage: "square.and.arrow.down")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.black)
                }
                Button { showSourceSearch = true } label: {
                    Label("Search 67movies", systemImage: "magnifyingglass")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Cinema.red, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 40)
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

    /// Direct-stream trailer: Kinocheck (IMDb id → English pure trailer)
    /// then Piped (YouTube id → 720p h264 MP4). No server file needed.
    private func resolveStreamTrailer() async {
        guard let movie = heroMovie,
              movie.trailerFileUrl == nil,
              streamTrailers[movie.id] == nil,
              let imdb = movie.imdbId, !imdb.isEmpty,
              let metaURL = URL(string: "https://api.kinocheck.com/movies?imdb_id=\(imdb)&language=en")
        else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: metaURL)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ytId = TrailerResolver.pick(obj),
                  let fileURL = await TrailerResolver.streamURL(ytId: ytId)
            else { return }
            streamTrailers[movie.id] = fileURL
        } catch { }
    }

    private func play(_ m: Movie) { playing = m }
}

/// Native muted looping trailer. Poster stays underneath until first frame.
private struct HeroTrailer: View {
    var url: URL
    var apiKey: String?
    @State private var player: AVPlayer?
    @State private var ready = false
    @State private var tick: Any?

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
        next.isMuted = true
        next.allowsExternalPlayback = false
        next.actionAtItemEnd = .none
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: next.currentItem, queue: .main) { _ in
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

/// Trailer resolution without server files: Kinocheck match → Piped MP4.
enum TrailerResolver {
    private static let instances = [
        "https://pipedapi.reallyaweso.me",
        "https://pipedapi.adminforge.de",
        "https://pipedapi.kavin.rocks",
    ]

    static func pick(_ obj: [String: Any]) -> String? {
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

    static func streamURL(ytId: String) async -> URL? {
        for base in instances {
            guard let api = URL(string: "\(base)/streams/\(ytId)") else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: api)
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let streams = obj["videoStreams"] as? [[String: Any]]
                else { continue }
                var best: (url: String, h: Int)?
                for s in streams {
                    guard let raw = s["url"] as? String, let url = URL(string: raw),
                          let q = s["quality"] as? String,
                          let h = Int(q.replacingOccurrences(of: "p", with: "")),
                          h >= 480, h <= 1080
                    else { continue }
                    let codec = ((s["codec"] as? String) ?? "").lowercased()
                    let mime = ((s["mimeType"] as? String) ?? "").lowercased()
                    let format = ((s["format"] as? String) ?? "").lowercased()
                    guard codec.contains("avc") || mime.contains("mp4") || format.contains("mp4") else { continue }
                    if best == nil || h > best!.h { best = (url.absoluteString, h) }
                }
                if let best, let url = URL(string: best.url) { return url }
            } catch { continue }
        }
        return nil
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
