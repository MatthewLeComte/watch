@preconcurrency import AVFoundation
import Foundation
import Observation
import SwiftUI

/// Dedicated two-stage import page: 1) Process (on-device VideoToolbox
/// HEVC transcode) then 2) Upload (multipart to R2). No tiny sidebar bar —
/// each stage gets its own full progress card with bytes and percent.
@MainActor
@Observable
final class ImportModel {
    enum Phase {
        case idle
        case processing(progress: Double, detail: String)
        case uploading(progress: Double, detail: String)
        case finishing
        case match(Movie)
        case done(title: String)
        case failed(message: String)
    }

    var phase: Phase = .idle
    var filename: String = ""
    /// (overall 0→1, stage, detail) — mirrored to the library pending poster.
    var onProgress: ((Double, String, String) -> Void)?
    /// First-frame preview of the picked file, filled in before stage 1.
    var preview: Image?
    /// Bulk runner hook: called when the import fails so the caller can
    /// free its concurrency slot. onDone fires only on success.
    var onError: ((String) -> Void)?
    private var task: Task<Void, Never>?
    private var matchMovie: Movie?
    private var matchResume: CheckedContinuation<Movie, Never>?

    func start(url: URL, scoped: Bool, api: WatchAPI, onDone: @escaping (Movie) -> Void) {
        filename = url.lastPathComponent
        task?.cancel()
        task = Task { await run(url: url, scoped: scoped, api: api, onDone: onDone) }
    }

    private func emit(_ overall: Double, _ stage: String, _ detail: String) {
        onProgress?(overall, stage, detail)
    }

    func cancel() {
        // Unstick the match gate first so the run can observe cancellation.
        if let resume = matchResume, let movie = matchMovie {
            matchResume = nil
            resume.resume(returning: movie)
        }
        task?.cancel()
        task = nil
        switch phase {
        case .done, .failed: break
        default: phase = .failed(message: "Cancelled.")
        }
    }

    /// Accept the shown auto-match and finish the import.
    func acceptMatch() {
        if let resume = matchResume, let movie = matchMovie {
            matchResume = nil
            resume.resume(returning: movie)
        }
    }

    /// Refresh the shown match after an in-flow correction.
    func refreshMatch(api: WatchAPI, id: String) async {
        guard let updated = try? await api.one(id: id) else { return }
        matchMovie = updated
        phase = .match(updated)
    }

