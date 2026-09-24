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

private struct CreateBody: Codable { var id: String; var partSize: Int }
private struct ErrorBody: Codable { var error: String }
