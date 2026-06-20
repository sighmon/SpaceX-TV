import AVKit
import SwiftUI

@MainActor
final class PlayerViewModel: ObservableObject {
    enum State: Equatable {
        case resolving
        case ready(URL, String, Int, Double?)
        case failed(String)
    }

    @Published private(set) var state: State = .resolving
    @Published private(set) var debugLines: [String] = []
    private let broadcast: Broadcast
    private var hasStarted = false
    private var playbackGeneration = 0
    private var streamRefreshCount = 0
    private var lastStreamRefreshDate: Date?
    private var isRefreshingStream = false
    private var usedFallbackStreamURLs = Set<URL>()

    init(broadcast: Broadcast) {
        self.broadcast = broadcast
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        state = .resolving
        debugLines = [
            "Status: \(broadcast.sourceURL.absoluteString)",
            "Stored stream: \(broadcast.streamURL?.absoluteString ?? "none")",
            "Fallback stream: \(broadcast.fallbackStreamURL?.absoluteString ?? "none")",
        ]
        print("[SpaceXTV] Fallback stream: \(broadcast.fallbackStreamURL?.absoluteString ?? "none")")
        do {
            let resolved = try await BroadcastResolver().resolve(broadcast)
            debugLines.append("Resolved stream: \(resolved.streamURL.absoluteString)")
            await preflight(resolved.streamURL)
            state = .ready(resolved.streamURL, videoPlayerTitle(resolved.title ?? broadcast.title), playbackGeneration, nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            debugLines.append("Resolve failed: \(message)")
            state = .failed(message)
        }
    }

    func appendPlayerDebug(_ line: String) {
        log(line)
    }

    var alternateStreamDescription: String? {
        guard let currentStreamURL,
              let alternateURL = alternateStreamURL(for: currentStreamURL),
              !usedFallbackStreamURLs.contains(alternateURL) else {
            return nil
        }
        return alternateURL.pathExtension.lowercased() == "m3u8" ? "HLS" : "MP4"
    }

    func keepWaitingForCurrentStream() {
        log("User chose to keep waiting for the current stream")
    }

    func refreshStreamAfterPlaybackFailure(resumePosition: Double?) async {
        guard !isRefreshingStream else {
            log("Skipping stream refresh: refresh already in progress")
            return
        }
        if let failedURL = currentStreamURL,
           let fallbackURL = alternateStreamURL(for: failedURL),
           !usedFallbackStreamURLs.contains(fallbackURL) {
            usedFallbackStreamURLs.insert(fallbackURL)
            playbackGeneration += 1
            let title = videoPlayerTitle(currentTitle ?? broadcast.title)
            log("Playback failed; switching format: \(fallbackURL.absoluteString)")
            state = .ready(fallbackURL, title, playbackGeneration, resumePosition)
            Task { await preflight(fallbackURL) }
            return
        }

        if let failedURL = currentStreamURL {
            log("No unused alternate format for: \(failedURL.absoluteString)")
        }

        if broadcast.fallbackStreamURL != nil {
            let message = "Both available playback formats stalled."
            log(message)
            state = .failed(message)
            return
        }

        guard canRefreshStream else {
            log("Skipping stream refresh: refresh limit reached")
            return
        }

        isRefreshingStream = true
        defer { isRefreshingStream = false }
        streamRefreshCount += 1
        lastStreamRefreshDate = Date()
        log("Refreshing stream after playback failure at \(formattedTime(resumePosition))")

        do {
            let resolved = try await BroadcastResolver().resolve(broadcast)
            playbackGeneration += 1
            log("Refreshed stream: \(resolved.streamURL.absoluteString)")
            state = .ready(resolved.streamURL, videoPlayerTitle(resolved.title ?? broadcast.title), playbackGeneration, resumePosition)
            Task { await preflight(resolved.streamURL) }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log("Stream refresh failed: \(message)")
            state = .failed(message)
        }
    }

    private func log(_ line: String) {
        debugLines.append(line)
        print("[SpaceXTV] \(line)")
    }

    private var canRefreshStream: Bool {
        guard streamRefreshCount < 3 else { return false }
        guard let lastStreamRefreshDate else { return true }
        return Date().timeIntervalSince(lastStreamRefreshDate) > 20
    }

    private var currentStreamURL: URL? {
        if case .ready(let url, _, _, _) = state {
            return url
        }
        return nil
    }

    private var currentTitle: String? {
        if case .ready(_, let title, _, _) = state {
            return title
        }
        return nil
    }

    private func preflight(_ streamURL: URL) async {
        let isPlaylist = streamURL.pathExtension.lowercased() == "m3u8"
        var request = URLRequest(url: streamURL)
        request.httpMethod = isPlaylist ? "GET" : "HEAD"
        request.setValue("Mozilla/5.0 AppleTV SpaceXTV/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue(playbackReferer(for: streamURL), forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? -1
            let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            let contentLength = httpResponse?.value(forHTTPHeaderField: "Content-Length") ?? "unknown"
            log("\(isPlaylist ? "HLS" : "Stream") preflight HTTP \(statusCode), \(data.count) bytes")
            log("Preflight headers: type \(contentType), length \(contentLength)")

            if isPlaylist, let preview = String(data: data.prefix(120), encoding: .utf8) {
                log("HLS preview: \(preview.replacingOccurrences(of: "\n", with: " "))")
            }
        } catch {
            log("\(isPlaylist ? "HLS" : "Stream") preflight failed: \(error.localizedDescription)")
        }
    }

    private func formattedTime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "unknown time" }
        return "\(Int(seconds))s"
    }

    private func videoPlayerTitle(_ title: String) -> String {
        let withoutLinks = title.replacingOccurrences(
            of: #"(?i)\b(?:https?://|www\.)\S+"#,
            with: "",
            options: .regularExpression
        )
        let cleaned = withoutLinks
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return cleaned.isEmpty ? "SpaceX Broadcast" : cleaned
    }

    private func spaceXHLSFallbackURL(for streamURL: URL) -> URL? {
        guard streamURL.pathExtension.lowercased() == "mp4",
              streamURL.host?.lowercased().contains("content.spacex.com") == true else {
            return nil
        }

        let filename = streamURL.deletingPathExtension().lastPathComponent
        let suffixes = ["_4K", "_1080P", "_720P"]
        guard let suffix = suffixes.first(where: { filename.hasSuffix($0) }) else {
            return nil
        }

        let baseName = String(filename.dropLast(suffix.count))
        let directoryURL = streamURL
            .deletingLastPathComponent()
            .appendingPathComponent(baseName, isDirectory: true)
        return directoryURL
            .appendingPathComponent(baseName)
            .appendingPathExtension("m3u8")
    }

    private func alternateStreamURL(for streamURL: URL) -> URL? {
        if let fallbackURL = broadcast.fallbackStreamURL {
            return fallbackURL == streamURL ? nil : fallbackURL
        }
        return spaceXHLSFallbackURL(for: streamURL)
    }
}

