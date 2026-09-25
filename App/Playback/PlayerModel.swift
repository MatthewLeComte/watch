@preconcurrency import AVFoundation
import AVKit
import Foundation
import Observation

@MainActor
@Observable
final class PlayerModel {
    let movie: Movie
    private let api: WatchAPI
    private let media: MediaStore
    private let onPosition: (Double) -> Void

    private(set) var player: AVPlayer?
    var errorText: String?
    var subtitlesOn = true
    private var token: Any?

    init(movie: Movie, api: WatchAPI, media: MediaStore, onPosition: @escaping (Double) -> Void) {
        self.movie = movie
        self.api = api
        self.media = media
        self.onPosition = onPosition
    }

    func start(position: Double) async {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let local = await media.playableFile(movie)
        let asset: AVURLAsset
        if let local {
            asset = AVURLAsset(url: local)
        } else {
            // Native HTTPS streaming with range requests.
            let mediaURL = "\(api.base)/v1/items/\(movie.id)/media"
            guard let url = URL(string: mediaURL) else { return }
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(api.key)"]])
        }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false

        let seconds = max(0, position)
        if seconds > 1 {
            Task { await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
        }
        token = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }
        self.player = player
        // Enable legible tracks automatically when available (Apple docs:
        // load the legible group, then selectMediaOptionAutomatically).
        Task { await self.setLegibleAutomatic(on: true) }
        player.play()
    }

    func stop() {
        if let player, let token {
            player.removeTimeObserver(token)
        }
        token = nil
        player?.pause()
        player = nil
    }

    /// One-tap subtitles toggle, Apple docs only: load the legible media
    /// selection group, then selectMediaOptionAutomatically (on) or
    /// select(nil) (off). No name guessing, no custom renderer.
    func toggleSubtitles() {
        subtitlesOn.toggle()
        let on = subtitlesOn
        Task { await self.setLegibleAutomatic(on: on) }
    }

    private func setLegibleAutomatic(on: Bool) async {
        guard let item = player?.currentItem else { return }
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
        if on {
            item.selectMediaOptionAutomatically(in: group)
        } else {
            item.select(nil, in: group)
        }
    }

    private func tick(_ seconds: Double) {
        onPosition(seconds)
    }
}
