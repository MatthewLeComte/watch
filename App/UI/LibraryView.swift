import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(LibraryModel.self) private var library
    @State private var importing = false
    @State private var correcting: Movie?
    @State private var pendingImport: URL?
    @State private var pendingScoped = false
    @State private var muted = true
    @State private var featuredID: String?
    @State private var videoAspect: CGFloat = 16.0 / 9.0
    @State private var posters: [String: URL] = [:]
    @State private var playing: Movie?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                if library.movies.isEmpty {
                    empty
                } else {
                    home
                }
                controls
            }
            .onDrop(of: [.movie, .mpeg4Movie, .quickTimeMovie], isTargeted: nil) { providers in
                acceptDrop(providers)
            }
            .toolbar { }
            .navigationDestination(for: Movie.self) { movie in
                DetailView(movieID: movie.id)
            }
            .sheet(item: $correcting) { movie in
                CorrectMatchView(movie: movie)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.mpeg4Movie, .quickTimeMovie, .movie]) { result in
                guard case .success(let url) = result else { return }
                let ext = url.pathExtension.lowercased()
                let scoped = url.startAccessingSecurityScopedResource()
                guard ["mp4", "m4v", "mov"].contains(ext) else {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    return
                }
                pendingScoped = scoped
                pendingImport = url
            }
            .overlay {
                // Full-page import on every screen. fullScreenCover is iOS-only;
                // an overlay is the same code everywhere and can't be swiped
                // into an orphaned import.
                if let url = pendingImport {
                    ImportView(url: url, scoped: pendingScoped) {
                        pendingImport = nil
                    }
                }
            }
            .modifier(PlayerCover(isPresented: Binding(
                get: { playing != nil },
                set: { if !$0 { playing = nil } }
            )) {
                if let playing { PlayerView(movie: playing, onClose: { self.playing = nil }) }
            })
            .refreshable { await library.refresh(); await loadPosters() }
            .onChange(of: library.openImport) {
                if let url = library.openImport {
                    pendingScoped = library.openImportScoped
                    pendingImport = url
                    library.openImport = nil
                }
            }
            .task {
                if featuredID == nil { featuredID = library.movies.first?.id }
                await loadPosters()
            }
        }
    }

    private var shelves: [Shelf] {
        var rows: [Shelf] = []
        let continuing = library.movies.filter { (library.positions[$0.id] ?? 0) > 30 }
        if !continuing.isEmpty {
            rows.append(Shelf(id: "continue", title: "Continue Watching", movies: continuing))
        }
        let saved = library.movies.filter { (library.fractions[$0.id] ?? 0) >= 0.999 }
        if !saved.isEmpty {
            rows.append(Shelf(id: "device", title: "Downloads", movies: saved))
        }
        var byGenre: [String: [Movie]] = [:]
        var loose: [Movie] = []
        for movie in library.movies {
            if movie.genres.isEmpty { loose.append(movie) }
            else {
                for genre in movie.genres { byGenre[genre, default: []].append(movie) }
            }
        }
        for genre in byGenre.keys.sorted() {
            rows.append(Shelf(id: "genre-\(genre)", title: genre, movies: byGenre[genre] ?? []))
        }
        if !loose.isEmpty {
            rows.append(Shelf(id: "movies", title: "Movies", movies: loose))
        } else if rows.isEmpty, !library.movies.isEmpty {
            rows.append(Shelf(id: "movies", title: "Movies", movies: library.movies))
        }
        return rows.filter { !$0.movies.isEmpty }
    }

    private var featured: Movie? {
        library.movies.first { $0.id == featuredID } ?? library.movies.first
    }

    private var home: some View {
        GeometryReader { geo in
            let aspect = max(videoAspect, 1.3)
            let ideal = geo.size.width / aspect
            let rowReserve = min(max(300, geo.size.height * 0.42), geo.size.height * 0.62)
            let hero = min(max(ideal, 200), max(200, geo.size.height - rowReserve))
            let rowBand = max(0, geo.size.height - hero)
            VStack(spacing: 0) {
                featuredCarousel(width: geo.size.width, height: hero)
                    .frame(width: geo.size.width, height: hero)
                rowPager(width: geo.size.width, height: rowBand)
                    .frame(width: geo.size.width, height: rowBand)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .animation(.smooth(duration: 0.35), value: hero)
        }
    }

    /// Featured shelf plays real trailers (YouTube key or trailer file),
    /// muted and looped — never the full movie. Tap toggles mute.
    /// Play, edit, and delete live on the context menu.
    private func featuredCarousel(width: CGFloat, height: CGFloat) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(library.movies) { movie in
                    ZStack {
                        Color.black
                        if Trailer.key(for: movie) != nil || Trailer.fileURL(for: movie) != nil {
                            TrailerPlayer(
                                key: Trailer.key(for: movie),
                                mp4: Trailer.fileURL(for: movie),
                                muted: muted
                            )
                        } else {
                            PosterImage(url: posters[movie.id] ?? URL(string: movie.thumbnailUrl ?? ""), title: movie.displayTitle)
                        }
                    }
                    .frame(width: width, height: height)
                    .id(movie.id)
                    .contentShape(Rectangle())
                    .onTapGesture { muted.toggle() }
                    .contextMenu { posterMenu(movie) }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $featuredID)
        .scrollIndicators(.hidden)
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 64)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            if featured != nil {
                Button {
                    muted.toggle()
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(muted ? "Unmute" : "Mute")
                .padding(.trailing, 14)
                .padding(.bottom, 28)
            }
        }
        .clipped()
    }

    private func rowPager(width: CGFloat, height: CGFloat) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                if !library.pending.isEmpty {
                    importingRow(width: width, height: height)
                        .containerRelativeFrame(.vertical)
                        .id("importing")
                }
                ForEach(shelves) { shelf in
                    rowPage(shelf, width: width, height: height)
                        .containerRelativeFrame(.vertical)
                        .id(shelf.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
    }

    private func rowPage(_ shelf: Shelf, width: CGFloat, height: CGFloat) -> some View {
        let showsDetails = shelf.id == shelves.first?.id
        let reserved: CGFloat = showsDetails ? 132 : 44
        let cardH = min(250, max(132, height - reserved - 24))
        let card = min(cardH / 1.5, max(96, width * 0.18))
        return VStack(alignment: .leading, spacing: 10) {
            if let featured, showsDetails {
                Text(featured.displayTitle)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.smooth(duration: 0.35)) { playing = featured }
                    }
                    .contextMenu { posterMenu(featured) }
                HStack(spacing: 8) {
                    if !featured.yearText.isEmpty { Text(featured.yearText) }
                    if let runtime = featured.runtimeText { Text(runtime) }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
                if !featured.overview.isEmpty {
                    Text(featured.overview)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                }
            }
            Text(shelf.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(shelf.movies) { movie in
                        PosterImage(url: posters[movie.id] ?? URL(string: movie.thumbnailUrl ?? ""), title: movie.displayTitle)
                            .frame(width: card, height: card * 1.5)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .onTapGesture { playing = movie }
                            .contextMenu { posterMenu(movie) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
    }

    /// Not-ready-yet posters with live transcode/upload progress,
    /// pinned above the shelves while imports run.
    private func importingRow(width: CGFloat, height: CGFloat) -> some View {
        let cardH = min(250, max(132, height - 44 - 24))
        let card = min(cardH / 1.5, max(96, width * 0.18))
        return VStack(alignment: .leading, spacing: 10) {
            Text("Importing")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(library.pending) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack {
                                LinearGradient(colors: [Color(white: 0.16), .black], startPoint: .top, endPoint: .bottom)
                                VStack(spacing: 6) {
                                    Image(systemName: "film")
                                        .font(.system(size: 30, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.85))
                                    Text("NOT READY YET")
                                        .font(.caption2.weight(.heavy))
                                        .foregroundStyle(Cinema.red)
                                    Text(item.stage.uppercased())
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: card, height: card * 1.5)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay(alignment: .bottom) {
                                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 44)
                            }
                            Text(item.filename)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                            ProgressView(value: item.progress)
                                .tint(Cinema.red)
                            Text("\(item.detail) — \(Int((item.progress * 100).rounded()))%")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                        .frame(width: card)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
    }

    /// Poster context menu: play, offline, match correction, rescan, delete.
    /// Edit lives here — not in a hamburger menu.
    @ViewBuilder
    private func posterMenu(_ movie: Movie) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.35)) { playing = movie }
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        if (library.fractions[movie.id] ?? 0) >= 0.999 {
            Button {
                Task { await library.removeLocal(movie) }
            } label: {
                Label("Remove download", systemImage: "trash")
            }
        } else {
            Button {
                library.download(movie)
            } label: {
                Label("Save to this device", systemImage: "arrow.down")
            }
        }
        Button {
            correcting = movie
        } label: {
            Label("Correct a match", systemImage: "pencil")
        }
        Button {
            Task { await library.rematch(movie) }
        } label: {
            Label("Rescan match", systemImage: "arrow.clockwise")
        }
        Button(role: .destructive) {
            Task { await library.delete(movie) }
        } label: {
            Label("Delete", systemImage: "trash.fill")
        }
    }

    private var featuredSelection: Binding<String> {
        Binding(
            get: { featured?.id ?? "" },
            set: { id in
                withAnimation(.smooth(duration: 0.45)) { featuredID = id }
            }
        )
    }

    /// No hamburger: one prominent glass Add button, top-trailing, 48pt.
    /// Everything else lives on the posters (context menus) and shelves.
    private var controls: some View {
        HStack {
            Spacer()
            Button { importing = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Add a movie")
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private func posterRow(_ shelf: Shelf, width: CGFloat) -> some View {
        let card = min(160, max(108, width * 0.28))
        return VStack(alignment: .leading, spacing: 10) {
            Text(shelf.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(shelf.movies) { movie in
                        PosterImage(url: posters[movie.id] ?? URL(string: movie.thumbnailUrl ?? ""), title: movie.displayTitle)
                            .frame(width: card, height: card * 1.5)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.smooth(duration: 0.35)) { playing = movie }
                            }
                            .contextMenu { posterMenu(movie) }
                    }
                }
                .padding(.horizontal, 18)
            }
        }
        .padding(.bottom, 22)
    }

    private var empty: some View {
        VStack(spacing: 18) {
            Text("WATCH")
                .font(.system(size: 42, weight: .black))
                .tracking(2)
                .foregroundStyle(Cinema.red)
            Text("Nothing here yet")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            Button { importing = true } label: {
                Label("Add a movie", systemImage: "plus")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    /// Drag-and-drop: drop movie files anywhere on the library to import.
    /// Each file is sandboxed immediately, then routed to the import page.
    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let movieIDs = [UTType.movie.identifier, UTType.mpeg4Movie.identifier, UTType.quickTimeMovie.identifier]
        var accepted = false
        for provider in providers {
            guard let type = movieIDs.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else { continue }
            accepted = true
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url, error == nil else { return }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-drop", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    Task { @MainActor in
                        pendingScoped = false
                        pendingImport = dest
                    }
                } catch { }
            }
        }
        return accepted
    }

    private func loadPosters() async {
        for movie in library.movies where posters[movie.id] == nil {
            if let url = await library.posterURL(for: movie.id) {
                posters[movie.id] = url
            }
        }
    }
}

private struct Shelf: Identifiable {
    var id: String
    var title: String
    var movies: [Movie]
}
