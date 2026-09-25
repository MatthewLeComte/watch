import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(LibraryModel.self) private var library
    @State private var importing = false
    @State private var correcting: Movie?
    @State private var pendingImport: URL?
    @State private var pendingScoped = false
    @State private var bulkSheetPresented = false
    @State private var posters: [String: URL] = [:]
    @State private var playing: Movie?

    private let posterWidth: CGFloat = 140
    private let posterHeight: CGFloat = 210

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
            .modifier(PlayerCover(isPresented: Binding(get: { playing != nil }, set: { if !$0 { playing = nil } })) { if let p = playing { PlayerView(movie: p, onClose: { playing = nil }) } })
            .refreshable { await library.refresh(); await loadPosters() }
            .onChange(of: library.openImport) { if let url = library.openImport { pendingImport = url; pendingScoped = library.openImportScoped; library.openImport = nil } }
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

    private var heroMovie: Movie? { library.movies.first }

    private var home: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                trailerHero
                ForEach(shelves) { shelfRow($0) }
            }
        }
    }

    private var trailerHero: some View {
        ZStack {
            Color.black
            // Single player rule: trailer unmounts the moment the movie player opens.
            if playing == nil, let movie = heroMovie, let url = Trailer.url(for: movie) {
                TrailerView(url: url)
                    .id(url.absoluteString)
                    .allowsHitTesting(false)
            } else if let movie = heroMovie {
                PosterImage(url: posters[movie.id] ?? URL(string: movie.thumbnailUrl ?? ""), title: movie.displayTitle)
            }
            if let movie = heroMovie {
                VStack(spacing: 8) {
                    Spacer()
                    Text(movie.displayTitle)
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 12) {
                        if !movie.yearText.isEmpty { Text(movie.yearText) }
                        if let rt = movie.runtimeText { Text(rt) }
                        if !movie.genres.isEmpty { Text(movie.genres.first!).foregroundStyle(Cinema.red) }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.7), .black], startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
            }
        }
        .frame(height: 380)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { if let movie = heroMovie { play(movie) } }
    }

    private func shelfRow(_ s: Shelf) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(s.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(s.movies) { m in
                        PosterImage(url: posters[m.id] ?? URL(string: m.thumbnailUrl ?? ""), title: m.displayTitle)
                            .frame(width: posterWidth, height: posterHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .onTapGesture { play(m) }
                            .contextMenu { posterMenu(m) }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.vertical, 10)
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

    private func play(_ m: Movie) { withAnimation(.smooth(duration: 0.35)) { playing = m } }
}

private struct Shelf: Identifiable { let id: String; let title: String; let movies: [Movie] }

extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
