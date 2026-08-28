import SwiftUI
import UIKit

struct TelevisionDisplayMetrics: Equatable {
    var isEnabled = false
    var scale: CGFloat = 1

    func scaled(_ value: CGFloat) -> CGFloat {
        isEnabled ? value * scale : value
    }
}

private struct TelevisionDisplayMetricsKey: EnvironmentKey {
    static let defaultValue = TelevisionDisplayMetrics()
}

extension EnvironmentValues {
    var televisionDisplayMetrics: TelevisionDisplayMetrics {
        get { self[TelevisionDisplayMetricsKey.self] }
        set { self[TelevisionDisplayMetricsKey.self] = newValue }
    }
}

enum TelevisionTextStyle {
    case title1
    case title2
    case title3
    case headline
    case callout
    case body
    case caption
    case caption2

    var pointSize: CGFloat {
        switch self {
        case .title1: 76
        case .title2: 57
        case .title3: 48
        case .headline: 38
        case .callout: 31
        case .body: 29
        case .caption: 25
        case .caption2: 23
        }
    }
}

private struct TelevisionFontModifier: ViewModifier {
    @Environment(\.televisionDisplayMetrics) private var metrics
    let standard: Font
    let style: TelevisionTextStyle
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(
            metrics.isEnabled
                ? .system(size: style.pointSize * metrics.scale, weight: weight, design: design)
                : standard
        )
    }
}

extension View {
    func televisionFont(
        _ standard: Font,
        style: TelevisionTextStyle,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(TelevisionFontModifier(standard: standard, style: style, weight: weight, design: design))
    }
}

struct RootView: View {
    @EnvironmentObject private var navigation: AppNavigationState
    @Environment(\.controlSize) private var controlSize
    var isExternalDisplay = false
    var externalDisplayScale: CGFloat = 1

    var body: some View {
        ZStack {
            NavigationStack {
                BroadcastBrowserView(
                    selectedBroadcast: $navigation.selectedBroadcast,
                    selectedGallery: $navigation.selectedGallery,
                    selectedCollection: $navigation.selectedCollection,
                    showsSettings: $navigation.showsSettings
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(item: $navigation.selectedBroadcast) { broadcast in
#if os(tvOS)
                        if broadcast.sourceKind == .youtube {
                            YouTubeLaunchScreen(broadcast: broadcast)
                        } else {
                            PlayerScreen(broadcast: broadcast)
                        }
#else
                        if broadcast.sourceKind == .youtube {
                            if isExternalDisplay {
                                Color.black.ignoresSafeArea()
                            } else {
                                YouTubeLaunchScreen(broadcast: broadcast)
                            }
                        } else if isExternalDisplay {
                            PlayerScreen(broadcast: broadcast, publishesExternalControls: true)
                        } else if navigation.isExternalDisplayConnected {
                            ExternalPlaybackStatusView(broadcast: broadcast)
                        } else {
                            PlayerScreen(broadcast: broadcast)
                        }
#endif
                    }
#if os(tvOS)
                    .navigationDestination(item: $navigation.selectedGallery) { gallery in
                        GalleryScreen(gallery: gallery)
                    }
#endif
                    .navigationDestination(item: $navigation.selectedCollection) { collection in
                        MediaCollectionScreen(collection: collection)
                    }
                    .navigationDestination(isPresented: $navigation.showsSettings) {
                        SettingsView()
                    }
            }
            .id(isExternalDisplay ? navigation.externalPlaybackPresentationGeneration : 0)
#if !os(tvOS)
            if let selectedGallery = navigation.selectedGallery {
                GalleryScreen(gallery: selectedGallery) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        navigation.selectedGallery = nil
                    }
                }
                .transition(.move(edge: .trailing))
                .zIndex(1)
            }
#endif
        }
#if !os(tvOS)
        .animation(.easeInOut(duration: 0.28), value: navigation.selectedGallery?.id)
#endif
        .environment(
            \.televisionDisplayMetrics,
            TelevisionDisplayMetrics(
                isEnabled: isExternalDisplay,
                scale: isExternalDisplay ? externalDisplayScale : 1
            )
        )
        .controlSize(isExternalDisplay ? .extraLarge : controlSize)
    }
}

#if !os(tvOS)
private struct ExternalPlaybackStatusView: View {
    @EnvironmentObject private var playback: ExternalPlaybackController
    @EnvironmentObject private var navigation: AppNavigationState
    let broadcast: Broadcast
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false
    @GestureState private var dismissalOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Image(systemName: "airplayvideo")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text(playback.title.isEmpty ? broadcast.title : playback.title)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)

                    HStack(spacing: 8) {
                        if playback.isBuffering || !playback.isAvailable {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(playbackStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 10) {
                    Slider(
                        value: Binding(
                            get: { displayedTime },
                            set: { value in
                                scrubPosition = value
                                isScrubbing = true
                            }
                        ),
                        in: sliderRange,
                        onEditingChanged: { editing in
                            if editing {
                                scrubPosition = displayedTime
                            } else {
                                playback.seek(to: scrubPosition)
                                isScrubbing = false
                            }
                        }
                    )
                    .disabled(!playback.canSeek)

                    HStack {
                        Text(formattedTime(displayedTime - playback.seekableStart))
                        Spacer()
                        Text(formattedTime(playback.seekableEnd - playback.seekableStart))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                Button {
                    playback.togglePlayback()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 60, height: 60)
                        .background(.white, in: Circle())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(!playback.isAvailable)
                .opacity(playback.isAvailable ? 1 : 0.45)
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 32)
            .padding(.vertical, 48)
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(.white.opacity(0.34))
                .frame(width: 36, height: 5)
                .padding(.top, 9)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .topLeading) {
            Button {
                closePlayer()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .contentShape(Circle())
            .padding(.leading, 16)
            .padding(.top, 12)
            .accessibilityLabel("Close player")
        }
        .offset(y: dismissalOffset)
        .scaleEffect(1 - min(dismissalOffset / 1_500, 0.04))
        .simultaneousGesture(dismissalGesture)
        .accessibilityAction(.escape) {
            closePlayer()
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var dismissalGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($dismissalOffset) { value, offset, _ in
                guard !isScrubbing,
                      value.translation.height > 0,
                      value.translation.height > abs(value.translation.width) * 1.25 else {
                    return
                }
                offset = value.translation.height
            }
            .onEnded { value in
                guard !isScrubbing,
                      value.translation.height > 0,
                      value.translation.height > abs(value.translation.width) * 1.25 else {
                    return
                }

                if value.translation.height > 120 || value.predictedEndTranslation.height > 240 {
                    closePlayer()
                }
            }
    }

    private func closePlayer() {
        playback.stopAndClear()
        withAnimation(.easeOut(duration: 0.2)) {
            navigation.dismissPlayer()
        }
    }

    private var sliderRange: ClosedRange<Double> {
        let start = playback.seekableStart
        return start ... max(playback.seekableEnd, start + 1)
    }

    private var displayedTime: Double {
        let time = isScrubbing ? scrubPosition : playback.currentTime
        return min(max(time, playback.seekableStart), playback.seekableEnd)
    }

    private var playbackStatus: String {
        if !playback.isAvailable { return "Preparing the external display" }
        if playback.isBuffering { return "Buffering on the external display" }
        return "Playing on the external display"
    }

    private func formattedTime(_ time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "--:--" }
        let totalSeconds = Int(time.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
#endif

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
