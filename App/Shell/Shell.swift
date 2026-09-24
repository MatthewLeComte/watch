import SwiftUI

@main
struct Shell: App {
    @State private var library = LibraryModel()

    var body: some Scene {
        WindowGroup {
            UI.ui_root()
                .environment(library)
                .preferredColorScheme(.dark)
                .task { await library.boot() }
                .onOpenURL { url in
                    let ext = url.pathExtension.lowercased()
                    guard ["mp4", "m4v", "mov"].contains(ext) else { return }
                    library.openImportScoped = url.startAccessingSecurityScopedResource()
                    library.openImport = url
                }
        }
        .defaultSize(width: 1180, height: 780)
    }
}
