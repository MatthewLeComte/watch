import Foundation

struct SubtitleTrack: Codable, Hashable, Identifiable, Sendable {
    var lang: String
    var label: String
    var source: String
    var releaseName: String?
    var hearingImpaired: Bool
    var id: String { lang }
}

struct Movie: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var filename: String
    var byteSize: Int64
    var contentType: String
    var ext: String
    var title: String
    var originalTitle: String?
    var year: Int?
    var overview: String
    var runtimeMin: Int?
    var genres: [String]
    var imdbId: String?
    /// TMDB movie id. Same number a search result uses in `meta:{id}`.
    var tmdbId: Int?
    var osHash: String?
    var streamId: String?
    var hlsUrl: String?
    var thumbnailUrl: String?
    var downloadUrl: String?
    var readyToStream: Bool?
    var posterUrl: String?
    var backdropUrl: String?
    var trailerSite: String?
    var trailerKey: String?
    var trailerUrl: String?
    /// Catalog JSON uses `trailer` for the YouTube watch URL.
    var trailer: String?

    var youTubeID: String? {
        if let trailerKey, !trailerKey.isEmpty { return trailerKey }
        let raw = trailerUrl ?? trailer
        guard let raw, let parts = URLComponents(string: raw) else { return nil }
        if let v = parts.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty { return v }
        let last = parts.path.split(separator: "/").last.map(String.init)
        if parts.host?.contains("youtu.be") == true { return last }
        return nil
    }
    var trailerFileUrl: String?
    /// Catalog JSON uses `trailerFile` for the R2 MP4.
    var trailerFile: String?

    var trailerFilePlayURL: URL? {
        let raw = trailerFile ?? trailerFileUrl
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
    /// English captions for the trailer file, when YouTube had them.
    var trailerCaptions: String?
    var status: String
    var matchSource: String
    var matchP: Double?
    var matchNote: String
    var subtitles: [SubtitleTrack]
    var createdAt: String
    var updatedAt: String
    /// Set while the title is a rental: when it deletes itself. Nil means permanent.
    var expiresAt: String?

    var isRental: Bool { expiresAt != nil }

    /// Whole days until a rental expires, never negative.
    var rentalDaysLeft: Int? {
        guard let expiresAt, let date = ISO8601DateFormatter.withFraction.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt) else { return nil }
        return max(0, Int(ceil(date.timeIntervalSinceNow / 86_400)))
    }

    /// Never show the container name. "Eddie The Eagle.mp4" is not a title.
    var displayTitle: String {
        let stripped = title.replacingOccurrences(of: #"\.(mp4|m4v|mov)$"#, with: "", options: .regularExpression)
        return stripped.isEmpty ? title : stripped
    }

    var yearText: String { year.map(String.init) ?? "" }

    var runtimeText: String? {
        guard let runtimeMin, runtimeMin > 0 else { return nil }
        return "\(runtimeMin / 60)h \(runtimeMin % 60)m"
    }

    var preferredSubtitle: SubtitleTrack? {
        subtitles.first { $0.lang == "en" } ?? subtitles.first
    }
}

private extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

struct ItemList: Codable, Sendable {
    var items: [Movie]
}

struct PendingImport: Identifiable, Hashable, Sendable {
    var id: UUID
    var filename: String
    var stage: String
    var progress: Double
    var detail: String
}

enum WatchBuiltIn {
    static let server = "https://watch.cornerstonecoatings.com"
    static let key = "a68596aee3429a00eea168ccc408af7f00235119bfce7e07152f92013cecc164"
}

enum WatchError: LocalizedError {
    case unauthorized
    case server(String)
    case offline
    case notPlayable

    var errorDescription: String? {
        switch self {
        case .unauthorized: "The library key was refused."
        case .server(let message): message
        case .offline: "This part is not on the device, and the library is unreachable."
        case .notPlayable: "This file will not play on this device. Use MP4, M4V, or MOV."
        }
    }
}
