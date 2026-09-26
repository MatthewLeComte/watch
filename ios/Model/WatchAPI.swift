import Foundation

struct WatchAPI: Sendable {
    var base: URL
    var key: String
    private let session: URLSession

    init(base: URL, key: String, session: URLSession = .shared) {
        self.base = base
        self.key = key
        self.session = session
    }

    func items() async throws -> [Movie] {
        let data = try await send(path: "v1/items", method: "GET")
        return try JSONDecoder().decode(ItemList.self, from: data).items
    }

    // MARK: - Sources (generic)

    /// List available sources.
    func listSources() async throws -> [SourceInfo] {
        let data = try await send(path: "v1/sources", method: "GET")
        return try JSONDecoder().decode([SourceInfo].self, from: data)
    }

    /// Search a source by query string.
    func sourceSearch(query: String, source: String = "67movies") async throws -> [SourceSearchResult] {
        let data = try await send(path: "v1/sources/search", method: "GET", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "source", value: source)
        ])
        return try JSONDecoder().decode([SourceSearchResult].self, from: data)
    }

    /// Search a source by IMDb ID.
    func sourceSearchByImdb(imdbId: String, source: String = "67movies") async throws -> [SourceSearchResult] {
        let data = try await send(path: "v1/sources/search", method: "GET", query: [
            URLQueryItem(name: "imdb", value: imdbId),
            URLQueryItem(name: "source", value: source)
        ])
        return try JSONDecoder().decode([SourceSearchResult].self, from: data)
    }

    /// Resolve a source item to stream info (master playlist, qualities, subtitles).
    func sourceResolve(source: String, id: String) async throws -> SourceStreamInfo {
        let data = try await send(path: "v1/sources/\(source)/resolve/\(id)", method: "GET")
        return try JSONDecoder().decode(SourceStreamInfo.self, from: data)
    }

    /// Download the selected quality to the library.
    func sourceDownload(source: String, stream: SourceStreamInfo, qualityHeight: Int, subtitleLang: String?) async throws -> Movie {
        var obj: [String: Any] = [
            "stream": stream.toDictionary(),
            "quality": ["height": qualityHeight]
        ]
        if let subtitleLang { obj["subtitleLang"] = subtitleLang }
        let body = try JSONSerialization.data(withJSONObject: obj)
        let data = try await send(path: "v1/sources/\(source)/download", method: "POST", body: body, contentType: "application/json")
        return try JSONDecoder().decode(Movie.self, from: data)
    }

    // MARK: - Existing Methods

    func create(filename: String, byteSize: Int64) async throws -> (id: String, partSize: Int) {
        let body = try JSONSerialization.data(withJSONObject: [
            "filename": filename,
            "byteSize": byteSize,
        ])
        let data = try await send(path: "v1/items", method: "POST", body: body, contentType: "application/json")
        let obj = try JSONDecoder().decode(CreateBody.self, from: data)
        return (obj.id, obj.partSize)
    }

    func uploadPart(id: String, part: Int, file: URL) async throws {
        guard let components = URLComponents(url: base.appendingPathComponent("v1/items/\(id)/parts/\(part)"), resolvingAgainstBaseURL: false),
              let url = components.url
        else { throw WatchError.server("Bad URL") }
        _ = components
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Watch/1", forHTTPHeaderField: "User-Agent")
        let bytes = (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        request.setValue(String(bytes), forHTTPHeaderField: "Content-Length")
        let (data, response) = try await session.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse else { throw WatchError.server("No response") }
        if http.statusCode == 401 { throw WatchError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Request failed (\(http.statusCode))"
            throw WatchError.server(message)
        }
    }

    func complete(id: String) async throws -> Movie {
        let data = try await send(path: "v1/items/\(id)/complete", method: "POST")
        return try JSONDecoder().decode(Movie.self, from: data)
    }

    func one(id: String) async throws -> Movie {
        let data = try await send(path: "v1/items/\(id)", method: "GET")
        return try JSONDecoder().decode(Movie.self, from: data)
    }

    func playback(id: String) async throws -> Movie {
        let data = try await send(path: "v1/items/\(id)/playback", method: "GET")
        return try JSONDecoder().decode(Movie.self, from: data)
    }

    func patch(id: String, title: String, year: Int?, overview: String, imdbId: String?) async throws -> Movie {
        var obj: [String: Any] = ["title": title, "overview": overview]
        if let year { obj["year"] = year } else { obj["year"] = NSNull() }
        let imdb = imdbId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !imdb.isEmpty { obj["imdbId"] = imdb }
        let body = try JSONSerialization.data(withJSONObject: obj)
        let data = try await send(path: "v1/items/\(id)", method: "PATCH", body: body, contentType: "application/json")
        return try JSONDecoder().decode(Movie.self, from: data)
    }

    func rematch(id: String) async throws -> Movie {
        let data = try await send(path: "v1/items/\(id)/rematch", method: "POST")
        return try JSONDecoder().decode(Movie.self, from: data)
    }

    func delete(id: String) async throws {
        _ = try await send(path: "v1/items/\(id)", method: "DELETE")
    }

    func bytes(id: String, offset: Int64, length: Int) async throws -> Data {
        let end = offset + Int64(length) - 1
        return try await send(path: "v1/items/\(id)/media", method: "GET", range: "bytes=\(offset)-\(end)")
    }

    func poster(id: String) async throws -> Data {
        try await send(path: "v1/items/\(id)/poster", method: "GET")
    }

    func putPoster(id: String, data: Data, contentType: String) async throws {
        _ = try await send(path: "v1/items/\(id)/poster", method: "PUT", body: data, contentType: contentType)
    }

    func subtitle(id: String, lang: String) async throws -> String {
        let data = try await send(path: "v1/items/\(id)/subtitles/\(lang)", method: "GET")
        guard let text = String(data: data, encoding: .utf8) else { throw WatchError.server("Bad subtitle") }
        return text
    }

    func putSubtitle(id: String, lang: String, text: String, label: String) async throws -> Movie {
        let data = try await send(
            path: "v1/items/\(id)/subtitles/\(lang)",
            method: "PUT",
            body: Data(text.utf8),
            contentType: "text/plain",
            query: [URLQueryItem(name: "label", value: label)]
        )
        return try JSONDecoder().decode(Movie.self, from: data)
    }

    private func send(
        path: String,
        method: String,
        body: Data? = nil,
        contentType: String? = nil,
        range: String? = nil,
        query: [URLQueryItem] = []
    ) async throws -> Data {
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw WatchError.server("Bad URL")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw WatchError.server("Bad URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("Watch/1", forHTTPHeaderField: "User-Agent")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WatchError.server("No response") }
        if http.statusCode == 401 { throw WatchError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Request failed (\(http.statusCode))"
            throw WatchError.server(message)
        }
        return data
    }
}

// MARK: - Source Types

struct SourceInfo: Codable, Hashable, Sendable, Identifiable {
    var id: String { key }
    var key: String
    var name: String
}

// MARK: - 67movies Types

struct SourceSearchResult: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var year: Int?
    var imdbId: String?
    var poster: String?
    var type: String

    var displayTitle: String {
        if let year { return "\(title) (\(year))" }
        return title
    }
}