private func playbackReferer(for streamURL: URL) -> String {
    guard let host = streamURL.host?.lowercased() else {
        return "https://x.com/"
    }

    if host.contains("spacex.com") || host.contains("azureedge.us") {
        return "https://www.spacex.com/"
    }

    if host.contains("pscp.tv") || host.contains("periscope.tv") {
        return "https://www.periscope.tv/"
    }

    return "https://x.com/"
}

struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BroadcastLibrary
    @StateObject private var model: PlayerViewModel
    @State private var showsPlaybackBackButton = false
    @State private var isPlaybackPaused = false
    @State private var backButtonHideTask: Task<Void, Never>?

    init(broadcast: Broadcast) {
        _model = StateObject(wrappedValue: PlayerViewModel(broadcast: broadcast))
    }

    var body: some View {
        Group {
            switch model.state {
            case .resolving:
                ProgressView("Resolving stream...")
                    .font(.title2)
                    .task {
                        await model.start()
                    }
            case .ready(let url, let title, let playbackGeneration, let resumePosition):
                ZStack(alignment: .bottomLeading) {
                    TVPlayerView(
                        streamURL: url,
                        title: title,
                        playbackGeneration: playbackGeneration,
                        resumePosition: resumePosition,
                        alternateStreamDescription: model.alternateStreamDescription,
                        onTapped: {
                            showPlaybackBackButton()
                        },
                        onPlaybackPausedChanged: { isPaused in
                            isPlaybackPaused = isPaused
                            if isPaused {
                                showPlaybackBackButton(autoHide: false)
                            } else {
                                hidePlaybackBackButtonAfterDelay()
                            }
                        },
                        onEnded: {
                            dismiss()
                        },
                        onKeepWaiting: {
                            model.keepWaitingForCurrentStream()
                        },
                        onPlaybackFailure: { resumePosition in
                            Task {
                                await model.refreshStreamAfterPlaybackFailure(resumePosition: resumePosition)
                            }
                        },
                        onFullScreenDismissed: {
                            dismiss()
                        }
                    ) { line in
                        model.appendPlayerDebug(line)
                    }
                    .id(playbackGeneration)
                    .ignoresSafeArea()

                    if showsPlaybackBackButton || isPlaybackPaused {
                        playbackBackButton
                            .padding(.top, 18)
                            .padding(.leading, 22)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .transition(.opacity)
                    }

                    if library.showsPlayerDebugOverlay {
                        PlayerDebugOverlay(lines: model.debugLines)
                            .padding(40)
                    }
                }
                // .navigationTitle(title)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 24) {
                    ContentUnavailableView(
                        "Stream unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                    if library.showsPlayerDebugOverlay {
                        PlayerDebugOverlay(lines: model.debugLines)
                    }
                }
                .padding(60)
            }
        }
        .toolbar(hidesNavigationBar ? .hidden : .automatic, for: .navigationBar)
