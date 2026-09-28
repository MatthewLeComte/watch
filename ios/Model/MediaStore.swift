import Foundation
import AVFoundation
import ImageIO

actor MediaStore {
    private var playerWaiters = 0
    private var flights: [String: Task<Void, Never>] = [:]
    private var downloadSessions: [String: HLSDownloadSession] = [:]

    func fraction(id: String, byteSize: Int64) -> Double {
        guard let index = try? loadIndex(id: id, byteSize: byteSize) else { return 0 }
        let covered = index.spans.reduce(Int64(0)) { $0 + ($1.end - $1.start) }
        guard byteSize > 0 else { return 0 }
        return min(1, Double(covered) / Double(byteSize))
    }

    func playableFile(_ movie: Movie) -> URL? {
        // 1. Byte-range MP4/MKV: complete file, no expiration, perfect for AirPlay offline
        if isComplete(id: movie.id, byteSize: movie.byteSize),
           let url = try? directory(id: movie.id).appendingPathComponent("movie.\(movie.ext)"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // 2. Exported MP4 (converted from HLS): single file, no expiration
        if let exported = try? exportedMP4URL(id: movie.id) {
            return exported
        }
        // 3. HLS .movpkg: LAST RESORT — only for offline scrubbing when NOT AirPlaying
        if let hlsFile = try? hlsPlayableFile(movie.id) {
            return hlsFile
        }
        return nil
    }

    /// Returns the exported MP4 URL if it exists (created after HLS download).
    func exportedMP4URL(id: String) -> URL? {
        let file = try? directory(id: id).appendingPathComponent("movie.mp4")
        return (file != nil && FileManager.default.fileExists(atPath: file!.path)) ? file : nil
    }

    func isComplete(id: String, byteSize: Int64) -> Bool {
        fraction(id: id, byteSize: byteSize) >= 0.999
    }

    func data(api: WatchAPI, movie: Movie, offset: Int64, length: Int) async throws -> Data {
        playerWaiters += 1
        defer { playerWaiters -= 1 }
        return try await load(api: api, movie: movie, offset: offset, length: length)
    }

    func prefetch(api: WatchAPI, movie: Movie) -> AsyncThrowingStream<Double, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Double, any Error>.makeStream()
        let job = Task {
            do {
                try await self.fill(api: api, movie: movie) { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            self.flights[movie.id] = nil
        }
        flights[movie.id] = job
        continuation.onTermination = { @Sendable _ in job.cancel() }
        return stream
    }

    /// Native HLS background download using AVAssetDownloadURLSession
    func downloadHLS(api: WatchAPI, movie: Movie, hlsURL: URL, headers: [String: String] = [:]) async throws -> URL {
        let session = HLSDownloadSession(movieID: movie.id, mediaStore: self)
        downloadSessions[movie.id] = session

        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: hlsURL, options: options)
        let config = URLSessionConfiguration.background(withIdentifier: "com.watch.hls.\(movie.id)")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        let downloadSession = AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: session, delegateQueue: OperationQueue.main)

        let task = downloadSession.makeAssetDownloadTask(asset: asset, assetTitle: movie.title, assetArtworkData: nil, options: nil)!
        session.task = task
        task.resume()

        // Wait for completion
        return try await session.completion()
    }

    func cancelHLSDownload(id: String) {
        downloadSessions[id]?.cancel()
        downloadSessions[id] = nil
    }

    func hlsDownloadProgress(id: String) -> Double? {
        downloadSessions[id]?.progress
    }

    func hlsPlayableFile(_ id: String) throws -> URL? {
        let file = try directory(id: id).appendingPathComponent("hls.movpkg")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        return nil
    }

    // Expose directory for HLS download session
    func hlsDirectory(id: String) throws -> URL {
        try directory(id: id)
    }

    func cancelPrefetch(id: String) {
        flights[id]?.cancel()
        flights[id] = nil
    }

    /// Turn a finished on-device HLS package into one mp4 next to it.
    func exportUnifiedVideo(movpkg: URL, name: String) async throws -> URL {
        let asset = AVURLAsset(url: movpkg)
        let safe = name
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let output = movpkg.deletingLastPathComponent().appendingPathComponent((safe.isEmpty ? "Movie" : safe) + ".mp4")
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.outputURL = output
        session.outputFileType = .mp4
        await session.export()
        guard session.status == .completed else {
            throw session.error ?? CocoaError(.fileWriteUnknown)
        }
        return output
    }

    func removePlayback(id: String) throws {
        flights[id]?.cancel()
        flights[id] = nil
        downloadSessions[id]?.cancel()
        downloadSessions[id] = nil
        let file = try directory(id: id).appendingPathComponent("hls.movpkg")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    func remove(id: String) throws {
        flights[id]?.cancel()
        flights[id] = nil
        downloadSessions[id]?.cancel()
        downloadSessions[id] = nil
        let folder = try directory(id: id)
        try FileManager.default.removeItem(at: folder)
    }

    func posterFile(api: WatchAPI, id: String, knownURL: URL? = nil) async -> URL? {
        do {
            let file = try directory(id: id).appendingPathComponent("poster.img")
            if imageFile(file) { return file }
            try? FileManager.default.removeItem(at: file)
            var data: Data?
            if let knownURL {
                data = try? await URLSession.shared.data(from: knownURL).0
            }
            if data == nil || !imageData(data!) {
                data = try? await api.poster(id: id)
            }
            guard let data, imageData(data) else { return nil }
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    private func imageFile(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return imageData(data)
    }

    private func imageData(_ data: Data) -> Bool {
        guard data.count > 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else { return false }
        return true
    }

    /// Saved playlist, if one is already on disk. Never hits the network.
    func cachedPlaylist(_ movie: Movie) -> URL? {
        guard let file = try? directory(id: movie.id).appendingPathComponent("index.m3u8"),
              let text = try? String(contentsOf: file, encoding: .utf8),
              text.contains("#EXTM3U"),
              text.contains("https://"),
              !text.contains("file://")
        else { return nil }
        return file
    }

    /// Download the playlist and keep it. Play does not wait on this.
    func storePlaylist(api: WatchAPI, movie: Movie) async {
        if cachedPlaylist(movie) != nil { return }
        guard let remote = URL(string: "\(api.base)/v1/items/\(movie.id)/index.m3u8?key=\(api.key)"),
              let file = try? directory(id: movie.id).appendingPathComponent("index.m3u8")
        else { return }
        var request = URLRequest(url: remote)
        request.timeoutInterval = 20
        request.setValue("Bearer \(api.key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8),
              text.contains("#EXTM3U"),
              text.contains("https://")
        else { return }
        try? data.write(to: file, options: .atomic)
        // The playlist is small. The first video piece is what play waits on, so fetch it now too.
        guard let seg = URL(string: "\(api.base)/v1/items/\(movie.id)/seg/0.ts?key=\(api.key)") else { return }
        var warm = URLRequest(url: seg)
        warm.timeoutInterval = 30
        warm.setValue("Bearer \(api.key)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: warm)
    }

    func cachePlaylists(api: WatchAPI, movies: [Movie]) async {
        await withTaskGroup(of: Void.self) { group in
            for movie in movies {
                group.addTask { await self.storePlaylist(api: api, movie: movie) }
            }
        }
    }

    func subtitleFile(api: WatchAPI, id: String, lang: String) async throws -> String {
        let file = try directory(id: id).appendingPathComponent("sub-\(lang).vtt")
        if let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty { return text }
        let text = try await api.subtitle(id: id, lang: lang)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return text
    }

    private func fill(api: WatchAPI, movie: Movie, onProgress: (Double) -> Void) async throws {
        let size = movie.byteSize
        var cursor: Int64 = 0
        while cursor < size {
            try Task.checkCancellation()
            while playerWaiters > 0 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            let index = try loadIndex(id: movie.id, byteSize: size)
            let hole = missing(index.spans, from: cursor, to: size).first
            guard let hole else { break }
            let length = Int(min(Int64(4 << 20), hole.end - hole.start))
            _ = try await load(api: api, movie: movie, offset: hole.start, length: length)
            cursor = hole.start + Int64(length)
            onProgress(fraction(id: movie.id, byteSize: size))
        }
        onProgress(fraction(id: movie.id, byteSize: size))
    }

    private func load(api: WatchAPI, movie: Movie, offset: Int64, length: Int) async throws -> Data {
        let end = min(movie.byteSize, offset + Int64(length))
        var index = try loadIndex(id: movie.id, byteSize: movie.byteSize)
        for hole in missing(index.spans, from: offset, to: end) {
            let data: Data
            do {
                data = try await api.bytes(id: movie.id, offset: hole.start, length: Int(hole.end - hole.start))
            } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
                throw WatchError.offline
            }
            if data.isEmpty { throw WatchError.offline }
            try write(movie: movie, data: data, at: hole.start)
            index.spans = merged(index.spans, Span(start: hole.start, end: hole.start + Int64(data.count)))
            try save(index, id: movie.id)
        }
        return try read(movie: movie, offset: offset, length: Int(end - offset))
    }

    private func write(movie: Movie, data: Data, at offset: Int64) throws {
        let url = try movieFile(movie)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func read(movie: Movie, offset: Int64, length: Int) throws -> Data {
        let url = try movieFile(movie)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
    }

    private func movieFile(_ movie: Movie) throws -> URL {
        let url = try directory(id: movie.id).appendingPathComponent("movie.\(movie.ext)")
        let index = try loadIndex(id: movie.id, byteSize: movie.byteSize)
        if !FileManager.default.fileExists(atPath: url.path) || index.byteSize != movie.byteSize {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(movie.byteSize))
            try handle.close()
            try save(LocalIndex(byteSize: movie.byteSize, spans: []), id: movie.id)
        }
        return url
    }

    private func directory(id: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Watch/media/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func indexURL(id: String) throws -> URL {
        try directory(id: id).appendingPathComponent("spans.json")
    }

    private func loadIndex(id: String, byteSize: Int64) throws -> LocalIndex {
        let url = try indexURL(id: id)
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(LocalIndex.self, from: data),
              index.byteSize == byteSize
        else { return LocalIndex(byteSize: byteSize, spans: []) }
        return index
    }

    private func save(_ index: LocalIndex, id: String) throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: try indexURL(id: id), options: .atomic)
    }
}

// MARK: - HLS Download Session

final class HLSDownloadSession: NSObject, AVAssetDownloadDelegate {
    let movieID: String
    let mediaStore: MediaStore
    var task: AVAssetDownloadTask?
    var continuation: CheckedContinuation<URL, Error>?
    var progress: Double = 0

    init(movieID: String, mediaStore: MediaStore) {
        self.movieID = movieID
        self.mediaStore = mediaStore
        super.init()
    }

    func completion() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        task?.cancel()
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    // MARK: - AVAssetDownloadDelegate

    nonisolated func assetDownloadTask(_: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        let total = timeRangeExpectedToLoad.duration.seconds
        Task { @MainActor in
            self.progress = total > 0 ? min(1, loaded / total) : 0
        }
    }

    nonisolated func assetDownloadTask(_: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        Task { @MainActor in
            // Move the downloaded .movpkg to our media directory
            do {
                let dest = try await self.mediaStore.hlsDirectory(id: self.movieID).appendingPathComponent("hls.movpkg")
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: location, to: dest)
                
                // Auto-export HLS .movpkg → movie.mp4 for permanent AirPlay offline support
                Task.detached {
                    do {
                        let mp4 = try await self.mediaStore.exportUnifiedVideo(movpkg: dest, name: "movie")
                        // Rename to fixed movie.mp4 in the same directory
                        let finalMP4 = dest.deletingLastPathComponent().appendingPathComponent("movie.mp4")
                        if FileManager.default.fileExists(atPath: finalMP4.path) {
                            try FileManager.default.removeItem(at: finalMP4)
                        }
                        try FileManager.default.moveItem(at: mp4, to: finalMP4)
                        print("✅ Auto-exported HLS to MP4 for offline AirPlay: \(finalMP4.path)")
                    } catch {
                        print("⚠️ Auto-export failed: \(error)")
                    }
                }
                
                self.continuation?.resume(returning: dest)
            } catch {
                self.continuation?.resume(throwing: error)
            }
            self.continuation = nil
            self.task = nil
        }
    }

    nonisolated func assetDownloadTask(_: AVAssetDownloadTask, didCompleteWith error: Error?) {
        if let error {
            Task { @MainActor in
                self.continuation?.resume(throwing: error)
                self.continuation = nil
                self.task = nil
            }
        }
    }
}

struct Span: Codable, Equatable, Sendable {
    var start: Int64
    var end: Int64
}

struct LocalIndex: Codable, Sendable {
    var byteSize: Int64
    var spans: [Span]
}

func merged(_ spans: [Span], _ add: Span) -> [Span] {
    guard add.end > add.start else { return spans }
    let all = (spans + [add]).sorted { $0.start < $1.start }
    var out: [Span] = []
    for span in all {
        if let last = out.last, span.start <= last.end {
            out[out.count - 1].end = max(last.end, span.end)
        } else {
            out.append(span)
        }
    }
    return out
}

func missing(_ spans: [Span], from start: Int64, to end: Int64) -> [Span] {
    var cursor = start
    var holes: [Span] = []
    for span in spans.sorted(by: { $0.start < $1.start }) where span.end > cursor && span.start < end {
        let a = max(span.start, start)
        if a > cursor { holes.append(Span(start: cursor, end: min(a, end))) }
        cursor = max(cursor, min(span.end, end))
        if cursor >= end { break }
    }
    if cursor < end { holes.append(Span(start: cursor, end: end)) }
    return holes
}