    private func run(url: URL, scoped: Bool, api: WatchAPI, onDone: @escaping (Movie) -> Void) async {
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            // Sandbox the file first: the picker revokes access on first wait.
            phase = .processing(progress: 0, detail: "Copying into sandbox…")
            emit(0.01, "Transcoding", "Copying into sandbox…")
            let inbox = try await Task.detached { try Self.copyIntoInbox(url) }.value
            defer { try? FileManager.default.removeItem(at: inbox) }
            preview = await Self.firstFrame(of: inbox)

            // // Stage 1 — process.
            // phase = .processing(progress: 0, detail: "Starting transcode…")
            // emit(0.02, "Transcoding", "Starting transcode…")
            // let source = try await transcodeToHEVC(inbox)
            // // DEBUG: Export encoded file to Documents for VMAF testing
            // if ProcessInfo.processInfo.environment["DEBUG_EXPORT"] == "1" {
            //     let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            //     let debugOut = docs.appendingPathComponent("DEBUG-\(UUID().uuidString).mp4")
            //     try? FileManager.default.copyItem(at: source, to: debugOut)
            //     print("DEBUG EXPORT: \(debugOut.path)")
            // }
            let source = inbox
            defer { if source != inbox { try? FileManager.default.removeItem(at: source) } }
            let size = (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard size > 0 else { throw WatchError.server("Empty file") }

            // Stage 2 — upload.
            phase = .uploading(progress: 0, detail: "Creating library entry…")
            emit(0.5, "Uploading", "Creating library entry…")
            let created = try await api.create(filename: url.lastPathComponent, byteSize: size)
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            var offset: UInt64 = 0
            var part = 1
            var totalParts = Int((size + Int64(created.partSize) - 1) / Int64(created.partSize))
            totalParts = max(totalParts, 1)
            while offset < UInt64(size) {
                try Task.checkCancellation()
                try handle.seek(toOffset: offset)
                let n = Int(min(UInt64(created.partSize), UInt64(size) - offset))
                guard let chunk = try handle.read(upToCount: n), !chunk.isEmpty else { break }
                let slice = FileManager.default.temporaryDirectory.appendingPathComponent("watch-part-\(part)")
                try chunk.write(to: slice, options: .atomic)
                defer { try? FileManager.default.removeItem(at: slice) }
                try await api.uploadPart(id: created.id, part: part, file: slice)
                offset += UInt64(chunk.count)
                part += 1
let frac = size > 0 ? Double(offset) / Double(size) : 0
                 let detail = "Part \(min(part - 1, totalParts)) of \(totalParts) — \(byteText(Int64(offset))) of \(byteText(size))"
                 phase = .uploading(progress: frac, detail: detail)
                 emit(0.5 + 0.5 * frac, "Uploading", detail)
            }

            phase = .finishing
            emit(0.99, "Finishing", "Finalizing…")
            _ = try await api.complete(id: created.id)
            let final = try await api.one(id: created.id)
            phase = .done(title: final.displayTitle)
            onDone(final)
            // // Ingest ran once on the server. Show its auto-match for
            // // confirm/adjust here — never re-ingest, never guess.
            // var movie = try await api.complete(id: created.id)
            // movie = try await api.one(id: created.id)
            // matchMovie = movie
            // phase = .match(movie)
            // emit(1.0, "Matching", movie.matchNote.isEmpty ? "Auto-match ready" : movie.matchNote)
            // movie = await withCheckedContinuation { matchResume = $0 }
            // matchResume = nil
            // matchMovie = nil
            // try Task.checkCancellation()
            // phase = .done(title: movie.displayTitle)
            // onDone(movie)
        } catch is CancellationError {
            phase = .failed(message: "Cancelled.")
            onError?("Cancelled.")
        } catch {
            let msg = error.localizedDescription
            phase = .failed(message: msg)
            onError?(msg)
        }
    }

    /// Hardware HEVC via VideoToolbox. Target: CQ (constant quality) with
    /// regular keyframes for instant scrubbing, matched source FPS, B-frames
    /// for efficiency. Returns the transcoded file, or the input unchanged when
    /// this device can't HEVC-encode. Progress reports through `.processing` phase updates.
    private func transcodeToHEVC(_ input: URL) async throws -> URL {
        let asset = AVURLAsset(url: input, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return input }
        let naturalSize = try await track.load(.naturalSize)
        let frameRate = try await track.load(.nominalFrameRate)
        let fps = frameRate > 0 ? Double(frameRate) : 24
        let duration = try await asset.load(.duration)
        let totalFrames = Int(ceil(duration.seconds * fps))

        // Pre-load audio track if present
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first

        // Target bitrate for visually lossless HEVC (x265 CRF 12 ≈ 99.7 VMAF)
        // Based on pixel count — handles all aspect ratios (4:3, 16:9, 2.35:1, 960p, etc.)
        let pixelCount = naturalSize.width * naturalSize.height
        let targetBitrate: Int
        switch pixelCount {
        case 8_294_400...:          targetBitrate = 30_000_000  // 4K+ (3840×2160=8.3M+)
        case 6_220_800..<8_294_400: targetBitrate = 25_000_000  // 3.2K (3200×1800=5.8M)
        case 4_665_600..<6_220_800: targetBitrate = 20_000_000  // 1440p+ (2560×1440=3.7M, 2880×1620=4.7M)
        case 3_110_400..<4_665_600: targetBitrate = 16_000_000  // 1080p-1440p (1920×1080=2.1M, 2560×1080=2.8M)
        case 2_073_600..<3_110_400: targetBitrate = 12_000_000  // 1080p / 960p (1920×800=1.5M, 1280×960=1.2M)
        case 1_244_160..<2_073_600: targetBitrate = 8_000_000   // 960p / 720p+
        case 921_600..<1_244_160:   targetBitrate = 5_000_000   // 720p (1280×720=921K)
        default:                     targetBitrate = 3_500_000  // 480p and below
        }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("watch-hevc-\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let codecSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: naturalSize.width,
            AVVideoHeightKey: naturalSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: targetBitrate,
                AVVideoQualityKey: 0.95,           // Max quality within bitrate budget
                AVVideoProfileLevelKey: "HEVCMainAutoLevel",
                AVVideoAllowFrameReorderingKey: true,  // B-frames
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: Int(fps * 2), // keyframe every 2s = instant scrub
            ]
        ]
        let inputWriter = AVAssetWriterInput(mediaType: .video, outputSettings: codecSettings)
        inputWriter.expectsMediaDataInRealTime = false
        inputWriter.transform = try await track.load(.preferredTransform)
        writer.add(inputWriter)