#if !os(tvOS)
        .statusBarHidden(hidesStatusBar)
#endif
        .animation(.easeOut(duration: 0.18), value: showsPlaybackBackButton)
        .animation(.easeOut(duration: 0.18), value: isPlaybackPaused)
        .onDisappear {
            backButtonHideTask?.cancel()
        }
    }

    private var hidesNavigationBar: Bool {
        if case .ready = model.state {
            return true
        }
        return false
    }

#if !os(tvOS)
    private var hidesStatusBar: Bool {
        guard case .ready = model.state else { return false }
        return !showsPlaybackBackButton && !isPlaybackPaused
    }
#endif

    private var playbackBackButton: some View {
        Button {
            dismiss()
        } label: {
            Label("Back", systemImage: "chevron.backward")
                .labelStyle(.iconOnly)
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 64, height: 64)
                .background(.black.opacity(0.58), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel("Back")
    }

    private func showPlaybackBackButton(autoHide: Bool = true) {
        showsPlaybackBackButton = true
        backButtonHideTask?.cancel()
        guard autoHide else { return }
        hidePlaybackBackButtonAfterDelay()
    }

    private func hidePlaybackBackButtonAfterDelay() {
        backButtonHideTask?.cancel()
        backButtonHideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if !isPlaybackPaused {
                    withAnimation(.easeOut(duration: 0.18)) {
                        showsPlaybackBackButton = false
                    }
                }
            }
        }
    }
}

struct TVPlayerView: UIViewControllerRepresentable {
    var streamURL: URL
    var title: String
    var playbackGeneration: Int
    var resumePosition: Double?
    var alternateStreamDescription: String?
    var onTapped: () -> Void
    var onPlaybackPausedChanged: (Bool) -> Void
    var onEnded: () -> Void
    var onKeepWaiting: () -> Void
    var onPlaybackFailure: (Double?) -> Void
    var onFullScreenDismissed: () -> Void
    var onDebug: (String) -> Void

