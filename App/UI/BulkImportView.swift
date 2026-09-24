import SwiftUI
import UniformTypeIdentifiers

/// Dedicated multi-upload sheet. One row per file with live progress.
/// No Done button — auto-dismisses when everything finishes.
/// Tap + to stack more files into the running queue. X closes the view
/// (the upload keeps running; the library row shows the progress).
struct BulkImportView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var pickingMore = false
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                List {
                    ForEach(library.bulkItems) { item in
                        row(item)
                    }
                }
                .listStyle(.plain)
            }
            .background(Color.black)
            .navigationTitle("Importing \(library.bulkItems.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { onClose() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { pickingMore = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add more")
                }
            }
            .fileImporter(
                isPresented: $pickingMore,
                allowedContentTypes: [.mpeg4Movie, .quickTimeMovie, .movie],
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result else { return }
                var items: [(URL, Bool)] = []
                for u in urls {
                    let ext = u.pathExtension.lowercased()
                    guard ["mp4", "m4v", "mov"].contains(ext) else { continue }
                    let s = u.startAccessingSecurityScopedResource()
                    items.append((u, s))
                }
                if !items.isEmpty { library.importBulk(items) }
            }
        }
        .onChange(of: library.bulkAllFinished) { _, finished in
            if finished {
                Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    onClose()
                }
            }
        }
    }

    private var header: some View {
        let running = library.bulkRunningCount
        let done = library.bulkItems.filter { $0.status == .done }.count
        let failed = library.bulkItems.filter { $0.status == .failed }.count
        return HStack(spacing: 8) {
            Text("\(running) uploading")
            Text("·").foregroundStyle(.secondary)
            Text("\(done) done").foregroundStyle(.green)
            if failed > 0 {
                Text("·").foregroundStyle(.secondary)
                Text("\(failed) failed").foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func row(_ item: BulkItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon(item))
                    .foregroundStyle(color(item))
                Text(item.url.lastPathComponent)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                Spacer()
                if item.status == .failed {
                    Button("Retry") { library.retryBulk(id: item.id) }
                        .font(.caption.bold())
                        .buttonStyle(.bordered)
                        .tint(.orange)
                } else if item.status == .done {
                    Text("Done")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
            }
            ProgressView(value: item.progress)
                .tint(color(item))
            Text(item.error ?? item.stage)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.vertical, 6)
        .listRowBackground(Color(white: 0.08))
    }

    private func icon(_ i: BulkItem) -> String {
        switch i.status {
        case .pending: "clock"
        case .uploading: "arrow.up.circle.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func color(_ i: BulkItem) -> Color {
        switch i.status {
        case .pending: .gray
        case .uploading: .red
        case .done: .green
        case .failed: .orange
        }
    }
}