        let sourceReader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        sourceReader.add(readerOutput)

        // Audio passthrough (copy)
        final class AudioRefs: @unchecked Sendable {
            var input: AVAssetWriterInput?
            var output: AVAssetReaderTrackOutput?
        }
        let audioRefs = AudioRefs()
        if let audioTrack {
            let formatDescs = try? await audioTrack.load(.formatDescriptions)
            if let formatDesc = formatDescs?.first {
                let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
                if let desc = basicDesc?.pointee {
                    let audioSettings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC_HE_V2,
                        AVSampleRateKey: desc.mSampleRate,
                        AVNumberOfChannelsKey: desc.mChannelsPerFrame,
                        AVEncoderBitRateKey: 128_000,
                    ]
                    let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                    aIn.expectsMediaDataInRealTime = false
                    writer.add(aIn)
                    audioRefs.input = aIn

                    let audioReader = try AVAssetReader(asset: asset)
                    let aOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                    audioReader.add(aOut)
                    audioReader.startReading()
                    audioRefs.output = aOut
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            final class TranscodeState: @unchecked Sendable {
                let writer: AVAssetWriter
                let inputWriter: AVAssetWriterInput
                let readerOutput: AVAssetReaderTrackOutput
                let audioInput: AVAssetWriterInput?
                let audioOutput: AVAssetReaderTrackOutput?
                let continuation: CheckedContinuation<URL, any Error>
                var framesWritten: Int = 0
                let totalFrames: Int
                let onProgress: @Sendable (Double) -> Void

                init(writer: AVAssetWriter, inputWriter: AVAssetWriterInput, readerOutput: AVAssetReaderTrackOutput, audioInput: AVAssetWriterInput?, audioOutput: AVAssetReaderTrackOutput?, continuation: CheckedContinuation<URL, any Error>, totalFrames: Int, onProgress: @escaping @Sendable (Double) -> Void) {
                    self.writer = writer
                    self.inputWriter = inputWriter
                    self.readerOutput = readerOutput
                    self.audioInput = audioInput
                    self.audioOutput = audioOutput
                    self.continuation = continuation
                    self.totalFrames = totalFrames
                    self.onProgress = onProgress
                }

                func finish() {
                    let outputURL = writer.outputURL
                    let writeError = writer.error
                    let cont = continuation
                    writer.finishWriting {
                        if let writeError {
                            cont.resume(throwing: writeError)
                        } else {
                            cont.resume(returning: outputURL)
                        }
                    }
                }

                func startAudio(on queue: DispatchQueue) {
                    guard let audioInput, let audioOutput else { return }
                    audioInput.requestMediaDataWhenReady(on: queue) { [weak self] in
                        guard let self else { return }
                        while audioInput.isReadyForMoreMediaData {
                            guard let sample = audioOutput.copyNextSampleBuffer() else {
                                audioInput.markAsFinished()
                                self.finish()
                                return
                            }
                            audioInput.append(sample)
                        }
                    }
                }
            }

            let onProgress: @Sendable (Double) -> Void = { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    let pct = Int((progress * 100).rounded())
                    self.phase = .processing(progress: progress, detail: "Transcoding… \(pct)%")
                    self.emit(progress * 0.5, "Transcoding", "Transcoding… \(pct)%")
                }
            }

            let state = TranscodeState(
                writer: writer,
                inputWriter: inputWriter,
                readerOutput: readerOutput,
                audioInput: audioRefs.input,
                audioOutput: audioRefs.output,
                continuation: continuation,
                totalFrames: totalFrames,
                onProgress: onProgress
            )

            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            sourceReader.startReading()

            let videoQueue = DispatchQueue(label: "watch.encode.video")

            state.inputWriter.requestMediaDataWhenReady(on: videoQueue) {
                while state.inputWriter.isReadyForMoreMediaData {
                    guard let sample = state.readerOutput.copyNextSampleBuffer() else {
                        state.inputWriter.markAsFinished()
                        if state.audioInput == nil { state.finish() }
                        return
                    }
                    state.inputWriter.append(sample)
                    state.framesWritten += 1
                    if state.framesWritten % 30 == 0 {
                        let progress = state.totalFrames > 0 ? Double(state.framesWritten) / Double(state.totalFrames) : 0
                        state.onProgress(progress)
                    }
                }
            }

            if state.audioInput != nil {
                let audioQueue = DispatchQueue(label: "watch.encode.audio")
                state.startAudio(on: audioQueue)
            } else {
                state.finish()
            }
        }
    }

    private nonisolated func finish(_ writer: AVAssetWriter, _ continuation: CheckedContinuation<URL, any Error>) {
        writer.finishWriting {
            if let error = writer.error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: writer.outputURL)
            }
        }
    }

    /// First video frame for the import preview card. Nonisolated so it
    /// never blocks the progress updates on the main actor.
    private nonisolated static func firstFrame(of url: URL) async -> Image? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        do {
            let image = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
            return Image(decorative: image, scale: 1)
        } catch {
            return nil
        }
    }

    private nonisolated static func copyIntoInbox(_ url: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }
}