    func makeUIViewController(context: Context) -> PlayerHostViewController {
        let host = PlayerHostViewController()
        host.onFullScreenDismissed = onFullScreenDismissed
        let controller = host.playerController
        context.coordinator.playerController = controller
        context.coordinator.alternateStreamDescription = alternateStreamDescription
        context.coordinator.lastPlaybackGeneration = playbackGeneration
        context.coordinator.configureAudioSession()
        controller.player = context.coordinator.makePlayer(for: streamURL, title: title)
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
#if !os(tvOS)
        host.isModalInPresentation = true
        host.shouldReportFullScreenDismissal = {
            !context.coordinator.isPictureInPicturePresentationActive
        }
        context.coordinator.hostController = host
        controller.delegate = context.coordinator
        controller.isModalInPresentation = true
        controller.allowsPictureInPicturePlayback = AVPictureInPictureController.isPictureInPictureSupported()
        if #available(iOS 14.2, *) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
        }
        controller.exitsFullScreenWhenPlaybackEnds = true
#endif
#if os(tvOS)
        context.coordinator.installTapRecognizer(on: controller.view)
#else
        context.coordinator.installPinchRecognizer(on: controller.view, playerController: controller)
        context.coordinator.installVideoSurfaceDragBlockers(on: controller.view, playerController: controller)
#endif
        if let player = controller.player {
            startPlayback(player, at: resumePosition)
        }
        return host
    }

    func updateUIViewController(_ host: PlayerHostViewController, context: Context) {
        let controller = host.playerController
        context.coordinator.onTapped = onTapped
        context.coordinator.onPlaybackPausedChanged = onPlaybackPausedChanged
        context.coordinator.onKeepWaiting = onKeepWaiting
        context.coordinator.onPlaybackFailure = onPlaybackFailure
        context.coordinator.alternateStreamDescription = alternateStreamDescription
        host.onFullScreenDismissed = onFullScreenDismissed
#if !os(tvOS)
        host.shouldReportFullScreenDismissal = {
            !context.coordinator.isPictureInPicturePresentationActive
        }
        context.coordinator.hostController = host
        controller.delegate = context.coordinator
#endif
        context.coordinator.updatePlaybackTitle(title, item: controller.player?.currentItem)
        let currentURL = (controller.player?.currentItem?.asset as? AVURLAsset)?.url

        guard currentURL != streamURL || context.coordinator.lastPlaybackGeneration != playbackGeneration else { return }

        context.coordinator.lastPlaybackGeneration = playbackGeneration
        let oldPlayer = controller.player
        let player = context.coordinator.makePlayer(for: streamURL, title: title)
        controller.player = player
        context.coordinator.stop(oldPlayer)
        startPlayback(player, at: resumePosition)
    }

    private func startPlayback(_ player: AVPlayer, at resumePosition: Double?) {
        guard let resumePosition, resumePosition.isFinite, resumePosition > 0 else {
            player.play()
            return
        }

        let target = CMTime(seconds: resumePosition, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        onDebug("Seeking refreshed stream to \(Int(resumePosition))s")
        player.seek(
            to: target,
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { finished in
            guard finished else {
                onDebug("Resume seek was cancelled")
                return
            }
            onDebug("Resuming refreshed stream at \(Int(resumePosition))s")
            player.play()
        }
    }

    static func dismantleUIViewController(_ host: PlayerHostViewController, coordinator: Coordinator) {
        let controller = host.playerController
        if controller.presentingViewController != nil {
            controller.dismiss(animated: false)
        }
        coordinator.stop(controller.player)
        controller.player = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            playbackTitle: title,
            onTapped: onTapped,
            onPlaybackPausedChanged: onPlaybackPausedChanged,
            onEnded: onEnded,
            onKeepWaiting: onKeepWaiting,
            onPlaybackFailure: onPlaybackFailure,
            onDebug: onDebug
        )
    }

    final class PlayerHostViewController: UIViewController {
        let playerController = AVPlayerViewController()
        private var hasPresentedFullScreenPlayer = false
        private var hasReportedFullScreenDismissal = false
        private var isPlayerEmbedded = false
        var onFullScreenDismissed: (() -> Void)?
#if !os(tvOS)
        var shouldReportFullScreenDismissal: (() -> Bool)?
#endif

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
#if os(tvOS)
            embedPlayerIfNeeded()
#endif
        }

#if !os(tvOS)
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)

            guard !hasPresentedFullScreenPlayer else {
                guard !hasReportedFullScreenDismissal else { return }
                guard shouldReportFullScreenDismissal?() ?? true else { return }
                hasReportedFullScreenDismissal = true
                onFullScreenDismissed?()
                return
            }

            hasPresentedFullScreenPlayer = true
            playerController.modalPresentationStyle = .fullScreen
            playerController.isModalInPresentation = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.presentedViewController == nil else { return }
                self.present(self.playerController, animated: false)
            }
        }
