import SwiftUI
import UIKit
import AVKit
import AVFoundation

/// Pure Apple player: the AVPlayerViewController itself is presented modally,
/// so Done, transport, PiP, AirPlay, and the caption picker are all native.
/// Zero custom UI over video.
final class DismissablePlayerVC: AVPlayerViewController {
    var onDone: (() -> Void)?
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed { onDone?() }
    }
}

struct FullScreenPlayer: ViewModifier {
    @Binding var movie: Movie?
    @Environment(LibraryModel.self) private var library
    @State private var model: PlayerModel?
    @State private var presented: DismissablePlayerVC?

    func body(content: Content) -> some View {
        content.onChange(of: movie?.id) { _, _ in sync() }
    }

    @MainActor
    private func sync() {
        if let m = movie {
            guard model == nil else { return }
            let mdl = PlayerModel(movie: m, api: library.api, media: library.media) { seconds in
                library.remember(position: seconds, for: m.id)
            }
            model = mdl
            Task {
                await mdl.start(position: library.positions[m.id] ?? 0)
                guard let player = mdl.player, movie?.id == m.id else {
                    await MainActor.run {
                        mdl.stop()
                        if movie?.id == m.id { movie = nil }
                        if model === mdl { model = nil }
                    }
                    return
                }
                let vc = DismissablePlayerVC()
                vc.player = player
                vc.modalPresentationStyle = .fullScreen
                vc.allowsPictureInPicturePlayback = true
                vc.updatesNowPlayingInfoCenter = true
                vc.onDone = {
                    mdl.stop()
                    model = nil
                    presented = nil
                    movie = nil
                }
                presented = vc
                topVC()?.present(vc, animated: true)
            }
        } else {
            if let vc = presented {
                presented = nil
                vc.dismiss(animated: true)
            }
            model?.stop()
            model = nil
        }
    }

    private func topVC() -> UIViewController? {
        var base = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.rootViewController
        while let next = base?.presentedViewController { base = next }
        return base
    }
}
