import SwiftUI

struct DetailView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.horizontalSizeClass) private var hSize
    var movieID: String
    @State private var playMovie: Movie?
    @State private var poster: URL?

    private var movie: Movie? { library.movies.first { $0.id == movieID } }

    var body: some View {
        Group {
            if let movie {
                content(for: movie)
            } else {
                ContentUnavailableView("Movie removed", systemImage: "film")
            }
        }
        .task {
            if let movie {
                poster = await library.posterURL(for: movie.id)
            }
        }
    }

    @ViewBuilder
    private func content(for movie: Movie) -> some View {
        GeometryReader { geo in
            let artH = hSize == .compact
                ? max(220, min(geo.size.height * 0.38, 360))
                : min(geo.size.height * 0.42, 520)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .bottomLeading) {
                        PosterImage(url: poster ?? URL(string: movie.thumbnailUrl ?? ""), title: movie.displayTitle)
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: artH)
                            .clipped()
                        LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom)
                        Text(movie.displayTitle)
                            .font(.largeTitle.weight(.heavy))
                            .fontDesign(.serif)
                            .foregroundStyle(.white)
                            .padding(20)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 18) {
                        Text(meta(movie))
                            .foregroundStyle(Cinema.mute)
                        if !movie.overview.isEmpty {
                            Text(movie.overview)
                                .foregroundStyle(Cinema.ink.opacity(0.9))
                        }
                        HStack(spacing: 12) {
                            Button {
                                playMovie = movie
                            } label: {
                                Label("Play", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                            Button {
                                library.download(movie)
                            } label: {
                                Label(downloadLabel(movie), systemImage: (library.fractions[movie.id] ?? 0) >= 0.999 ? "checkmark" : "arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                            .overlay { SaveRing(progress: library.downloading[movie.id]) }
                            .disabled((library.fractions[movie.id] ?? 0) >= 0.999)
                        }
                        if let progress = library.downloading[movie.id] {
                            ProgressView(value: progress) {
                                Text("Saving \(byteText(Int64(progress * Double(movie.byteSize)))) of \(byteText(movie.byteSize))")
                                    .font(.caption)
                                    .foregroundStyle(Cinema.mute)
                            }
                            .tint(Cinema.red)
                            Text("Keep Watch open to finish saving.")
                                .font(.caption)
                                .foregroundStyle(Cinema.mute)
                        }
                        if (library.fractions[movie.id] ?? 0) >= 0.999 {
                            Button("Remove download from this device") {
                                Task { await library.removeLocal(movie) }
                            }
                            .font(.footnote)
                            .foregroundStyle(Cinema.mute)
                        }
                        if !movie.subtitles.isEmpty {
                            Text("Subtitles")
                                .font(.headline)
                                .foregroundStyle(Cinema.ink)
                            ForEach(movie.subtitles) { track in
                                HStack {
                                    Text(track.label)
                                    if track.source == "opensubtitles" {
                                        Text("This version")
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Cinema.red.opacity(0.35), in: Capsule())
                                    }
                                    Spacer()
                                    Text(track.lang.uppercased())
                                        .foregroundStyle(Cinema.mute)
                                }
                                .foregroundStyle(Cinema.ink)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: Cinema.column, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .modifier(FullScreenPlayer(movie: $playMovie))
        }
    }

    private func meta(_ movie: Movie) -> String {
        [movie.yearText, movie.runtimeText, movie.genres.joined(separator: " · ")]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func downloadLabel(_ movie: Movie) -> String {
        if (library.fractions[movie.id] ?? 0) >= 0.999 { return "Downloaded" }
        if library.downloading[movie.id] != nil { return "Saving" }
        return "Download"
    }
}