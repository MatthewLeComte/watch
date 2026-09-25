import SwiftUI
import ImageIO
import CoreGraphics
import Foundation

enum Cinema {
    static let bg = Color(red: 0.08, green: 0.08, blue: 0.08)
    static let ink = Color.white
    static let mute = Color(white: 0.72)
    static let red = Color(red: 0.898, green: 0.035, blue: 0.078)
    static let chip = Color(white: 0.42)
}

/// In-memory poster cache. MediaStore keeps the poster files on disk across
/// launches; this keeps decoded thumbnails across cell reuse so fast
/// scrolling doesn't refetch + redecode every poster on every pass.
/// Without it AsyncImage re-resolves each cell and the shelves stutter.
enum PosterCache {
    /// NSCache is thread-safe by Apple contract; the strict-concurrency
    /// checker can't see that, so this is unchecked.
    nonisolated(unsafe) private static let memory: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 300
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()

    static func image(for url: URL) async -> Image? {
        let key = url.absoluteString as NSString
        if let hit = memory.object(forKey: key) {
            return Image(decorative: hit, scale: 2)
        }
        guard let thumb = await thumbnail(for: url) else { return nil }
        memory.setObject(thumb, forKey: key, cost: thumb.width * thumb.height * 4)
        return Image(decorative: thumb, scale: 2)
    }

    private static func thumbnail(for url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            let opts: CFDictionary = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                // 150pt cards @2x. Small decode = no scroll lag.
                kCGImageSourceThumbnailMaxPixelSize: 512,
            ] as CFDictionary
            let source: CGImageSource?
            if url.isFileURL {
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                source = CGImageSourceCreateWithURL(url as CFURL, nil)
            } else {
                var request = URLRequest(url: url)
                request.cachePolicy = .returnCacheDataElseLoad
                guard let (data, _) = try? await URLSession.shared.data(for: request),
                      !data.isEmpty
                else { return nil }
                source = CGImageSourceCreateWithData(data as CFData, nil)
            }
            guard let source else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, opts)
        }.value
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
            } else {
                posterFallback(title)
            }
        }
        .task(id: url?.absoluteString) {
            guard let url else { localImage = nil; return }
            guard !Task.isCancelled else { return }
            if let hit = await PosterCache.image(for: url), !Task.isCancelled {
                localImage = hit
            }
        }
    }
}

private func posterFallback(_ title: String) -> some View {
    ZStack {
        LinearGradient(colors: [Color(white: 0.16), .black], startPoint: .top, endPoint: .bottom)
        Text(title)
            .font(.system(size: 28, weight: .heavy))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(16)
    }
}

func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds)
    return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}
