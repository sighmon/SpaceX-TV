import SwiftUI

struct RootView: View {
    @State private var selectedBroadcast: Broadcast?
    @State private var selectedGallery: Broadcast?
    @State private var showsSettings = false

    var body: some View {
        ZStack {
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
#if os(tvOS)
                    .navigationDestination(item: $selectedGallery) { gallery in
                        GalleryScreen(gallery: gallery)
                    }
#endif
                    .navigationDestination(isPresented: $showsSettings) {
                        SettingsView()
                    }
            }
#if !os(tvOS)
            if let selectedGallery {
                GalleryScreen(gallery: selectedGallery) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        self.selectedGallery = nil
                    }
                }
                .transition(.move(edge: .trailing))
                .zIndex(1)
            }
#endif
        }
#if !os(tvOS)
        .animation(.easeInOut(duration: 0.28), value: selectedGallery?.id)
#endif
    }
}
