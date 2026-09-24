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
    private var loader: ResourceLoader?
    var currentTime: Double = 0
    var duration: Double = 0
    var playing = false
    var chrome = true
    var cueText: String?
    var errorText: String?
    var subtitlesOn = true
    /// Set by the player view once its AVPlayerLayer exists. Powers the
    /// chrome PiP button; the view also enables automatic PiP from inline.
    var pipController: AVPictureInPictureController?
    var pipPossible: Bool { pipController != nil }
    private var cues: [Cue] = []
    private var token: Any?
    private var hideTask: Task<Void, Never>?

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
        let hls = movie.hlsUrl.flatMap { URL(string: $0) }
        let asset: AVURLAsset
        if let local {
            asset = AVURLAsset(url: local)
        } else if let hls {
            asset = AVURLAsset(url: hls)
        } else {
            let loader = ResourceLoader(movie: movie, api: api, media: media)
            self.loader = loader
            guard let custom = URL(string: "watchmedia://movie/\(movie.id).\(movie.ext)") else { return }
            asset = AVURLAsset(url: custom)
            asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "watch.media"))
        }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        if let lang = movie.preferredSubtitle?.lang {
            if let text = try? await media.subtitleFile(api: api, id: movie.id, lang: lang) {
                cues = parseVTT(text)
            }
        }
        let seconds = max(0, position)
        if seconds > 1 {
            // Fire the seek in the background instead of awaiting it.
            // Awaiting the seek here forces AVPlayer to buffer every
            // byte from the resource loader up to the resume point
            // before `play()` is called — a 1 MB/round-trip loader plus
            // a 5+ minute resume point can pin a black screen for ~20s
            // with no progress shown. Let playback start on whatever
            // the player has already buffered; the seek lands and the
            // player jumps to the resume point once the data arrives.
            Task { await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
        }
        token = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }
        self.player = player
        player.play()
        playing = true
        scheduleHide()
    }

    func stop() {
        if let player, let token {
            player.removeTimeObserver(token)
        }
        token = nil
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        pipController = nil
        player?.pause()
        player = nil
        loader = nil
        hideTask?.cancel()
    }

    func togglePlay() {
        guard let player else { return }
        if playing {
            player.pause()
            playing = false
        } else {
            player.play()
            playing = true
            scheduleHide()
        }
    }

    func toggleChrome() {
        chrome.toggle()
        if chrome { scheduleHide() }
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
    }

    func togglePip() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            pip.startPictureInPicture()
        }
    }

    private func tick(_ seconds: Double) {
        currentTime = seconds
        if let item = player?.currentItem {
            let d = item.duration.seconds
            if d.isFinite { duration = d }
        }
        cueText = subtitlesOn ? cue(at: seconds, in: cues) : nil
        onPosition(seconds)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, playing { chrome = false }
        }
    }
}

final class ResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let movie: Movie
    let api: WatchAPI
    let media: MediaStore

    init(movie: Movie, api: WatchAPI, media: MediaStore) {
        self.movie = movie
        self.api = api
        self.media = media
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard loadingRequest.request.url?.scheme == "watchmedia" else { return false }
        let request = loadingRequest
        Task { await self.fulfill(request) }
        return true
    }

    private func fulfill(_ request: AVAssetResourceLoadingRequest) async {
        if request.isCancelled { return }
        if let info = request.contentInformationRequest {
            info.contentType = contentType(movie.ext)
            info.contentLength = movie.byteSize
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return
        }
        var offset = dataRequest.requestedOffset
        let end = dataRequest.requestsAllDataToEndOfResource
            ? movie.byteSize
            : min(movie.byteSize, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
        do {
            while offset < end {
                if request.isCancelled { return }
                let length = Int(min(Int64(1 << 20), end - offset))
                let data = try await media.data(api: api, movie: movie, offset: offset, length: length)
                if data.isEmpty { throw WatchError.offline }
                dataRequest.respond(with: data)
                offset += Int64(data.count)
            }
            request.finishLoading()
        } catch {
            request.finishLoading(with: error)
        }
    }

    private func contentType(_ ext: String) -> String {
        switch ext {
        case "mov": "com.apple.quicktime-movie"
        case "m4v": "com.apple.m4v-video"
        default: "public.mpeg-4"
        }
    }
}