struct ImportView: View {
    @Environment(LibraryModel.self) private var library
    @State private var model = ImportModel()
    @State private var pendingID: UUID?
    @State private var adjusting: Movie?
    @State private var didAdjust = false
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let scoped: Bool
    var onClose: () -> Void = {}

    private func close() {
        onClose()
        dismiss()
    }

    private var running: Bool {
        switch model.phase {
        case .processing, .uploading, .finishing, .match: return true
        default: return false
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text(model.filename.isEmpty ? url.lastPathComponent : model.filename)
                    .font(.title2.bold())
                    .lineLimit(2)
                if let preview = model.preview {
                    preview
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                stageCard(
                    number: "1",
                    title: "Process",
                    subtitle: "On-device HEVC transcode",
                    progress: processingProgress,
                    detail: processingDetail,
                    active: isProcessing
                )
                stageCard(
                    number: "2",
                    title: "Upload",
                    subtitle: "Multipart to library",
                    progress: uploadingProgress,
                    detail: uploadingDetail,
                    active: isUploading
                )
                if case .match(let movie) = model.phase {
                    matchCard(movie)
                }
                Spacer()
                switch model.phase {
                case .done:
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(Cinema.red)
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                    HStack {
                        Button("Retry") { start() }
                            .buttonStyle(.borderedProminent)
                            .tint(Cinema.red)
                        Button("Close") {
                            if let id = pendingID { library.endPending(id: id); pendingID = nil }
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                case .finishing:
                    ProgressView("Finishing…")
                default:
                    Button("Cancel") {
                        model.cancel()
                        if let id = pendingID { library.endPending(id: id); pendingID = nil }
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
                if case .done(let title) = model.phase {
                    Text("\(title) is in your library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .navigationTitle("Add a movie")
            .toolbar { }
        }
        .onAppear { start() }
        .interactiveDismissDisabled(running)
        .sheet(item: $adjusting) { movie in
            CorrectMatchView(movie: movie)
        }
    }

    /// Stage 3 — the server ingested once. Confirm its auto-match here or
    /// adjust it in place. No re-ingest, no guessing.
    private func matchCard(_ movie: Movie) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("3")
                    .font(.title.bold())
                    .foregroundStyle(Cinema.red)
                    .frame(width: 36)
                VStack(alignment: .leading) {
                    Text("Match").font(.headline)
                    Text("Server ingest result — confirm or adjust").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(movie.displayTitle)
                .font(.title3.bold())
            HStack(spacing: 8) {
                if !movie.yearText.isEmpty { Text(movie.yearText) }
                if let runtime = movie.runtimeText { Text(runtime) }
                if !movie.matchSource.isEmpty { Text(movie.matchSource).foregroundStyle(Cinema.red) }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            if !movie.matchNote.isEmpty {
                Text(movie.matchNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Looks right") { model.acceptMatch() }
                    .buttonStyle(.borderedProminent)
                    .tint(Cinema.red)
                Button("Adjust") { didAdjust = true; adjusting = movie }
                    .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onDisappear {
            // A correction saved underneath: refresh the shown auto-match.
            // Only after Adjust — Accept tears this card down for .done.
            if didAdjust, case .match(let current) = model.phase {
                didAdjust = false
                Task { await model.refreshMatch(api: library.api, id: current.id) }
            }
        }
    }

    private func start() {
        let id = library.beginPending(filename: url.lastPathComponent)
        pendingID = id
        model.onProgress = { overall, stage, detail in
            library.updatePending(id: id, stage: stage, progress: overall, detail: detail)
        }
        model.start(url: url, scoped: scoped, api: library.api) { movie in
            library.endPending(id: id)
            pendingID = nil
            library.adopt(movie)
        }
    }

    private var isProcessing: Bool {
        if case .processing = model.phase { return true }
        return false
    }

    private var isUploading: Bool {
        switch model.phase {
        case .uploading, .finishing: return true
        default: return false
        }
    }

    private var processingProgress: Double? {
        if case .processing(let p, _) = model.phase { return p }
        if isUploading { return 1 }
        if case .done = model.phase { return 1 }
        return nil
    }

    private var processingDetail: String {
        if case .processing(_, let d) = model.phase { return d }
        if isUploading { return "Done" }
        if case .done = model.phase { return "Done" }
        if case .failed = model.phase { return "Failed" }
        return "Waiting…"
    }

    private var uploadingProgress: Double? {
        if case .uploading(let p, _) = model.phase { return p }
        if case .done = model.phase { return 1 }
        return nil
    }

    private var uploadingDetail: String {
        if case .uploading(_, let d) = model.phase { return d }
        if case .done = model.phase { return "Done" }
        if case .failed = model.phase { return "Failed" }
        return "Waiting for process…"
    }

    private func stageCard(number: String, title: String, subtitle: String, progress: Double?, detail: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(number)
                    .font(.title.bold())
                    .foregroundStyle(Cinema.red)
                    .frame(width: 36)
                VStack(alignment: .leading) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if active { ProgressView() }
            }
            if let progress {
                ProgressView(value: progress)
                    .tint(Cinema.red)
                HStack {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((progress * 100).rounded()))%").font(.caption.monospaced())
                }
            } else {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .opacity(active || progress != nil ? 1 : 0.6)
    }
}
