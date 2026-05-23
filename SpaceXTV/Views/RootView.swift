import SwiftUI

struct RootView: View {
    @State private var selectedBroadcast: Broadcast?
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            BroadcastBrowserView(
                selectedBroadcast: $selectedBroadcast,
                showsSettings: $showsSettings
            )
                .navigationDestination(item: $selectedBroadcast) { broadcast in
                    PlayerScreen(broadcast: broadcast)
                }
                .navigationDestination(isPresented: $showsSettings) {
                    SettingsView()
                }
        }
    }
}
