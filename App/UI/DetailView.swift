import SwiftUI

struct PlayerCover<Cover: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder var cover: () -> Cover

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                cover()
            }
        }
    }
}

struct DetailView: View {
    @Environment(LibraryModel.self) private var library
    var movieID: String
    @State private var playing = false
    @State private var poster: URL?

    private var movie: Movie? { library.movies.first { $0.id == movieID } }

    var body: some View {
        Group {
            if let movie {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ZStack(alignment: .bottomLeading) {
                            PosterImage(url: poster ?? URL(string: movie.thumbnailUrl ?? ""), title: movie.displayTitle)
                                .frame(maxWidth: .infinity)
                                .frame(height: 460)
                                .clipped()
                            LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom)
                            Text(movie.displayTitle)
                                .font(.system(size: 40, weight: .heavy))
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
                        if movie.matchSource != "manual", !movie.matchNote.isEmpty {
                            Text(movie.matchNote)
                                .font(.footnote)
                                .foregroundStyle(Cinema.mute)
                        }
                        HStack(spacing: 12) {
                            Button {
                                playing = true
                            } label: {
                                Label("Play", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.white)
                            .foregroundStyle(.black)
                            Button {
                                library.download(movie)
                            } label: {
                                Label(downloadLabel(movie), systemImage: "arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
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
                    }
                }
                .background(Color.black.ignoresSafeArea())
                .navigationTitle(movie.displayTitle)
                .modifier(PlayerCover(isPresented: $playing) {
                    PlayerView(movie: movie, onClose: { playing = false })
                })
                .task {
                    poster = await library.posterURL(for: movie.id)
                }
            } else {
                ContentUnavailableView("Movie removed", systemImage: "film")
            }
        }
    }

    private func meta(_ movie: Movie) -> String {
        [movie.yearText, movie.runtimeText, movie.genres.joined(separator: " · ")]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func downloadLabel(_ movie: Movie) -> String {
        if (library.fractions[movie.id] ?? 0) >= 0.999 { return "On this device" }
        if library.downloading[movie.id] != nil { return "Saving" }
        return "Download"
    }
}