#endif

        private func embedPlayerIfNeeded() {
            guard !isPlayerEmbedded, playerController.parent == nil else { return }
            addChild(playerController)
            view.addSubview(playerController.view)
            playerController.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                playerController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                playerController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                playerController.view.topAnchor.constraint(equalTo: view.topAnchor),
                playerController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            playerController.didMove(toParent: self)
            isPlayerEmbedded = true
        }
    }

    final class Coordinator: NSObject {
        var lastPlaybackGeneration = 0
        var onTapped: () -> Void
        var onPlaybackPausedChanged: (Bool) -> Void
        var onKeepWaiting: () -> Void
        var onPlaybackFailure: (Double?) -> Void
        var alternateStreamDescription: String?
        weak var playerController: AVPlayerViewController?
        private var playbackTitle: String
        private var displayedResolution: String?
        private let onEnded: () -> Void
        private let onDebug: (String) -> Void
        private var statusObservation: NSKeyValueObservation?
        private var playbackObservation: NSKeyValueObservation?
        private weak var observedPlayer: AVPlayer?
        private var endObserver: NSObjectProtocol?
        private var stallObserver: NSObjectProtocol?
        private var accessLogObserver: NSObjectProtocol?
        private var stallRecoveryTask: Task<Void, Never>?
        private weak var streamChoiceAlert: UIAlertController?
        private weak var tapRecognizer: UITapGestureRecognizer?
#if !os(tvOS)
        weak var hostController: PlayerHostViewController?
        private var isPictureInPictureStarting = false
        private var isPictureInPictureActive = false
        private var isPictureInPictureRestoring = false
        private weak var pinchRecognizer: UIPinchGestureRecognizer?
        private weak var videoSurfacePanBlocker: UIPanGestureRecognizer?
        private weak var videoSurfaceLongPressBlocker: UILongPressGestureRecognizer?
        private weak var pinchPlayerController: AVPlayerViewController?
        private weak var interactionPlayerController: AVPlayerViewController?
        private var hasRequestedPanDismiss = false
        var isPictureInPicturePresentationActive: Bool {
            isPictureInPictureStarting || isPictureInPictureActive || isPictureInPictureRestoring
        }
#endif

        init(
            playbackTitle: String,
            onTapped: @escaping () -> Void,
            onPlaybackPausedChanged: @escaping (Bool) -> Void,
            onEnded: @escaping () -> Void,
            onKeepWaiting: @escaping () -> Void,
            onPlaybackFailure: @escaping (Double?) -> Void,
            onDebug: @escaping (String) -> Void
        ) {
            self.playbackTitle = playbackTitle
            self.onTapped = onTapped
            self.onPlaybackPausedChanged = onPlaybackPausedChanged
            self.onEnded = onEnded
            self.onKeepWaiting = onKeepWaiting
            self.onPlaybackFailure = onPlaybackFailure
            self.onDebug = onDebug
        }

        deinit {
            stallRecoveryTask?.cancel()
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            if let accessLogObserver {
                NotificationCenter.default.removeObserver(accessLogObserver)
            }
            if let stallObserver {
                NotificationCenter.default.removeObserver(stallObserver)
            }
            statusObservation?.invalidate()
            playbackObservation?.invalidate()
        }

        func installTapRecognizer(on view: UIView) {
            guard tapRecognizer == nil else { return }
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            recognizer.cancelsTouchesInView = false
            view.addGestureRecognizer(recognizer)
            tapRecognizer = recognizer
        }

        @objc private func handleTap() {
            onTapped()
        }

#if !os(tvOS)
        func installPinchRecognizer(on view: UIView, playerController: AVPlayerViewController) {
            pinchPlayerController = playerController
            guard pinchRecognizer == nil else { return }
            let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            recognizer.cancelsTouchesInView = false
            view.addGestureRecognizer(recognizer)
            pinchRecognizer = recognizer
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            if recognizer.scale > 1.08 {
                pinchPlayerController?.videoGravity = .resizeAspectFill
                onDebug("Pinch zoom: fill")
            } else if recognizer.scale < 0.92 {
                pinchPlayerController?.videoGravity = .resizeAspect
                onDebug("Pinch zoom: fit")
            }
        }

        func installVideoSurfaceDragBlockers(on view: UIView, playerController: AVPlayerViewController) {
            interactionPlayerController = playerController
            guard videoSurfacePanBlocker == nil, videoSurfaceLongPressBlocker == nil else { return }

            let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleBlockedVideoSurfacePan(_:)))
            panRecognizer.maximumNumberOfTouches = 1
            panRecognizer.cancelsTouchesInView = true
            panRecognizer.delegate = self
            view.addGestureRecognizer(panRecognizer)

            let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleBlockedVideoSurfaceLongPress(_:)))
            longPressRecognizer.minimumPressDuration = 0.18
            longPressRecognizer.allowableMovement = 12
            longPressRecognizer.numberOfTouchesRequired = 1
            longPressRecognizer.cancelsTouchesInView = true
            longPressRecognizer.delegate = self
            view.addGestureRecognizer(longPressRecognizer)

            videoSurfacePanBlocker = panRecognizer
            videoSurfaceLongPressBlocker = longPressRecognizer
        }

        @objc private func handleBlockedVideoSurfacePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                hasRequestedPanDismiss = false
                convertVideoSurfaceDragToTap()
                onDebug("Blocked player surface pan")
            case .changed:
                requestDismissIfNeeded(for: recognizer)
            case .ended, .cancelled, .failed:
                hasRequestedPanDismiss = false
            default:
                break
            }
        }

        @objc private func handleBlockedVideoSurfaceLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            convertVideoSurfaceDragToTap()
            onDebug("Blocked player surface long press")
        }

        private func convertVideoSurfaceDragToTap() {
            onTapped()
            guard let controller = interactionPlayerController else { return }
            controller.showsPlaybackControls = false
            DispatchQueue.main.async {
                controller.showsPlaybackControls = true
            }
        }

        private func requestDismissIfNeeded(for recognizer: UIPanGestureRecognizer) {
            guard !hasRequestedPanDismiss,
                  let view = recognizer.view else { return }

            let translation = recognizer.translation(in: view)
            let velocity = recognizer.velocity(in: view)
            guard translation.y > 120,
                  translation.y > abs(translation.x) * 1.35,
                  velocity.y > 250 else { return }

            hasRequestedPanDismiss = true
            onDebug("Dismissed player from downward pan")
            dismissPresentedPlayer()
        }

        private func dismissPresentedPlayer() {
            guard let hostController else { return }
            let completeDismissal = {
                hostController.onFullScreenDismissed?()
            }

            if let presentedViewController = hostController.presentedViewController {
                presentedViewController.dismiss(animated: true) {
                    completeDismissal()
                }
            } else if hostController.playerController.presentingViewController != nil {
                hostController.playerController.dismiss(animated: true) {
                    completeDismissal()
                }
            } else {
                completeDismissal()
            }
        }
