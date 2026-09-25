import Foundation
import Observation
import UIKit

struct BulkItem: Identifiable {
    var id: UUID = UUID()
    var url: URL
    var scoped: Bool
    var progress: Double = 0
    var stage: String = "Queued"
    var status: BulkStatus = .pending
    var error: String? = nil
    var movieTitle: String? = nil
    var movieID: String? = nil
}

enum BulkStatus { case pending, uploading, done, failed }

@MainActor
@Observable
final class LibraryModel {
    var movies: [Movie] = []
    var fractions: [String: Double] = [:]
    var positions: [String: Double] = [:]
    var message: String?
    /// Set by onOpenURL (share sheet / document types). LibraryView routes
    /// it into the dedicated import page.
    var openImport: URL?
    var openImportScoped = false
    var downloading: [String: Double] = [:]
    var serverText: String
    var keyText: String

    let media = MediaStore()
    private var downloads: [String: Task<Void, Never>] = [:]
    private let defaults = UserDefaults.standard

    init() {
        serverText = defaults.string(forKey: "watch.server") ?? WatchBuiltIn.server
        keyText = defaults.string(forKey: "watch.key") ?? WatchBuiltIn.key
        if let data = try? Data(contentsOf: Self.cacheURL()),
           let list = try? JSONDecoder().decode([Movie].self, from: data) {
            movies = list
        }
        if let data = defaults.data(forKey: "watch.positions"),
           let saved = try? JSONDecoder().decode([String: Double].self, from: data) {
            positions = saved
        }
    }

    var api: WatchAPI {
        let trimmed = serverText.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = URL(string: trimmed) ?? URL(string: WatchBuiltIn.server)!
        return WatchAPI(base: url, key: keyText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func boot() async {
        await refreshFractions()
        await refresh()
        await cachePosters()
    }

    func saveSettings() {
        defaults.set(serverText.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: "watch.server")
        defaults.set(keyText.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "watch.key")
    }

    func refresh() async {
        do {
            let items = try await api.items()
            movies = items
            message = nil
            if let data = try? JSONEncoder().encode(items) {
                try? data.write(to: Self.cacheURL(), options: .atomic)
            }
            await refreshFractions()
        } catch {
            message = error.localizedDescription
        }
    }

    func refreshFractions() async {
        await withTaskGroup(of: (String, Double).self) { group in
            for movie in movies {
                group.addTask { [self] in (movie.id, await media.fraction(id: movie.id, byteSize: movie.byteSize)) }
            }
            var next: [String: Double] = [:]
            for await (id, frac) in group { next[id] = frac }
            fractions = next
        }
    }

    func cachePosters() async {
        await withTaskGroup(of: Void.self) { group in
            for movie in movies {
                group.addTask { [self] in _ = await media.posterFile(api: api, id: movie.id) }
            }
        }
    }

    func posterURL(for id: String) async -> URL? {
        await media.posterFile(api: api, id: id)
    }

    func remember(position: Double, for id: String) {
        let old = positions[id] ?? 0
        positions[id] = position
        // Persist at most every ~5s of playback — the tick fires 4x/sec and
        // JSON-encoding UserDefaults on every tick stalls the main thread.
        let now = Date().timeIntervalSince1970
        guard abs(position - old) > 2 || now - lastPositionSave > 5 else { return }
        lastPositionSave = now
        if let data = try? JSONEncoder().encode(positions) {
            defaults.set(data, forKey: "watch.positions")
        }
    }
    private var lastPositionSave: Double = 0

    /// Called by the dedicated import page when its two-stage
    /// process→upload flow finishes. Inserts the movie + caches its poster.
    func adopt(_ movie: Movie) {
        if let index = movies.firstIndex(where: { $0.id == movie.id }) {
            movies[index] = movie
        } else {
            movies.insert(movie, at: 0)
        }
        Task { _ = await media.posterFile(api: api, id: movie.id) }
    }

    // MARK: - Pending posters (not-ready-yet cards in the library grid)

    /// A movie being processed/uploaded. Rendered as a pending poster with
    /// live stage + progress right in the library — never hidden in a menu.
    var pending: [PendingImport] = []

    @discardableResult
    func beginPending(filename: String) -> UUID {
        let entry = PendingImport(id: UUID(), filename: filename, stage: "Transcoding", progress: 0, detail: "Starting…")
        pending.append(entry)
        return entry.id
    }

    func updatePending(id: UUID, stage: String, progress: Double, detail: String) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[i].stage = stage
        pending[i].progress = min(max(progress, 0), 1)
        pending[i].detail = detail
    }

    func endPending(id: UUID) {
        pending.removeAll { $0.id == id }
    }

    func save(_ movie: Movie, title: String, year: Int?, overview: String, imdbId: String? = nil) async {
        do {
            let updated = try await api.patch(id: movie.id, title: title, year: year, overview: overview, imdbId: imdbId)
            replace(updated)
        } catch {
            message = error.localizedDescription
        }
    }

    func rematch(_ movie: Movie) async {
        do {
            let updated = try await api.rematch(id: movie.id)
            replace(updated)
            _ = await media.posterFile(api: api, id: movie.id)
        } catch {
            message = error.localizedDescription
        }
    }

    func delete(_ movie: Movie) async {
        do {
            try await api.delete(id: movie.id)
            downloads[movie.id]?.cancel()
            try? await media.remove(id: movie.id)
            movies.removeAll { $0.id == movie.id }
        } catch {
            message = error.localizedDescription
        }
    }

    func attachSubtitle(_ movie: Movie, url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let updated = try await api.putSubtitle(id: movie.id, lang: "en", text: text, label: "English")
            replace(updated)
        } catch {
            message = error.localizedDescription
        }
    }

