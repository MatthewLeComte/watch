import SwiftUI
import ImageIO
import CoreGraphics

enum Cinema {
    static let bg = Color(red: 0.08, green: 0.08, blue: 0.08)
    static let ink = Color.white
    static let mute = Color(white: 0.72)
    static let red = Color(red: 0.898, green: 0.035, blue: 0.078)
    static let chip = Color(white: 0.42)
    static let column: CGFloat = 680
    static let playColumn: CGFloat = 420
}

struct SaveRing: View {
    var progress: Double?
    var body: some View {
        if let progress {
            Capsule(style: .continuous)
                .trim(from: 0, to: max(0.02, progress))
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(180))
                .padding(1)
                .allowsHitTesting(false)
                .animation(.linear(duration: 0.25), value: progress)
        }
    }
}

struct PosterImage: View {
    var url: URL?
    var title: String
    @State private var localImage: Image?

    var body: some View {
        Group {
            if let localImage {
                localImage.resizable().scaledToFill()
            } else if let url, url.scheme == "https" || url.scheme == "http" {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        PosterPlaceholder()
                    }
                }
            } else if let url, url.isFileURL {
                PosterPlaceholder()
                    .task { localImage = await loadLocalImage(url) }
            } else {
                PosterPlaceholder()
            }
        }
        .accessibilityLabel(title)
    }
}

/// Grey sweep while a poster is still loading.
private struct PosterPlaceholder: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            LinearGradient(
                stops: [
                    .init(color: Color(white: 0.16), location: 0),
                    .init(color: Color(white: 0.28), location: phase),
                    .init(color: Color(white: 0.16), location: 1)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private func loadLocalImage(_ url: URL) async -> Image? {
    await Task.detached(priority: .userInitiated) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return Image(decorative: image, scale: 1)
    }.value
}

func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds)
    return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}

/// Where a show tile leads: its seasons, then its episodes.
struct SeriesRoute: Hashable { var name: String }

struct SeriesView: View {
    @Environment(LibraryModel.self) private var library
    let name: String

    private var episodes: [Movie] { library.movies.filter { $0.series == name } }
    private var seasons: [Int] { Array(Set(episodes.map { $0.season ?? 1 })).sorted() }

    var body: some View {
        List {
            ForEach(seasons, id: \.self) { season in
                Section {
                    ForEach(episodes.filter { ($0.season ?? 1) == season }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }) { episode in
                        NavigationLink(value: episode) { EpisodeRow(show: name, episode: episode) }
                            .listRowBackground(Color.black)
                    }
                } header: {
                    Text("Season \(season)")
                        .font(.headline.smallCaps())
                        .foregroundStyle(.white)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct EpisodeRow: View {
    let show: String
    let episode: Movie

    /// "Rick and Morty S1 E1: Pilot" reads as "Pilot" under its own show and season.
    private var episodeName: String {
        episode.title.range(of: ": ").map { String(episode.title[$0.upperBound...]) } ?? episode.displayTitle
    }

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: URL(string: episode.posterUrl ?? episode.thumbnailUrl ?? ""), title: episode.displayTitle)
                .frame(width: 64, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text("E\(episode.episode ?? 0) · \(episodeName)")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text([episode.runtimeText ?? "", episode.rentalDaysLeft.map { $0 == 0 ? "Leaves today" : "Leaves in \($0)d" } ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(.vertical, 4)
    }
}
