import SwiftUI
import AVFoundation
import AVKit

struct PlayerView: View {
    @Environment(LibraryModel.self) private var library
    var movie: Movie
    var onClose: () -> Void
    @State private var model: PlayerModel?
    @State private var scrubbing = false
    @State private var scrub: Double = 0
    @State private var zoom: CGFloat = 1
    @State private var lift: CGFloat = 0
    @State private var pan: CGSize = .zero
    @State private var zoomStart: CGFloat = 1
    @State private var liftStart: CGFloat = 0
    @State private var panStart: CGSize = .zero
    @State private var zooming = false
    /// Floating window furniture (traffic lights) reports no safe area, so
    /// the back row adds its own clearance only then. Notch/island and
    /// titlebar screens already report theirs. Same code, every screen.
    @State private var topExtra: CGFloat = 0
    /// One app, one look: fixed chrome everywhere, phone and Mac alike.
    private let chromeButton: CGFloat = 40
    private let playButton: CGFloat = 44

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model, let player = model.player {
                NativePlayerContainer(
                    player: player,
                    chrome: model.chrome,
                    zoom: zoom,
                    lift: lift,
                    pan: pan,
                    onTap: { model.toggleChrome() },
                    onZoom: { zoom = $0 },
                    onLift: { lift = $0 },
                    onPip: { model.pipController = $0 }
                )
                .gesture(pinch)
                .simultaneousGesture(move)
                if model.subtitlesOn, let text = model.cueText, !text.isEmpty {
                    VStack {
                        Spacer()
                        Text(text)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 28)
                            .padding(.bottom, model.chrome ? 120 : 40)
                    }
                }
                closeChrome(model)
            } else if let model, let error = model.errorText {
                Text(error).foregroundStyle(.white)
            }
        }
        .task {
            let player = PlayerModel(movie: movie, api: library.api, media: library.media) { seconds in
                library.remember(position: seconds, for: movie.id)
            }
            model = player
            await player.start(position: library.positions[movie.id] ?? 0)
        }
        .contentShape(Rectangle())
        .onDisappear { model?.stop() }
        #if os(macOS)
        .onExitCommand { onClose() }
        #endif
    }

    private var backButton: some View {
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
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zooming = true
                zoom = min(2.8, max(1, zoomStart * value.magnification))
            }
            .onEnded { _ in
                zooming = false
                if zoom < 1.04 {
                    zoom = 1
                    pan = .zero
                    panStart = .zero
                }
                zoomStart = zoom
            }
    }

    /// Manual picture moves, nothing automatic. Zoomed in: drag pans the
    /// picture. At normal size: a vertical drag lifts it. Taps, horizontal
    /// swipes, and pinch movement never move anything.
    private var move: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !zooming else { return }
                if zoom > 1.02 {
                    pan = CGSize(
                        width: panStart.width + value.translation.width,
                        height: panStart.height + value.translation.height
                    )
                } else if abs(value.translation.height) > 1.5 * abs(value.translation.width) {
                    let delta = -value.translation.height / 320
                    lift = min(1, max(0, liftStart + delta))
                }
            }
            .onEnded { _ in
                panStart = pan
                liftStart = lift
            }
    }

    /// Back sits with the title and scrubber, and leaves with them.
    /// Top clearance follows the screen safe area (notch, island, traffic
    /// lights) instead of branching per platform.
    private func closeChrome(_ model: PlayerModel) -> some View {
        VStack {
            HStack {
                if model.chrome {
                    backButton
                    Text(movie.displayTitle)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                    if model.pipPossible {
                        Button { model.togglePip() } label: {
                            Image(systemName: "pictureInPicture")
                                .font(.body.weight(.semibold))
                                .frame(width: chromeButton, height: chromeButton)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .accessibilityLabel("Picture in Picture")
                    }
                    if let player = model.player {
                        CaptionMenuButton(player: player)
                    }
                } else {
                    Spacer()
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
            if model.chrome {
            VStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { scrubbing ? scrub : model.currentTime },
                        set: { scrub = $0 }
                    ),
                    in: 0...max(model.duration, 1),
                    onEditingChanged: { editing in
                        scrubbing = editing
                        if !editing { model.seek(to: scrub) }
                    }
                )
                .tint(.white)
                HStack {
                    Text(clock(model.currentTime))
                    Spacer()
                    Button { model.togglePlay() } label: {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: playButton, height: playButton)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(model.playing ? "Pause" : "Play")
                    Spacer()
                    Text(clock(model.duration))
                }
                .foregroundStyle(.white)
                .font(.caption.monospacedDigit())
            }
            .padding()
            }
        }
    }
}

