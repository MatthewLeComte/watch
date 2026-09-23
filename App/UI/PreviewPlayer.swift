import AVFoundation
import SwiftUI
import AVKit

/// Muted picture for the pinned trailer. The poster stays up until a frame is actually in this view.
struct PreviewPlayer: View {
    var movie: Movie
    var poster: URL?
    var active: Bool
    var muted: Bool
    var onAspect: (CGFloat) -> Void = { _ in }
    @Environment(LibraryModel.self) private var library
    @State private var player: AVPlayer?
    @State private var loader: ResourceLoader?
    @State private var frameReady = false
    @State private var tick: Any?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
                    .onAppear {
                        // Frame ready detection via time observer
                    }
            }
            PosterImage(url: poster, title: movie.displayTitle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(frameReady ? 0 : 1)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: "\(movie.id)-\(active)") {
            if active { await play() } else { stop() }
        }
        .onChange(of: muted) { _, muted in
            player?.isMuted = muted
        }
        .onDisappear { stop() }
    }

    private func play() async {
        frameReady = false
        player?.pause()
        let local = await library.media.playableFile(movie)
        let asset: AVURLAsset
        if let local {
            loader = nil
            asset = AVURLAsset(url: local)
        } else if let hls = movie.hlsUrl.flatMap({ URL(string: $0) }) {
            loader = nil
            asset = AVURLAsset(url: hls)
        } else {
            let gate = ResourceLoader(movie: movie, api: library.api, media: library.media)
            loader = gate
            guard let custom = URL(string: "watchmedia://movie/\(movie.id).\(movie.ext)") else { return }
            asset = AVURLAsset(url: custom)
            asset.resourceLoader.setDelegate(gate, queue: DispatchQueue(label: "watch.preview"))
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            let width = abs(rect.width)
            let height = abs(rect.height)
            if height > 1 { onAspect(width / height) }
        }
        let item = AVPlayerItem(asset: asset)
        let next = AVPlayer(playerItem: item)
        next.isMuted = muted
        next.allowsExternalPlayback = false
        let clock = next.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
            if time.seconds > 0.05 {
                Task { @MainActor in frameReady = true }
            }
        }
        tick = clock
        player = next
    }

    private func stop() {
        if let player, let tick { player.removeTimeObserver(tick) }
        tick = nil
        frameReady = false
        player?.pause()
        player = nil
        loader = nil
    }
}