#endif

        func makePlayer(for streamURL: URL, title: String) -> AVPlayer {
            onDebug("Creating player for: \(streamURL.absoluteString)")
            playbackTitle = title
            displayedResolution = initialResolutionDescription(for: streamURL)
            let headers = [
                "User-Agent": "Mozilla/5.0 AppleTV SpaceXTV/1.0",
                "Referer": referer(for: streamURL),
            ]
            let asset = AVURLAsset(
                url: streamURL,
                options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
            )
            let item = AVPlayerItem(asset: asset)
            item.preferredPeakBitRate = 0
            item.preferredForwardBufferDuration = streamURL.pathExtension.lowercased() == "mp4" ? 5 : 20
            if #available(tvOS 11.0, iOS 11.0, *) {
                item.preferredMaximumResolution = CGSize(width: 3840, height: 2160)
            }
            applyExternalMetadata(to: item)
            onDebug("Player preferences: peakBitRate \(Int(item.preferredPeakBitRate)), forwardBuffer \(Int(item.preferredForwardBufferDuration))s, maxResolution \(Int(item.preferredMaximumResolution.width))x\(Int(item.preferredMaximumResolution.height))")
            observe(item)
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = true
            observe(player)
            return player
        }

        func configureAudioSession() {
#if !os(tvOS)
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
                onDebug("Audio session configured for Picture in Picture")
            } catch {
                onDebug("Audio session setup failed: \(error.localizedDescription)")
            }
