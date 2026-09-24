import Foundation

/// Data category — exactly 10 functions. Talks to the worker / D1 via `WatchAPI`
/// and to the local cache via `MediaStore`. The shape of the data is driven by
/// `watch/migrations/0001_init.sql`, `0002_trailer.sql`, `0003_stream.sql`.
enum DataLayer {

    /// 1. Introspect the SQL structure: returns table → columns.
    static func schema() -> [String: [String]] {
        [
            "movie": [
                "id", "filename", "byte_size", "content_type", "ext",
                "title", "original_title", "year", "overview", "runtime_min",
                "genres_json", "imdb_id", "os_hash", "status",
                "match_source", "match_p", "match_note",
                "trailer_site", "trailer_key", "trailer_url",
                "stream_uid", "hls_url", "thumbnail_url", "download_url",
                "ready_to_stream", "pull_token",
                "created_at", "updated_at",
            ],
            "subtitle": ["movie_id", "lang", "label", "r2_key", "hearing_impaired", "source", "release_name"],
            "upload": ["movie_id", "upload_id", "parts_json"],
        ]
    }

    /// 2. List rows of a table.
    static func list(table: String, api: WatchAPI) async throws -> [Movie] {
        _ = table
        return try await api.items()
    }

    /// 3. One row by id.
    static func one(table: String, id: String, api: WatchAPI) async throws -> Movie {
        _ = table
        return try await api.one(id: id)
    }

    /// 4. Create a row.
    static func create(table: String, fields: [String: String], api: WatchAPI) async throws -> (id: String, partSize: Int) {
        _ = table
        let filename = fields["filename"] ?? ""
        let byteSize = Int64(fields["byte_size"] ?? "0") ?? 0
        return try await api.create(filename: filename, byteSize: byteSize)
    }

    /// 5. Update a row.
    static func update(table: String, id: String, fields: [String: String], api: WatchAPI) async throws -> Movie {
        _ = table
        let title = fields["title"]
        let year = fields["year"].flatMap { Int($0) }
        let overview = fields["overview"] ?? ""
        let imdb = fields["imdb_id"]
        return try await api.patch(id: id, title: title ?? "", year: year, overview: overview, imdbId: imdb)
    }

    /// 6. Delete a row.
    static func delete(table: String, id: String, api: WatchAPI) async throws {
        _ = table
        try await api.delete(id: id)
    }

    /// 7. Upload a file part.
    static func upload(table: String, id: String, part: Int, file: URL, api: WatchAPI) async throws {
        _ = table
        try await api.uploadPart(id: id, part: part, file: file)
    }

    /// 8. Resolve media URL for streaming.
    static func media(table: String, id: String, api: WatchAPI) async throws -> Movie {
        _ = table
        return try await api.playback(id: id)
    }

    /// 9. Fetch a subtitle.
    static func subtitle(table: String, id: String, lang: String, api: WatchAPI, media: MediaStore) async throws -> String {
        _ = table
        return try await media.subtitleFile(api: api, id: id, lang: lang)
    }

    /// 10. Fetch a poster.
    static func poster(table: String, id: String, api: WatchAPI, media: MediaStore) async throws -> URL? {
        _ = table
        return await media.posterFile(api: api, id: id)
    }
}
