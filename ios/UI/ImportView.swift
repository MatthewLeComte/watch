@preconcurrency import AVFoundation
import Foundation
import Observation
import SwiftUI

/// Dedicated two-stage import page: 1) Prepare (copy into the sandbox so the
/// picker can't revoke the file mid-upload) then 2) Upload (multipart to R2).
/// No tiny sidebar bar — each stage gets its own full progress card with
/// bytes and percent.
@MainActor
@Observable
final class ImportModel {
    enum Phase {
        case idle
        case processing(progress: Double, detail: String)
        case uploading(progress: Double, detail: String)
        case finishing
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

    func start(url: URL, scoped: Bool, api: WatchAPI, onDone: @escaping (Movie) -> Void) {
        filename = url.lastPathComponent
        task?.cancel()
        task = Task { await run(url: url, scoped: scoped, api: api, onDone: onDone) }
    }

    private func emit(_ overall: Double, _ stage: String, _ detail: String) {
        onProgress?(overall, stage, detail)
    }

    func cancel() {
        task?.cancel()
        task = nil
        switch phase {
        case .done, .failed: break
        default: phase = .failed(message: "Cancelled.")
        }
    }

    private func run(url: URL, scoped: Bool, api: WatchAPI, onDone: @escaping (Movie) -> Void) async {
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            // Stage 1 — prepare: sandbox the file first, the picker revokes
            // access on first wait.
            phase = .processing(progress: 0, detail: "Copying into sandbox…")
            emit(0.01, "Preparing", "Copying into sandbox…")
            let inbox = try await Task.detached { try Self.copyIntoInbox(url) }.value
            defer { try? FileManager.default.removeItem(at: inbox) }
            preview = await Self.firstFrame(of: inbox)

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
        } catch is CancellationError {
            phase = .failed(message: "Cancelled.")
            onError?("Cancelled.")
        } catch {
            let msg = error.localizedDescription
            phase = .failed(message: msg)
            onError?(msg)
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
        case .processing, .uploading, .finishing: return true
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
                    title: "Prepare",
                    subtitle: "Copy into sandbox",
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
        return "Waiting to prepare…"
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
