import SwiftUI
import AVFoundation
import AVKit

struct PlayerView: View {
    @Environment(LibraryModel.self) private var library
    var movie: Movie
    var onClose: () -> Void
    @State private var model: PlayerModel?
    @State private var topExtra: CGFloat = 0
    private let chromeButton: CGFloat = 44

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model, let player = model.player {
                NativePlayerController(player: player)
                    .ignoresSafeArea()
                topBar(model)
            } else if let model, let error = model.errorText {
                Text(error).foregroundStyle(.white)
            }
        }
        .task(id: movie.id) {
            let player = PlayerModel(movie: movie, api: library.api, media: library.media) { seconds in
                library.remember(position: seconds, for: movie.id)
            }
            model = player
            await player.start(position: library.positions[movie.id] ?? 0)
        }
        .onDisappear { model?.stop() }
    }

    private func topBar(_ model: PlayerModel) -> some View {
        VStack {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.backward")
                        .font(.body.weight(.semibold))
                        .frame(width: chromeButton, height: chromeButton)
                        .contentShape(Circle())
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel("Back")
                Text(movie.displayTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                if model.player != nil {
                    Button { model.toggleSubtitles() } label: {
                        Image(systemName: model.subtitlesOn ? "captions.bubble.fill" : "captions.bubble")
                            .font(.body.weight(.semibold))
                            .frame(width: chromeButton, height: chromeButton)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .accessibilityLabel(model.subtitlesOn ? "Turn off subtitles" : "Turn on subtitles")
                }
            }
            .padding()
            .safeAreaPadding(.top)
            .padding(.top, topExtra)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.safeAreaInsets.top, initial: true) {
                            topExtra = geo.safeAreaInsets.top < 8 ? 28 : 0
                        }
                }
            }
            Spacer()
        }
    }
}

/// The one and only player: AVPlayerViewController with Apple transport
/// controls (scrubber, play/pause, PiP, AirPlay, native caption picker).
/// No custom slider or buttons duplicating it.
private struct NativePlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.updatesNowPlayingInfoCenter = true
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}
