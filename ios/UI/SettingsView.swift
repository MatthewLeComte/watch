import SwiftUI
import UniformTypeIdentifiers

/// Correct a wrong automatic match. Does not change the server, the key, or delete the file.
struct SettingsView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Movie?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Wrong match")
                        .font(.system(.largeTitle, design: .serif))
                        .foregroundStyle(Cinema.ink)
                    Text("If a file was matched to the wrong movie, correct the title, year, overview, and poster. The video stays on the server.")
                        .font(.callout)
                        .foregroundStyle(Cinema.mute)
                    if library.movies.isEmpty {
                        Text("No files on the server yet.")
                            .foregroundStyle(Cinema.mute)
                    }
                    ForEach(library.movies) { movie in
                        Button { editing = movie } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(movie.title)
                                        .font(.headline)
                                        .foregroundStyle(Cinema.ink)
                                    Text(movie.filename)
                                        .font(.caption)
                                        .foregroundStyle(Cinema.mute)
                                        .lineLimit(1)
                                    if movie.matchSource == "manual" {
                                        Text("Corrected")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(Cinema.red)
                                    }
                                }
                                Spacer()
                                Image(systemName: "pencil")
                                    .foregroundStyle(Cinema.mute)
                            }
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Cinema.ink.opacity(0.08))
                    }
                }
                .padding(24)
            }
            .background(Cinema.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $editing) { movie in
                CorrectMatchView(movie: movie)
            }
        }
    }
}

struct CorrectMatchView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    var movie: Movie
    @State private var title = ""
    @State private var year = ""
    @State private var overview = ""
    @State private var imdbId = ""
    @State private var pickingPoster = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(movie.filename)
                        .font(.caption)
                        .foregroundStyle(Cinema.mute)
                    labeled("IMDb id") {
                        TextField("tt0053604", text: $imdbId)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                    }
                    Text("This is the id other library apps store. Saving it loads that title, poster, and trailer once. It does not search again.")
                        .font(.caption)
                        .foregroundStyle(Cinema.mute)
                    labeled("Title") {
                        TextField("Title", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeled("Year") {
                        TextField("Year", text: $year)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeled("Overview") {
                        TextField("Overview", text: $overview, axis: .vertical)
                            .lineLimit(4...8)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("Replace poster") { pickingPoster = true }
                        .buttonStyle(.bordered)
                    Button {
                        saving = true
                        let parsed = Int(year.trimmingCharacters(in: .whitespaces))
                        Task {
                            await library.save(
                                movie,
                                title: title.trimmingCharacters(in: .whitespaces),
                                year: parsed,
                                overview: overview,
                                imdbId: imdbId.trimmingCharacters(in: .whitespaces)
                            )
                            saving = false
                            dismiss()
                        }
                    } label: {
                        Text(saving ? "Saving" : "Save correction")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Cinema.red)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
                .padding(24)
            }
            .background(Cinema.bg.ignoresSafeArea())
            .navigationTitle("Correct match")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { fill(movie) }
            .fileImporter(isPresented: $pickingPoster, allowedContentTypes: [.image]) { result in
                if case .success(let url) = result {
                    Task { await library.attachPoster(movie, url: url) }
                }
            }
        }
    }

    private func labeled<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.caption).foregroundStyle(Cinema.mute)
            content()
        }
    }

    private func fill(_ movie: Movie) {
        title = movie.title
        year = movie.year.map(String.init) ?? ""
        overview = movie.overview
        imdbId = movie.imdbId ?? ""
    }
}
