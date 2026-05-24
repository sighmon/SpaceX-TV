import SwiftUI

@main
struct SpaceXTVApp: App {
    @StateObject private var library = BroadcastLibrary()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
        }
    }
}