    func attachPoster(_ movie: Movie, url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let type = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            try await api.putPoster(id: movie.id, data: data, contentType: type)
            try? await media.removePoster(id: movie.id)
            _ = await media.posterFile(api: api, id: movie.id)
        } catch {
            message = error.localizedDescription
        }
    }

    func download(_ movie: Movie) {
        if downloads[movie.id] != nil { return }
        if (fractions[movie.id] ?? 0) >= 0.999 { return }
        downloading[movie.id] = fractions[movie.id] ?? 0
        let api = self.api
        downloads[movie.id] = Task {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "watch.save") {}
        defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
            do {
                for try await fraction in await media.prefetch(api: api, movie: movie) {
                    downloading[movie.id] = fraction
                    fractions[movie.id] = fraction
                }
                fractions[movie.id] = await media.fraction(id: movie.id, byteSize: movie.byteSize)
                downloading[movie.id] = nil
            } catch is CancellationError {
                downloading[movie.id] = nil
            } catch {
                message = error.localizedDescription
                downloading[movie.id] = nil
            }
            downloads[movie.id] = nil
        }
    }

    func removeLocal(_ movie: Movie) async {
        downloads[movie.id]?.cancel()
        downloads[movie.id] = nil
        downloading[movie.id] = nil
        try? await media.remove(id: movie.id)
        fractions[movie.id] = 0
    }

    func subtitleText(_ movie: Movie, lang: String) async throws -> String {
        try await media.subtitleFile(api: api, id: movie.id, lang: lang)
    }

    private func replace(_ movie: Movie) {
        if let index = movies.firstIndex(where: { $0.id == movie.id }) {
            movies[index] = movie
        }
    }

    private static func cacheURL() -> URL {
        let root = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("Watch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }

    // MARK: - Bulk import (dedicated multi-upload view)

    var bulkItems: [BulkItem] = []
    private var bulkInFlight: Int = 0
    private var bulkPending: [BulkItem] = []
    private let bulkMaxConcurrent = 2

    var bulkRunningCount: Int {
        bulkItems.filter { $0.status == .pending || $0.status == .uploading }.count
    }
    var bulkAllFinished: Bool {
        !bulkItems.isEmpty && bulkItems.allSatisfy { $0.status == .done || $0.status == .failed }
    }

    func importBulk(_ urls: [(URL, Bool)]) {
        let new = urls.map { BulkItem(url: $0.0, scoped: $0.1) }
        bulkItems.append(contentsOf: new)
        bulkPending.append(contentsOf: new)
        pumpBulk()
    }

    func retryBulk(id: UUID) {
        guard let i = bulkItems.firstIndex(where: { $0.id == id }) else { return }
        bulkItems[i].status = .pending
        bulkItems[i].error = nil
        bulkItems[i].progress = 0
        bulkItems[i].stage = "Queued"
        bulkPending.append(bulkItems[i])
        pumpBulk()
    }

    func removeBulk(id: UUID) {
        bulkItems.removeAll { $0.id == id }
        bulkPending.removeAll { $0.id == id }
    }

    func clearFinishedBulk() {
        bulkItems.removeAll { $0.status == .done || $0.status == .failed }
    }

    private func pumpBulk() {
        while bulkInFlight < bulkMaxConcurrent, let next = bulkPending.first {
            bulkPending.removeFirst()
            bulkInFlight += 1
            runBulkOne(next)
        }
    }

    private func runBulkOne(_ item: BulkItem) {
        updateBulk(id: item.id) {
            $0.status = .uploading
            $0.stage = "Preparing"
        }
        let model = ImportModel()
        model.onProgress = { [weak self] overall, stage, _ in
            self?.updateBulk(id: item.id) {
                $0.progress = overall
                $0.stage = stage
            }
        }
        model.onError = { [weak self] msg in
            guard let self else { return }
            self.updateBulk(id: item.id) {
                $0.status = .failed
                $0.error = msg
                $0.stage = "Failed"
            }
            self.bulkInFlight -= 1
            self.pumpBulk()
        }
        model.start(url: item.url, scoped: item.scoped, api: self.api) { [weak self] movie in
            guard let self else { return }
            self.updateBulk(id: item.id) {
                $0.status = .done
                $0.progress = 1
                $0.stage = "Done"
                $0.movieTitle = movie.displayTitle
                $0.movieID = movie.id
            }
            self.adopt(movie)
            self.bulkInFlight -= 1
            self.pumpBulk()
        }
    }

    private func updateBulk(id: UUID, _ mutate: (inout BulkItem) -> Void) {
        if let i = bulkItems.firstIndex(where: { $0.id == id }) {
            mutate(&bulkItems[i])
        }
    }
}

extension MediaStore {
    func removePoster(id: String) throws {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let file = root.appendingPathComponent("Watch/media/\(id)/poster.img")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
