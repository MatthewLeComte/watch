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
    var trailerFileUrl: String?
    var status: String
    var matchSource: String
    var matchP: Double?
    var matchNote: String
    var subtitles: [SubtitleTrack]
    var createdAt: String
    var updatedAt: String

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
