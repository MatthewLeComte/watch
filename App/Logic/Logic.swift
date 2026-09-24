import Foundation
import SwiftUI

/// Logic category — exactly 10 functions. Business rules that sit on top of
/// the Data layer and the LibraryModel.
enum Logic {

    /// 1. Boot the library.
    @MainActor
    static func boot(library: LibraryModel) async {
        await library.boot()
    }

    /// 2. Import a single file.
    @MainActor
    static func `import`(library: LibraryModel, url: URL, scoped: Bool) async {
        let model = ImportModel()
        model.onProgress = { _, _, _ in }
        model.onError = { _ in }
        model.start(url: url, scoped: scoped, api: library.api) { movie in
            library.adopt(movie)
        }
    }

    /// 3. Import a bulk batch.
    @MainActor
    static func importBulk(library: LibraryModel, urls: [(URL, Bool)]) {
        library.importBulk(urls)
    }

    /// 4. Resolve a playable URL.
    @MainActor
    static func play(library: LibraryModel, id: String) async -> URL? {
        if let movie = library.movies.first(where: { $0.id == id }),
           let local = await library.media.playableFile(movie) { return local }
        do {
            let movie = try await library.api.playback(id: id)
            if let hls = movie.hlsUrl, let url = URL(string: hls) { return url }
        } catch {}
        return nil
    }

    /// 5. Download for offline.
    @MainActor
    static func download(library: LibraryModel, movie: Movie) {
        library.download(movie)
    }

    /// 6. Delete a movie.
    @MainActor
    static func delete(library: LibraryModel, movie: Movie) async {
        await library.delete(movie)
    }

    /// 7. Rematch against IMDb/TMDb.
    @MainActor
    static func rematch(library: LibraryModel, movie: Movie) async {
        await library.rematch(movie)
    }

    /// 8. Search the library.
    @MainActor
    static func search(library: LibraryModel, query: String) -> [Movie] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return library.movies }
        return library.movies.filter {
            $0.displayTitle.lowercased().contains(q) ||
            ($0.overview.lowercased().contains(q))
        }
    }

    /// 9. Typed field accessor for a movie.
    @MainActor
    static func field(movie: Movie, key: String) -> Any? {
        switch key {
        case "id": return movie.id
        case "title": return movie.displayTitle
        case "year": return movie.year
        case "overview": return movie.overview
        case "runtime_min": return movie.runtimeMin
        case "imdb_id": return movie.imdbId
        case "hls_url": return movie.hlsUrl
        case "byte_size": return movie.byteSize
        case "ready_to_stream": return movie.readyToStream
        default: return nil
        }
    }

    /// 10. Patch editable fields.
    @MainActor
    static func patch(library: LibraryModel, movie: Movie, title: String, year: Int?, overview: String, imdbId: String?) async {
        await library.save(movie, title: title, year: year, overview: overview, imdbId: imdbId)
    }
}
