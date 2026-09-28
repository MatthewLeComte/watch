import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AVFoundation
import WebKit

private struct ImportMenuButton: UIViewRepresentable {
    var onImport: () -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "plus"), for: .normal)
        button.tintColor = .label
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [
            UIAction(title: "Import File", image: UIImage(systemName: "square.and.arrow.down")) { _ in
                context.coordinator.fire()
            }
        ])
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.fire = onImport
    }

    func makeCoordinator() -> Coordinator { Coordinator(fire: onImport) }

    final class Coordinator {
        var fire: () -> Void
        init(fire: @escaping () -> Void) { self.fire = fire }
    }
}

private final class VolumeUpUnmute: @unchecked Sendable {
    var onUp: @Sendable () -> Void = {}
    private let lock = NSLock()
    private var watch: NSKeyValueObservation?
    private var last: Float = -1

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)
        lock.lock()
        last = session.outputVolume
        lock.unlock()
        watch = session.observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            guard let self else { return }
            self.lock.lock()
            let now = session.outputVolume
            let rose = now > self.last + 0.001
            self.last = now
            let fire = self.onUp
            self.lock.unlock()
            if rose { fire() }
        }
    }
}

struct LibraryView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @State private var importing = false
    @State private var searchQuery = ""
    @State private var searchPresented = false
    @State private var searchResults: [SourceSearchResult] = []
    @State private var searchError: String?
    @State private var picked: SourceSearchResult?
    @State private var correcting: Movie?
    @State private var pendingImport: URL?
    @State private var pendingScoped = false
    @State private var bulkSheetPresented = false
    @State private var shelfID: String?
    @State private var posters: [String: URL] = [:]
    @State private var playing: Movie?
    @State private var youtubeIDs: [String: String] = [:]
    @AppStorage("watch.trailerAudible") private var trailerAudible = false
    @State private var volumeUp = VolumeUpUnmute()
    @State private var featuredID: String?

    private var isCompact: Bool { hSize == .compact }

    private func cardWidth(in width: CGFloat) -> CGFloat {
        let columns: CGFloat = isCompact ? 2.4 : (width > 1000 ? 6.2 : 4.6)
        return min(260, max(140, (width - 64) / columns))
    }

    private var heroFileURL: URL? { heroMovie?.trailerFilePlayURL }

    private var heroYouTubeID: String? {
        guard heroFileURL == nil, let movie = heroMovie else { return nil }
        return movie.youTubeID ?? youtubeIDs[movie.id]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if library.movies.isEmpty {
                    empty
                } else {
                    home
                }
                if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    searchResultsList
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .searchable(text: $searchQuery, isPresented: $searchPresented, prompt: "Movie or show")
            .task(id: searchQuery) { await runSearch() }
            .sheet(item: $picked) { result in
                RiveCaptureView(library: library, result: result) { picked = nil }
            }
            .toolbar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                if !searchPresented {
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        ImportMenuButton { importing = true }
                    }
                }
            }
            .navigationDestination(for: Movie.self) { DetailView(movieID: $0.id) }
            .sheet(item: $correcting) { CorrectMatchView(movie: $0) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.mpeg4Movie, .quickTimeMovie, .movie], allowsMultipleSelection: true) { handleImport($0) }
            .overlay { if let url = pendingImport { ImportView(url: url, scoped: pendingScoped) { pendingImport = nil } } }
            .sheet(isPresented: $bulkSheetPresented) { BulkImportView(onClose: { if library.bulkAllFinished { library.clearFinishedBulk() }; bulkSheetPresented = false }) }
            .onChange(of: library.bulkItems.count) { _, c in if c > 0 { bulkSheetPresented = true } }
            .modifier(FullScreenPlayer(movie: $playing))
            .sensoryFeedback(.impact(weight: .medium), trigger: playing?.id)

            .onChange(of: library.openImport) { if let url = library.openImport { pendingImport = url; pendingScoped = library.openImportScoped; library.openImport = nil } }
            .onChange(of: shelves.map(\.id)) { _, ids in if let id = shelfID, !ids.contains(id) { shelfID = nil } }
            .task { await loadPosters() }
            .task(id: library.movies.map(\.id).joined(separator: ",")) { await library.cachePlaylists() }
            .task(id: heroMovie?.id) { await resolveStreamTrailer() }
            .onAppear {
                volumeUp.onUp = { Task { @MainActor in trailerAudible = true } }
                volumeUp.start()
            }
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

    private var heroMovie: Movie? {
        if let featuredID, let movie = library.movies.first(where: { $0.id == featuredID }) { return movie }
        return library.movies.first
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 18) {
                trailerStage
                if let movie = heroMovie {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(movie.displayTitle)
                            .font(.largeTitle.weight(.heavy))
                            .fontDesign(.serif)
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text([movie.yearText, movie.runtimeText ?? "", movie.genres.prefix(3).joined(separator: " · ")].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 20)
                    HStack(spacing: 12) {
                        Button { play(movie) } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        Button { library.download(movie) } label: {
                            let saved = (library.fractions[movie.id] ?? 0) >= 0.999
                            Label(downloadTitle(movie), systemImage: saved ? "checkmark" : "arrow.down").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .disabled((library.fractions[movie.id] ?? 0) >= 0.999)
                        .overlay { SaveRing(progress: library.downloading[movie.id]) }
                    }
                    .padding(.horizontal, 20)
                    ScrollView {
                        Text(movie.overview.isEmpty ? " " : movie.overview)
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 18)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .scrollIndicators(.visible, axes: .vertical)
                    .padding(.horizontal, 20)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.45),
                                .init(color: .clear, location: 0.92)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            posterCarousel
                .frame(height: 162)
        }
        .padding(.top, -40)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trailerStage: some View {
        ZStack {
            Color.black
            if playing == nil, let url = heroFileURL {
                HeroTrailer(
                    url: url,
                    captionsURL: heroMovie?.trailerCaptions.flatMap(URL.init(string:)),
                    apiKey: library.api.key,
                    audible: trailerAudible,
                    suspended: picked != nil
                )
                .id(url.absoluteString)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { trailerAudible.toggle() }
            } else if let movie = heroMovie {
                PosterImage(url: billboardURL(movie), title: movie.displayTitle)
                    .scaledToFit()
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
        .overlay(alignment: .topTrailing) {
            if heroFileURL != nil, playing == nil {
                Image(systemName: trailerAudible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.body.weight(.semibold))
                    .padding(10)
                    .glassEffect(.regular, in: Circle())
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
    }

    private var posterCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(library.movies) { movie in
                    Button { featuredID = movie.id } label: {
                        PosterImage(url: posters[movie.id] ?? URL(string: movie.posterUrl ?? movie.thumbnailUrl ?? ""), title: movie.displayTitle)
                            .frame(width: 108, height: 162)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                if movie.id == heroMovie?.id {
                                    RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if (library.fractions[movie.id] ?? 0) > 0 || library.downloading[movie.id] != nil {
                            Button("Clear Download", systemImage: "trash", role: .destructive) {
                                Task { await library.clearDownload(movie) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
    }

    private func downloadTitle(_ movie: Movie) -> String {
        if (library.fractions[movie.id] ?? 0) >= 0.999 { return "Downloaded" }
        if library.downloading[movie.id] != nil { return "Saving" }
        return "Download"
    }

    @ViewBuilder private func shelfScroll(width: CGFloat) -> some View {
        if isCompact {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(shelves) { shelf in
                        shelfRow(shelf, width: width)
                            .containerRelativeFrame(.vertical)
                            .id(shelf.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $shelfID)
            .scrollIndicators(.hidden)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(shelves) { shelf in
                        shelfRow(shelf, width: width).id(shelf.id)
                    }
                }
                .padding(.bottom, 32)
            }
        }
    }

    private func heroCarousel(width: CGFloat) -> some View {
        let movie = heroMovie
        return ZStack(alignment: .bottom) {
            if let movie {
                PosterImage(url: billboardURL(movie), title: movie.displayTitle)
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                Color.black
            }
            if playing == nil, let url = heroFileURL {
                HeroTrailer(
                    url: url,
                    captionsURL: heroMovie?.trailerCaptions.flatMap(URL.init(string:)),
                    apiKey: library.api.key,
                    audible: trailerAudible,
                    suspended: picked != nil
                )
                    .id(url.absoluteString)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { trailerAudible.toggle() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(trailerAudible ? "Mute trailer" : "Unmute trailer")
            } else if playing == nil, let videoID = heroYouTubeID {
                YouTubeTrailer(videoID: videoID)
                    .id(videoID)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            if let movie {
                VStack(alignment: .leading, spacing: 10) {
                    Text(movie.displayTitle)
                        .font(.largeTitle.weight(.heavy))
                        .fontDesign(.serif)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    HStack(spacing: 10) {
                        if let p = movie.matchP, p > 0 {
                            Text("\(Int((p * 100).rounded()))% Match")
                                .font(.subheadline.weight(.bold).smallCaps())
                                .foregroundStyle(Cinema.ink)
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
                            .padding(.vertical, 14)
                            .padding(.horizontal, 28)
                            .frame(maxWidth: isCompact ? .infinity : Cinema.playColumn, alignment: .leading)
                            .background(.white, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, isCompact ? 20 : 32)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.85), .black], startPoint: .top, endPoint: .bottom)
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            if heroFileURL != nil, playing == nil {
                Image(systemName: trailerAudible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: width, maxHeight: .infinity, alignment: .bottom)
    }

    private func billboardURL(_ movie: Movie) -> URL? {
        if let raw = movie.backdropUrl, let url = URL(string: raw) { return url }
        if let raw = movie.thumbnailUrl, let url = URL(string: raw) { return url }
        return posters[movie.id]
    }

    private func shelfRow(_ s: Shelf, width window: CGFloat) -> some View {
        let card = cardWidth(in: window)
        return VStack(alignment: .leading, spacing: 12) {
            Text(s.title)
                .font(.headline.smallCaps())
                .foregroundStyle(.white)
                .padding(.horizontal, isCompact ? 20 : 32)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(s.movies) { m in
                        NavigationLink(value: m) {
                            VStack(alignment: .leading, spacing: 6) {
                                PosterImage(url: posters[m.id] ?? URL(string: m.thumbnailUrl ?? ""), title: m.displayTitle)
                                    .frame(width: card, height: card * 1.5)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                if s.id == "continue", let frac = continueFraction(m) {
                                    ProgressView(value: frac)
                                        .tint(Cinema.red)
                                        .frame(width: card)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu { posterMenu(m) }
                    }
                }
                .padding(.horizontal, isCompact ? 20 : 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: isCompact ? .infinity : nil, alignment: .top)
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
                Button { importing = true } label: { Label("Import File", systemImage: "square.and.arrow.down") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Add a movie")
        }.padding(.horizontal, isCompact ? 14 : 24).padding(.top, 6)
    }

    private var topInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.flatMap(\.windows).first
        return window?.safeAreaInsets.top ?? 59
    }

    private var searchResultsList: some View {
        Group {
            if let searchError, searchResults.isEmpty {
                ContentUnavailableView(searchError, systemImage: "exclamationmark.triangle")
            } else {
                List(searchResults) { result in
                    Button { open(result) } label: {
                        HStack(spacing: 14) {
                            PosterImage(url: result.poster.flatMap(URL.init(string:)), title: result.displayTitle)
                                .frame(width: 92, height: 138)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.displayTitle).font(.headline).foregroundStyle(.white)
                                if let year = result.year { Text(String(year)).font(.subheadline).foregroundStyle(.white.opacity(0.6)) }
                                Text(owned(result) == nil ? "Online" : "In your library")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.black)
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, topInset + 12, for: .scrollContent)
                .scrollIndicators(.hidden)
            }
        }
    }

    private func owned(_ result: SourceSearchResult) -> Movie? {
        library.movie(matching: result)
    }

    private func open(_ result: SourceSearchResult) {
        if let movie = library.movie(matching: result) {
            searchQuery = ""
            searchPresented = false
            play(movie)
            return
        }
        picked = result
    }

    private func runSearch() async {
        let term = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else {
            searchResults = []
            searchError = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled, term == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        searchError = nil
        do {
            let found = if term.hasPrefix("tt"), term.count >= 9 {
                try await library.sourceSearchByImdb(imdbId: term, source: "meta")
            } else {
                try await library.sourceSearch(query: term, source: "meta")
            }
            guard !Task.isCancelled else { return }
            searchResults = found
        } catch {
            guard !Task.isCancelled else { return }
            searchResults = []
            let message = error.localizedDescription
            searchError = message.contains("tmdb_unconfigured") ? "TMDB is not configured on the worker." : message
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

            }
            .padding(.horizontal, 40)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
    }

    private func handleImport(_ r: Result<[URL], Error>) {
        guard case .success(let urls) = r else { return }
        var items: [(URL, Bool)] = []
        for u in urls { let ext = u.pathExtension.lowercased(); guard ["mp4","m4v","mov","mkv","webm","avi","flv","wmv","mpg","mpeg","m2v","m4s","ts","m2ts","vob","ogv","3gp","3g2"].contains(ext) else { continue }; items.append((u, u.startAccessingSecurityScopedResource())) }
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

    /// TMDB YouTube id, stored by the worker. One lookup for the visible hero.
    private func resolveStreamTrailer() async {
        guard let movie = heroMovie,
              movie.youTubeID == nil,
              youtubeIDs[movie.id] == nil,
              movie.imdbId?.isEmpty == false
        else { return }
        let id = movie.id
        let imdb = movie.imdbId
        if let yt = try? await library.api.resolveTrailer(id: id), !yt.isEmpty {
            youtubeIDs[id] = yt
            return
        }
        guard let imdb, let yt = await cinemetaYouTube(imdb), !yt.isEmpty else { return }
        youtubeIDs[id] = yt
    }

    private func cinemetaYouTube(_ imdb: String) async -> String? {
        guard let url = URL(string: "https://v3-cinemeta.strem.io/meta/movie/\(imdb).json") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = obj["meta"] as? [String: Any],
              let streams = meta["trailerStreams"] as? [[String: Any]]
        else { return nil }
        return streams.compactMap { $0["ytId"] as? String }.first { !$0.isEmpty }
    }

    private func play(_ m: Movie) { playing = m }
}


private struct TrailerCue {
    var start: Double
    var end: Double
    var text: String

    static func parse(_ vtt: String) -> [TrailerCue] {
        var cues: [TrailerCue] = []
        let blocks = vtt.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timing = lines.first(where: { $0.contains("-->") }) else { continue }
            let parts = timing.components(separatedBy: "-->")
            guard parts.count >= 2 else { continue }
            let start = seconds(parts[0])
            let end = seconds(parts[1])
            let text = lines.drop { !$0.contains("-->") }.dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard end > start, !text.isEmpty else { continue }
            if cues.last?.text == text { continue }
            cues.append(TrailerCue(start: start, end: end, text: text))
        }
        return cues
    }

    private static func seconds(_ raw: String) -> Double {
        let clock = raw.split(separator: " ").first.map(String.init) ?? raw
        let bits = clock.split(separator: ":").map { Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        if bits.count == 3 { return bits[0] * 3600 + bits[1] * 60 + bits[2] }
        if bits.count == 2 { return bits[0] * 60 + bits[1] }
        return bits.first ?? 0
    }
}

private struct Shelf: Identifiable { let id: String; let title: String; let movies: [Movie] }
/// Muted looping trailer file from R2. The poster stays visible until the first frame.
private struct HeroTrailer: View {
    var url: URL
    var captionsURL: URL?
    var apiKey: String
    var audible: Bool
    var suspended: Bool = false
    @State private var player: AVPlayer?
    @State private var ready = false
    @State private var tick: Any?
    @State private var cues: [TrailerCue] = []
    @State private var shown = ""

    var body: some View {
        ZStack {
            Color.black
            if let player {
                HeroPlayerLayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(ready ? 1 : 0)
            }
        }
        .background(Color.black)
        .overlay(alignment: .bottom) {
            if !shown.isEmpty {
                Text(shown)
                    .font(.system(size: 16, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
            }
        }
        .onAppear { start() }
        .onDisappear { stop() }
        .onChange(of: audible) { _, on in applyAudio(on) }
        .onChange(of: suspended) { _, hold in
            if hold { player?.pause() } else { player?.play() }
        }
        .task(id: captionsURL) { await loadCaptions() }
    }

    private func loadCaptions() async {
        cues = []
        shown = ""
        guard let captionsURL else { return }
        var request = URLRequest(url: captionsURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8)
        else { return }
        cues = TrailerCue.parse(text)
    }

    private func start() {
        stop()
        ready = false
        var finalURL = url
        if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "key", value: apiKey)]
            finalURL = comps.url ?? url
        }
        let asset = AVURLAsset(url: finalURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(apiKey)"]])
        let next = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        next.isMuted = !audible
        next.allowsExternalPlayback = false
        next.actionAtItemEnd = .none
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: next.currentItem, queue: .main) { _ in
            next.seek(to: .zero)
            next.play()
        }
        tick = next.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
            let seconds = time.seconds
            Task { @MainActor in
                if seconds > 0.05 { ready = true }
                let line = cues.first { seconds >= $0.start && seconds < $0.end }?.text ?? ""
                if line != shown { shown = line }
            }
        }
        player = next
        applyAudio(audible)
        if !suspended { next.play() }
    }

    private func applyAudio(_ on: Bool) {
        player?.isMuted = !on
        guard on else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
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
    func makeUIView(context: Context) -> PlayerHost {
        let view = PlayerHost()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ view: PlayerHost, context: Context) {
        view.playerLayer.player = player
        view.playerLayer.frame = view.bounds
    }
}

private final class PlayerHost: UIView {
    let playerLayer = AVPlayerLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

/// Muted looping YouTube trailer. The poster stays visible behind the web view.
private struct YouTubeTrailer: UIViewRepresentable {
    var videoID: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.backgroundColor = .clear
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loadedID != videoID else { return }
        context.coordinator.loadedID = videoID
        let src = "https://www.youtube-nocookie.com/embed/\(videoID)?autoplay=1&mute=1&playsinline=1&controls=0&loop=1&playlist=\(videoID)&rel=0"
        let html = """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;background:transparent;height:100%}iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="\(src)" allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen></iframe>
        </body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com"))
    }

    final class Coordinator { var loadedID: String? }
}

extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}