/// Native player container using AVPlayerViewController (via VideoPlayer).
/// This gives us native PiP, native captions (including iOS 27 generated captions),
/// and native controls. We overlay custom chrome on top.
private struct NativePlayerContainer: View {
    let player: AVPlayer
    var chrome = false
    var zoom: CGFloat = 1
    var lift: CGFloat = 0
    var pan: CGSize = .zero
    var onTap: () -> Void
    var onZoom: (CGFloat) -> Void
    var onLift: (CGFloat) -> Void
    var onPip: (AVPictureInPictureController?) -> Void

    var body: some View {
        // VideoPlayer is SwiftUI's wrapper around AVPlayerViewController.
        // It provides native controls, PiP, captions menu, etc.
        VideoPlayer(player: player)
            .overlay {
                // Custom zoom/pan/lift transform applied on top of native player
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { onTap() }
                        .gesture(
                            MagnifyGesture()
                                .onChanged { value in
                                    onZoom(min(2.8, max(1, zoom * value.magnification)))
                                }
                        )
                        .gesture(
                            DragGesture(minimumDistance: 12)
                                .onChanged { value in
                                    if zoom > 1.02 {
                                        // Pan handled by parent gesture state
                                    } else if abs(value.translation.height) > 1.5 * abs(value.translation.width) {
                                        onLift(min(1, max(0, lift + (-value.translation.height / 320))))
                                    }
                                }
                        )
                }
                .allowsHitTesting(true)
            }
    }
}

/// Apple's native subtitle menu. On iOS 27/macOS 27 this includes generated captions
/// for movies that have none of their own. Uses AVLegibleMediaOptionsMenuController.
struct CaptionMenuButton: View {
    let player: AVPlayer

    var body: some View {
        let side: CGFloat = 40
        if #available(iOS 26.4, macOS 26.4, *) {
            NativeCaptionMenuButton(player: player)
                .frame(width: side, height: side)
                .contentShape(Circle())
                .glassEffect(.regular, in: Circle())
        }
    }
}

/// Native caption menu button using AVLegibleMediaOptionsMenuController.
/// On iOS: UIButton with showsMenuAsPrimaryAction
/// On macOS: NSButton with menu popUp
@available(iOS 26.4, macOS 26.4, *)
private struct NativeCaptionMenuButton: View {
    let player: AVPlayer

    var body: some View {
        #if os(iOS)
        NativeCaptionMenuButtonIOS(player: player)
        #else
        NativeCaptionMenuButtonMac(player: player)
        #endif
    }
}

#if os(iOS)
@available(iOS 26.4, *)
private struct NativeCaptionMenuButtonIOS: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.tintColor = .white
        button.setImage(UIImage(systemName: "captions.bubble"), for: .normal)
        button.showsMenuAsPrimaryAction = true
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        button.menu = AVLegibleMediaOptionsMenuController(player: player).menu(contents: .all)
    }
}
#else
@available(macOS 26.4, *)
private struct NativeCaptionMenuButtonMac: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .white
        button.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "Subtitles")
        button.target = context.coordinator
        button.action = #selector(Coordinator.pop(_:))
        context.coordinator.player = player
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.player = player
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject {
        var player: AVPlayer?
        @objc func pop(_ sender: NSButton) {
            guard let player else { return }
            let menu = AVLegibleMediaOptionsMenuController(player: player).menu(contents: .all)
            menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
        }
    }
}
#endif

/// Fit the picture in the play area. Lift 0 is centered; lift is strictly
/// manual (drag) and never starts raised. Pan moves a zoomed picture and is
/// clamped to the overflow so edges can't be dragged past.
func pictureRect(in area: CGRect, aspect: CGFloat, zoom: CGFloat, lift: CGFloat, pan: CGSize, topIsMinY: Bool) -> CGRect {
    let ratio = max(aspect, 0.2)
    var width = area.width
    var height = width / ratio
    if height > area.height {
        height = area.height
        width = height * ratio
    }
    let scale = min(2.8, max(1, zoom))
    width *= scale
    height *= scale
    var x = area.midX - width / 2
    let centered = area.midY - height / 2
    let raised = topIsMinY ? area.minY : area.maxY - height
    let amount = min(1, max(0, lift))
    var y = centered + (raised - centered) * amount
    if scale > 1.02 {
        let maxX = max(0, (width - area.width) / 2)
        let maxY = max(0, (height - area.height) / 2)
        x += min(maxX, max(-maxX, pan.width))
        y += min(maxY, max(-maxY, pan.height))
    }
    return CGRect(x: x, y: y, width: width, height: height)
}