#endif
        }

        func stop(_ player: AVPlayer?) {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
        }

        func updatePlaybackTitle(_ title: String, item: AVPlayerItem?) {
            guard playbackTitle != title else { return }
            playbackTitle = title
            if let item {
                applyExternalMetadata(to: item)
            }
        }

        private func referer(for streamURL: URL) -> String {
            playbackReferer(for: streamURL)
        }

        private func observe(_ player: AVPlayer) {
            observedPlayer = player
            playbackObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
                Task { @MainActor in
                    self?.onPlaybackPausedChanged(player.timeControlStatus == .paused)
                }
            }
        }

        private func observe(_ item: AVPlayerItem) {
            stallRecoveryTask?.cancel()
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            if let stallObserver {
                NotificationCenter.default.removeObserver(stallObserver)
            }
            if let accessLogObserver {
                NotificationCenter.default.removeObserver(accessLogObserver)
            }

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.onDebug("AVPlayerItem reached end")
                self?.onEnded()
            }

            stallObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemPlaybackStalled,
                object: item,
                queue: .main
            ) { [weak self, weak item] _ in
                self?.onDebug("AVPlayerItem playback stalled")
                guard let self, let item else { return }
                let stalledAt = item.currentTime().seconds
                self.stallRecoveryTask?.cancel()
                self.stallRecoveryTask = Task { @MainActor [weak self, weak item] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled, let self, let item else { return }
                    guard self.observedPlayer?.timeControlStatus != .paused else {
                        self.onDebug("Stall recovery cancelled while playback is paused")
                        return
                    }
                    let currentTime = item.currentTime().seconds
                    if stalledAt.isFinite,
                       currentTime.isFinite,
                       currentTime >= stalledAt + 1 {
                        self.onDebug("Playback recovered from stall")
                        return
                    }
                    self.onDebug("Playback remained stalled; asking whether to switch stream format")
                    self.presentStreamChoice(resumePosition: currentTime.isFinite ? currentTime : nil)
                }
            }

            accessLogObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemNewAccessLogEntry,
                object: item,
                queue: .main
            ) { [weak self, weak item] _ in
                guard let event = item?.accessLog()?.events.last else { return }
                if let item, let resolution = self?.resolutionDescription(from: event.uri) {
                    self?.updateDisplayedResolution(resolution, item: item)
                }
                self?.onDebug(
                    "Access log update: indicated \(Int(event.indicatedBitrate)), observed \(Int(event.observedBitrate)), requests \(event.numberOfMediaRequests), bytes \(event.numberOfBytesTransferred), uri \(event.uri ?? "unknown")"
                )
            }

            statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                Task { @MainActor in
                    switch item.status {
                    case .unknown:
                        self?.onDebug("AVPlayerItem status: unknown")
                    case .readyToPlay:
                        self?.onDebug("AVPlayerItem status: ready")
                        if let event = item.accessLog()?.events.last {
                            if let resolution = self?.resolutionDescription(from: event.uri) {
                                self?.updateDisplayedResolution(resolution, item: item)
                            }
                            self?.onDebug("Access log: bitrate \(Int(event.indicatedBitrate)), segments \(event.numberOfMediaRequests)")
                        }
                    case .failed:
                        self?.onDebug("AVPlayerItem status: failed")
                        if let error = item.error {
                            self?.onDebug("Player error: \(error.localizedDescription)")
                        }
                        if let event = item.errorLog()?.events.last {
                            self?.onDebug("Error log: \(event.errorStatusCode) \(event.errorComment ?? "")")
                        }
                        self?.onPlaybackFailure(item.currentTime().seconds)
                    @unknown default:
                        self?.onDebug("AVPlayerItem status: unknown future status")
                    }
                }
            }
        }

        private func presentStreamChoice(resumePosition: Double?) {
            guard streamChoiceAlert == nil else {
                onDebug("Stream choice is already visible")
                return
            }
            guard let alternateStreamDescription else {
                onDebug("No alternate stream is available; refreshing current stream")
                onPlaybackFailure(resumePosition)
                return
            }
            guard let playerController else {
                onDebug("Could not present stream choice: player controller unavailable")
                return
            }

            let alert = UIAlertController(
                title: "Playback is still buffering",
                message: "Keep waiting for the current stream, or switch playback to \(alternateStreamDescription).",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Keep Waiting", style: .cancel) { [weak self] _ in
                self?.onDebug("User chose to keep waiting for the current stream")
                self?.onKeepWaiting()
            })
            alert.addAction(UIAlertAction(title: "Switch to \(alternateStreamDescription)", style: .default) { [weak self] _ in
                self?.onDebug("User chose to switch stream format")
                self?.onPlaybackFailure(resumePosition)
            })

            streamChoiceAlert = alert
            onDebug("Presenting stream choice over native player")
            playerController.present(alert, animated: true)
        }

        private func applyExternalMetadata(to item: AVPlayerItem) {
            var metadata: [AVMetadataItem] = [
                metadataItem(
                    identifier: .commonIdentifierTitle,
                    value: playbackTitle
                )
            ]

            if let displayedResolution {
                metadata.append(
                    metadataItem(
                        identifier: .iTunesMetadataTrackSubTitle,
                        value: displayedResolution
                    )
                )
            }

            item.externalMetadata = metadata
        }

        private func metadataItem(identifier: AVMetadataIdentifier, value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item.copy() as! AVMetadataItem
        }

        private func updateDisplayedResolution(_ resolution: String, item: AVPlayerItem) {
            guard displayedResolution != resolution else { return }
            displayedResolution = resolution
            applyExternalMetadata(to: item)
            onDebug("Updated native player resolution: \(resolution)")
        }

        private func initialResolutionDescription(for streamURL: URL) -> String {
            resolutionDescription(from: streamURL.absoluteString) ?? "Auto up to 4K"
        }

        private func resolutionDescription(from uri: String?) -> String? {
            guard let uri = uri?.lowercased() else { return nil }
            if uri.contains("2160") || uri.contains("4k") || uri.contains("uhd") {
                return "4K"
            }
            if uri.contains("1080") {
                return "1080p"
            }
            if uri.contains("720") {
                return "720p"
            }
            if uri.contains("480") {
                return "480p"
            }
            if uri.contains("360") {
                return "360p"
            }
            return nil
        }
    }
}

