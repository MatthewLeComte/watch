import SwiftUI

/// UI category — 8 functions. The render layer that the Shell
/// composes. Each function returns a SwiftUI view from the existing UI
/// primitives; no business logic lives here.
@MainActor
enum UI {

    /// 1. The root view shown by the Shell.
    @ViewBuilder
    static func ui_root() -> some View {
        LibraryView()
    }

    /// 2. The library list.
    @ViewBuilder
    static func ui_list() -> some View {
        LibraryView()
    }

    /// 3. A single row in the grid (open detail).
    @ViewBuilder
    static func ui_row(movieID: String) -> some View {
        DetailView(movieID: movieID)
    }

    /// 4. The detail screen.
    @ViewBuilder
    static func ui_detail(movieID: String) -> some View {
        DetailView(movieID: movieID)
    }

    /// 5. The single-file import screen.
    @ViewBuilder
    static func ui_import(url: URL, scoped: Bool, onClose: @escaping () -> Void) -> some View {
        ImportView(url: url, scoped: scoped, onClose: onClose)
    }

    /// 6. The bulk import sheet.
    @ViewBuilder
    static func ui_bulk(onClose: @escaping () -> Void) -> some View {
        BulkImportView(onClose: onClose)
    }

    /// 7. The settings screen.
    @ViewBuilder
    static func ui_settings() -> some View {
        SettingsView()
    }

    /// 8. The unified error screen.
    @ViewBuilder
    static func ui_error(_ error: any Error) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
            Text(error.localizedDescription).foregroundStyle(.white).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
