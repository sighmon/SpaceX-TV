import SwiftUI
import UIKit

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
                        if broadcast.sourceKind == .youtube {
                            YouTubeLaunchScreen(broadcast: broadcast)
                        } else {
                            PlayerScreen(broadcast: broadcast)
                        }
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

private struct YouTubeLaunchScreen: View {
    let broadcast: Broadcast

    @State private var attemptedLocalOpen = false
    @State private var handoffActivity: NSUserActivity?
    @State private var status = "Opening YouTube…"

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 72))

            Text(broadcast.title)
                .font(.title)
                .multilineTextAlignment(.center)

            Text(status)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Try YouTube Again") {
                Task { await openYouTube() }
            }
            .buttonStyle(.bordered)
        }
        .padding(60)
        .task {
            guard !attemptedLocalOpen else { return }
            attemptedLocalOpen = true
            await openYouTube()
        }
        .onDisappear {
            handoffActivity?.invalidate()
        }
    }

    @MainActor
    private func openYouTube() async {
        handoffActivity?.invalidate()
        handoffActivity = nil
        status = "Opening YouTube…"

        for url in youtubeAppURLs {
            guard UIApplication.shared.canOpenURL(url) else { continue }
            if await open(url) {
                return
            }
        }

        if await open(broadcast.sourceURL, options: [.universalLinksOnly: true]) {
            return
        }

        let activity = NSUserActivity(activityType: "com.sighmon.SpaceXTV.watchYouTube")
        activity.title = broadcast.title
        activity.webpageURL = broadcast.sourceURL
        activity.isEligibleForHandoff = true
        activity.becomeCurrent()
        handoffActivity = activity
        status = "YouTube is not installed on this device."
    }

    private var youtubeAppURLs: [URL] {
        guard let videoID = broadcast.sourceURL.youtubeVideoID else { return [] }

        return [
            URL(string: "youtube://www.youtube.com/watch?v=\(videoID)"),
            URL(string: "youtube://watch?v=\(videoID)"),
            URL(string: "vnd.youtube://\(videoID)")
        ].compactMap { $0 }
    }

    @MainActor
    private func open(
        _ url: URL,
        options: [UIApplication.OpenExternalURLOptionsKey: Any] = [:]
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: options) { success in
                continuation.resume(returning: success)
            }
        }
    }
}

private extension URL {
    var youtubeVideoID: String? {
        if host?.lowercased() == "youtu.be" {
            return pathComponents.dropFirst().first
        }

        guard host?.lowercased().contains("youtube.com") == true else {
            return nil
        }

        return URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "v" }?
            .value
    }
}