#if !os(tvOS)
extension TVPlayerView.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === videoSurfacePanBlocker || gestureRecognizer === videoSurfaceLongPressBlocker else {
            return true
        }

        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === videoSurfacePanBlocker || gestureRecognizer === videoSurfaceLongPressBlocker,
              let view = gestureRecognizer.view else {
            return true
        }

        let point = touch.location(in: view)
        return !containsInteractiveControl(in: view, at: point)
    }

    private func containsInteractiveControl(in view: UIView, at point: CGPoint) -> Bool {
        guard !view.isHidden,
              view.alpha > 0.01,
              view.isUserInteractionEnabled,
              view.point(inside: point, with: nil) else {
            return false
        }

        for subview in view.subviews.reversed() {
            let convertedPoint = view.convert(point, to: subview)
            if containsInteractiveControl(in: subview, at: convertedPoint) {
                return true
            }
        }

        return view is UIControl
    }
}

extension TVPlayerView.Coordinator: AVPlayerViewControllerDelegate {
    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureStarting = true
        onDebug("Picture in Picture starting")
    }

    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureStarting = false
        isPictureInPictureActive = true
        onDebug("Picture in Picture started")
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isPictureInPictureStarting = false
        isPictureInPictureActive = false
        isPictureInPictureRestoring = false
        onDebug("Picture in Picture failed: \(error.localizedDescription)")
    }

    func playerViewControllerWillStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureRestoring = true
        onDebug("Picture in Picture stopping")
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureStarting = false
        isPictureInPictureActive = false
        isPictureInPictureRestoring = false
        onDebug("Picture in Picture stopped")
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        isPictureInPictureRestoring = true
        guard let hostController else {
            completionHandler(false)
            return
        }

        if hostController.presentedViewController === playerViewController {
            completionHandler(true)
            return
        }

        playerViewController.modalPresentationStyle = .fullScreen
        playerViewController.isModalInPresentation = true
        hostController.present(playerViewController, animated: true) {
            completionHandler(true)
        }
    }
}
#endif

private struct PlayerDebugOverlay: View {
    var lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Playback Debug")
                .font(.headline)
            ForEach(Array(lines.suffix(10).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(18)
        .frame(maxWidth: 1000, alignment: .leading)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
    }
}
