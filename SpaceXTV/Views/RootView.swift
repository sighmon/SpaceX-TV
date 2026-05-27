import SwiftUI

struct RootView: View {
    @State private var selectedBroadcast: Broadcast?
    @State private var selectedGallery: Broadcast?
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            BroadcastBrowserView(
                selectedBroadcast: $selectedBroadcast,
                selectedGallery: $selectedGallery,
                showsSettings: $showsSettings
            )
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $selectedBroadcast) { broadcast in
                    PlayerScreen(broadcast: broadcast)
                }
                .navigationDestination(item: $selectedGallery) { gallery in
                    GalleryScreen(gallery: gallery)
                }
                .navigationDestination(isPresented: $showsSettings) {
                    SettingsView()
                }
        }
    }
}
