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
    private var token: Any?
    private var failObserver: (any NSObjectProtocol)?
    private var watchTask: Task<Void, Never>?
    /// Fired once when playback fails (bad key, offline, bad media) so the
    /// UI can say so instead of sitting on a black frame.
    var onError: (String) -> Void = { _ in }

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
            // Native HTTPS streaming with range requests. Key travels in the
            // URL (headers can be dropped on range follow-ups); Bearer kept too.
            let mediaURL = "\(api.base)/v1/items/\(movie.id)/media?key=\(api.key)"
            guard let url = URL(string: mediaURL) else {
                fail("Couldn't play this movie.")
                return
            }
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(api.key)"]])
        }
        let item = AVPlayerItem(asset: asset)
        watch(item: item)
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
        watchTask?.cancel()
        watchTask = nil
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
            self.failObserver = nil
        }
        if let player, let token {
            player.removeTimeObserver(token)
        }
        token = nil
        player?.pause()
        player = nil
    }

    /// Record the failure, tear down, and tell the UI once. Called from the
    /// item watchers below — never silently black-screens.
    func fail(_ message: String) {
        guard errorText == nil else { return }
        errorText = message
        let cb = onError
        stop()
        cb(message)
    }

    /// Watch the item and fail fast with the real error (401, offline, bad
    /// media) instead of leaving a black frame that never resolves.
    private func watch(item: AVPlayerItem) {
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] note in
            let msg = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?.localizedDescription
                ?? "Playback stopped."
            Task { @MainActor in self?.fail(msg) }
        }
        watchTask?.cancel()
        watchTask = Task {
            for _ in 0..<150 {
                if Task.isCancelled { return }
                if item.status == .readyToPlay { return }
                if item.status == .failed {
                    let msg = (item.error as NSError?)?.localizedDescription ?? "Couldn't play this movie."
                    await MainActor.run { self.fail(msg) }
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if !Task.isCancelled, item.status != .readyToPlay {
                await MainActor.run { self.fail("The movie never started. Check the connection and try again.") }
            }
        }
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
