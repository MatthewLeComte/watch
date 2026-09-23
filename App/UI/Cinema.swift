import SwiftUI
import ImageIO
import CoreGraphics

enum Cinema {
    static let bg = Color(red: 0.08, green: 0.08, blue: 0.08)
    static let ink = Color.white
    static let mute = Color(white: 0.72)
    static let red = Color(red: 0.898, green: 0.035, blue: 0.078)
    static let chip = Color(white: 0.42)
}

struct PosterImage: View {
    var url: URL?
    var title: String

    var body: some View {
        Group {
            if let url, url.isFileURL, let image = platformImage(url) {
                image.resizable().scaledToFill()
            } else if let url, url.scheme == "https" || url.scheme == "http" {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        posterFallback(title)
                    }
                }
            } else {
                posterFallback(title)
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

private func platformImage(_ url: URL) -> Image? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    return Image(decorative: image, scale: 1)
}

func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds)
    return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}