struct SourceQuality: Codable, Hashable, Sendable, Identifiable {
    var id: String { "\(height)" }
    var height: Int
    var bandwidth: Int
    var codecs: String
    var uri: String

    var label: String {
        "\(height)p • \(bandwidth / 1_000_000) Mbps"
    }
}

struct SourceSubtitle: Codable, Hashable, Sendable, Identifiable {
    var id: String { lang }
    var lang: String
    var label: String
    var uri: String
    var forced: Bool
}

struct SourceStreamInfo: Codable, Hashable, Sendable {
    var id: String
    var title: String
    var year: Int?
    var imdbId: String?
    var poster: String?
    var hlsUrl: String
    var qualities: [SourceQuality]
    var subtitles: [SourceSubtitle]

    func toDictionary() -> [String: Any] {
        [
            "id": id,
            "title": title,
            "year": year ?? NSNull(),
            "imdbId": imdbId ?? NSNull(),
            "poster": poster ?? NSNull(),
            "hlsUrl": hlsUrl,
            "qualities": qualities.map { $0.toDictionary() },
            "subtitles": subtitles.map { $0.toDictionary() }
        ]
    }
}

extension SourceQuality {
    func toDictionary() -> [String: Any] {
        ["height": height, "bandwidth": bandwidth, "codecs": codecs, "uri": uri]
    }
}

extension SourceSubtitle {
    func toDictionary() -> [String: Any] {
        ["lang": lang, "label": label, "uri": uri, "forced": forced]
    }
}

private struct CreateBody: Codable { var id: String; var partSize: Int }
private struct ErrorBody: Codable { var error: String }
