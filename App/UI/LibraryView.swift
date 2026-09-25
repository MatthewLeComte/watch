import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

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
            .modifier(FullScreenPlayer(movie: $playing))
            .refreshable { await library.refresh(); await loadPosters() }
            .onChange(of: library.openImport) { if let url = library.openImport { pendingImport = url; pendingScoped = library.openImportScoped; library.openImport = nil } }
            .onChange(of: shelves.map(\.id)) { _, ids in if let id = shelfID, !ids.contains(id) { shelfID = nil } }
            .task { await loadPosters() }
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
            let videoH = w * 9 / 16
            let infoH: CGFloat = 190
            let heroH = videoH + infoH
            let pageH = max(200, h - heroH)
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
    }

    private func billboard(width: CGFloat, videoH: CGFloat, infoH: CGFloat) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if playing == nil,
                   let movie = heroMovie,
                   let raw = movie.trailerFileUrl,
                   let url = URL(string: raw) {
                    HeroTrailer(url: url, apiKey: library.api.key)
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
            Button { importing = true } label: { Image(systemName: "plus").font(.system(size: 20, weight: .bold)).frame(width: 48, height: 48) }
            .buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel("Add a movie")
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
private struct HeroTrailer: View {
    var url: URL
    var apiKey: String
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
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(apiKey)"]])
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

extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
