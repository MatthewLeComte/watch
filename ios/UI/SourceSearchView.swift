import SwiftUI

/// Search 67movies and add to library.
struct SourceSearchView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var results: [SourceSearchResult] = []
    @State private var searching = false
    @State private var error: String?
    @State private var selected: SourceSearchResult?
    @State private var showQualityPicker = false
    @State private var pendingStream: SourceStreamInfo?
    @State private var pendingQuality: SourceQuality?
    @State private var pendingSubtitle: SourceSubtitle?
    @State private var downloading = false
    @State private var downloadStage = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Search bar
                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.black)

                    // Results
                    if searching {
                        Spacer()
                        ProgressView()
                            .tint(.white)
                        Spacer()
                    } else if let error {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 40))
                                .foregroundStyle(.yellow)
                            Text(error)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                            Button("Retry") { Task { await doSearch() } }
                                .buttonStyle(.borderedProminent)
                        }
                        Spacer()
                    } else if results.isEmpty && !query.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundStyle(.white.opacity(0.4))
                            Text("No results for \"\(query)\"")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                    } else if results.isEmpty {
                        // Empty state with suggestions
                        Spacer()
                        VStack(spacing: 16) {
                            Image(systemName: "magnifyingglass.circle")
                                .font(.system(size: 60))
                                .foregroundStyle(Cinema.red)
                            Text("Search 67movies")
                                .font(.title.weight(.bold))
                                .foregroundStyle(.white)
                            Text("Type a movie title or IMDb ID (ttXXXXXXX)")
                                .foregroundStyle(.white.opacity(0.6))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        Spacer()
                    } else {
                        List {
                            ForEach(results) { result in
                                resultRow(result)
                                    .listRowBackground(Color.black)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("Add from 67movies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $selected) { result in
                SourceResolveView(
                    library: library,
                    result: result,
                    onDownload: { stream, quality, subtitle in
                        selected = nil
                        pendingStream = stream
                        pendingQuality = quality
                        pendingSubtitle = subtitle
                        showQualityPicker = true
                    }
                )
            }
            .sheet(isPresented: $showQualityPicker) {
                if let stream = pendingStream, let quality = pendingQuality {
                    SourceDownloadConfirmView(
                        stream: stream,
                        quality: quality,
                        subtitle: pendingSubtitle,
                        onConfirm: { q, sub in
                            Task { await doDownload(stream: stream, quality: q, subtitle: sub) }
                        },
                        onCancel: { showQualityPicker = false }
                    )
                }
            }
            .overlay {
                if downloading {
                    downloadOverlay
                }
            }
            .onChange(of: query) { _, new in
                if new.hasPrefix("tt") && new.count >= 9 {
                    Task { await doSearch(imdb: new) }
                } else if new.count >= 2 {
                    Task { await doSearch() }
                } else {
                    results = []
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.5))
            TextField("Movie title or IMDb ID (ttXXXXXXX)", text: $query)
                .foregroundStyle(.white)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .onSubmit { Task { await doSearch() } }
            if !query.isEmpty {
                Button { query = ""; results = [] } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func resultRow(_ result: SourceSearchResult) -> some View {
        HStack(spacing: 14) {
            // Poster
            AsyncImage(url: result.poster.flatMap(URL.init)) { phase in
                switch phase {
                case .empty:
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.1))
                        .overlay(ProgressView().tint(.white.opacity(0.3)))
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.1))
                        .overlay(Image(systemName: "film").foregroundStyle(.white.opacity(0.3)))
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 60, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(result.displayTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let imdb = result.imdbId {
                    Text("IMDb: \(imdb)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.white.opacity(0.4))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selected = result
        }
    }

    private func doSearch(imdb: String? = nil) async {
        searching = true
        error = nil
        do {
            if let imdb {
                results = try await library.sourceSearchByImdb(imdbId: imdb)
            } else {
                results = try await library.sourceSearch(query: query)
            }
        } catch {
            self.error = error.localizedDescription
            results = []
        }
        searching = false
    }

    private func doDownload(stream: SourceStreamInfo, quality: SourceQuality, subtitle: SourceSubtitle?) async {
        downloading = true
        downloadStage = "Preparing…"

        do {
            let movie = try await library.sourceDownload(
                stream: stream,
                qualityHeight: quality.height,
                subtitleLang: subtitle?.lang
            )
            library.adopt(movie)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            // Show error briefly then dismiss overlay
            try? await Task.sleep(for: .seconds(3))
        }
        downloading = false
    }

    private var downloadOverlay: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                Text(downloadStage.isEmpty ? "Downloading & Processing…" : downloadStage)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("This may take a few minutes")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// Resolve movie page → show qualities & subtitles.
struct SourceResolveView: View {
    let library: LibraryModel
    let result: SourceSearchResult
    let onDownload: (SourceStreamInfo, SourceQuality, SourceSubtitle?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var streamInfo: SourceStreamInfo?
    @State private var resolving = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if resolving {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("Loading stream info…")
                            .foregroundStyle(.white.opacity(0.8))
                    }
                } else if let error {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundStyle(.yellow)
                        Text(error)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button("Retry") { Task { await resolve() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if let stream = streamInfo {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            // Header
                            HStack(spacing: 16) {
                                AsyncImage(url: stream.poster.flatMap(URL.init)) { phase in
                                    switch phase {
                                    case .empty:
                                        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1))
                                    case .success(let img):
                                        img.resizable().scaledToFill()
                                    case .failure:
                                        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1))
                                            .overlay(Image(systemName: "film").foregroundStyle(.white.opacity(0.3)))
                                    @unknown default:
                                        EmptyView()
                                    }
                                }
                                .frame(width: 100, height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(stream.title)
                                        .font(.title2.weight(.bold))
                                        .foregroundStyle(.white)
                                    if let year = stream.year {
                                        Text("\(year)")
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                    if let imdb = stream.imdbId {
                                        Text(imdb)
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.5))
                                    }
                                }
                            }

                            // Qualities
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Quality")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(.white)

                                ForEach(stream.qualities) { q in
                                    Button {
                                        onDownload(stream, q, nil)
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("\(q.height)p")
                                                    .font(.headline.weight(.semibold))
                                                    .foregroundStyle(.white)
                                                Text("\(q.bandwidth / 1_000_000) Mbps • \(q.codecs)")
                                                    .font(.caption)
                                                    .foregroundStyle(.white.opacity(0.6))
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .foregroundStyle(.white.opacity(0.4))
                                        }
                                        .padding()
                                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            // Subtitles
                            if !stream.subtitles.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Subtitles")
                                        .font(.headline.weight(.bold))
                                        .foregroundStyle(.white)

                                    ForEach(stream.subtitles) { s in
                                        Button {
                                            onDownload(stream, stream.qualities.first!, s)
                                        } label: {
                                            HStack {
                                                Text(s.label)
                                                    .font(.headline.weight(.semibold))
                                                    .foregroundStyle(.white)
                                                if s.forced {
                                                    Text("FORCED")
                                                        .font(.caption2.weight(.bold))
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Cinema.red, in: Capsule())
                                                }
                                                Spacer()
                                                Image(systemName: "chevron.right")
                                                    .foregroundStyle(.white.opacity(0.4))
                                            }
                                            .padding()
                                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    // None option
                                    Button {
                                        onDownload(stream, stream.qualities.first!, nil)
                                    } label: {
                                        HStack {
                                            Text("None")
                                                .font(.headline.weight(.semibold))
                                                .foregroundStyle(.white)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .foregroundStyle(.white.opacity(0.4))
                                        }
                                        .padding()
                                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle(result.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await resolve() }
        }
    }

    private func resolve() async {
        resolving = true
        error = nil
        do {
            streamInfo = try await library.sourceResolve(id: result.id)
        } catch {
            self.error = error.localizedDescription
        }
        resolving = false
    }
}

/// Confirm download with quality & subtitle selection.
struct SourceDownloadConfirmView: View {
    let stream: SourceStreamInfo
    let quality: SourceQuality
    let subtitle: SourceSubtitle?
    let onConfirm: (SourceQuality, SourceSubtitle?) -> Void
    let onCancel: () -> Void

    @State private var selectedQuality: SourceQuality
    @State private var selectedSubtitle: SourceSubtitle?

    init(stream: SourceStreamInfo, quality: SourceQuality, subtitle: SourceSubtitle?, onConfirm: @escaping (SourceQuality, SourceSubtitle?) -> Void, onCancel: @escaping () -> Void) {
        self.stream = stream
        self.quality = quality
        self.subtitle = subtitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self._selectedQuality = State(initialValue: quality)
        self._selectedSubtitle = State(initialValue: subtitle)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Movie info
                        HStack(spacing: 16) {
                            AsyncImage(url: stream.poster.flatMap(URL.init)) { phase in
                                switch phase {
                                case .empty:
                                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1))
                                case .success(let img):
                                    img.resizable().scaledToFill()
                                case .failure:
                                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1))
                                        .overlay(Image(systemName: "film").foregroundStyle(.white.opacity(0.3)))
                                @unknown default:
                                    EmptyView()
                                }
                            }
                            .frame(width: 80, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(stream.title)
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(.white)
                                if let year = stream.year {
                                    Text("\(year)")
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                            }
                        }

                        // Quality picker
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Quality")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)

                            ForEach(stream.qualities) { q in
                                Button {
                                    selectedQuality = q
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(q.height)p")
                                                .font(.headline.weight(.semibold))
                                                .foregroundStyle(.white)
                                            Text("\(q.bandwidth / 1_000_000) Mbps • \(q.codecs)")
                                                .font(.caption)
                                                .foregroundStyle(.white.opacity(0.6))
                                        }
                                        Spacer()
                                        if selectedQuality.id == q.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(Cinema.red)
                                                .font(.title2)
                                        }
                                    }
                                    .padding()
                                    .background(
                                        selectedQuality.id == q.id ?
                                        Color.white.opacity(0.15) : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(selectedQuality.id == q.id ? Cinema.red : Color.clear, lineWidth: 2)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Subtitle picker
                        if !stream.subtitles.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Subtitles")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(.white)

                                Button {
                                    selectedSubtitle = nil
                                } label: {
                                    subtitleRow(label: "None", selected: selectedSubtitle == nil)
                                }
                                .buttonStyle(.plain)

                                ForEach(stream.subtitles) { s in
                                    Button {
                                        selectedSubtitle = s
                                    } label: {
                                        subtitleRow(label: s.label, forced: s.forced, selected: selectedSubtitle?.id == s.id)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Confirm Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        onConfirm(selectedQuality, selectedSubtitle)
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }

    private func subtitleRow(label: String, forced: Bool = false, selected: Bool) -> some View {
        HStack {
            Text(label)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            if forced {
                Text("FORCED")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Cinema.red, in: Capsule())
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Cinema.red)
                    .font(.title2)
            }
        }
        .padding()
        .background(
            selected ? Color.white.opacity(0.15) : Color.white.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Cinema.red : Color.clear, lineWidth: 2)
        )
    }
}