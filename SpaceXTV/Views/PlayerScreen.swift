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
        ]
        do {
            let resolved = try await BroadcastResolver().resolve(broadcast)
            debugLines.append("Resolved stream: \(resolved.streamURL.absoluteString)")
            await preflight(resolved.streamURL)
            state = .ready(resolved.streamURL, resolved.title ?? broadcast.title, playbackGeneration, nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            debugLines.append("Resolve failed: \(message)")
            state = .failed(message)
        }
    }

    func appendPlayerDebug(_ line: String) {
        debugLines.append(line)
        print("[SpaceXTV] \(line)")
    }

    func refreshStreamAfterPlaybackFailure(resumePosition: Double?) async {
        guard !isRefreshingStream else {
            debugLines.append("Skipping stream refresh: refresh already in progress")
            return
        }
        if let failedURL = currentStreamURL,
           let fallbackURL = spaceXHLSFallbackURL(for: failedURL),
           !usedFallbackStreamURLs.contains(fallbackURL) {
            usedFallbackStreamURLs.insert(fallbackURL)
            playbackGeneration += 1
            debugLines.append("MP4 playback failed; falling back to HLS: \(fallbackURL.absoluteString)")
            await preflight(fallbackURL)
            state = .ready(fallbackURL, currentTitle ?? broadcast.title, playbackGeneration, resumePosition)
            return
        }

        guard canRefreshStream else {
            debugLines.append("Skipping stream refresh: refresh limit reached")
            return
        }

        isRefreshingStream = true
        defer { isRefreshingStream = false }
        streamRefreshCount += 1
        lastStreamRefreshDate = Date()
        debugLines.append("Refreshing stream after playback failure at \(formattedTime(resumePosition))")

        do {
            let resolved = try await BroadcastResolver().resolve(broadcast)
            playbackGeneration += 1
            debugLines.append("Refreshed stream: \(resolved.streamURL.absoluteString)")
            await preflight(resolved.streamURL)
            state = .ready(resolved.streamURL, resolved.title ?? broadcast.title, playbackGeneration, resumePosition)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            debugLines.append("Stream refresh failed: \(message)")
            state = .failed(message)
        }
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
            debugLines.append("\(isPlaylist ? "HLS" : "Stream") preflight HTTP \(statusCode), \(data.count) bytes")
            debugLines.append("Preflight headers: type \(contentType), length \(contentLength)")

            if isPlaylist, let preview = String(data: data.prefix(120), encoding: .utf8) {
                debugLines.append("HLS preview: \(preview.replacingOccurrences(of: "\n", with: " "))")
            }
        } catch {
            debugLines.append("\(isPlaylist ? "HLS" : "Stream") preflight failed: \(error.localizedDescription)")
        }
    }

    private func formattedTime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "unknown time" }
        return "\(Int(seconds))s"
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
    @State private var showsCompletionOverlay = false
    @State private var showsPlaybackBackButton = false
    @State private var isPlaybackPaused = false
    @State private var backButtonHideTask: Task<Void, Never>?
    @State private var replayRequest = 0

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
                        replayRequest: replayRequest,
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
                            showsCompletionOverlay = true
                        },
                        onPlaybackFailure: { resumePosition in
                            Task {
                                await model.refreshStreamAfterPlaybackFailure(resumePosition: resumePosition)
                            }
                        }
                    ) { line in
                        model.appendPlayerDebug(line)
                    }
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
        .fullScreenCover(isPresented: $showsCompletionOverlay) {
            PlaybackCompleteOverlay(
                onReplay: {
                    showsCompletionOverlay = false
                    replayRequest += 1
                },
                onBack: {
                    showsCompletionOverlay = false
                    dismiss()
                }
            )
            .preferredColorScheme(.dark)
        }
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
    var replayRequest: Int
    var onTapped: () -> Void
    var onPlaybackPausedChanged: (Bool) -> Void
    var onEnded: () -> Void
    var onPlaybackFailure: (Double?) -> Void
    var onDebug: (String) -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        context.coordinator.lastPlaybackGeneration = playbackGeneration
        controller.player = context.coordinator.makePlayer(for: streamURL, title: title)
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        context.coordinator.installTapRecognizer(on: controller.view)
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.onTapped = onTapped
        context.coordinator.onPlaybackPausedChanged = onPlaybackPausedChanged
        context.coordinator.onPlaybackFailure = onPlaybackFailure
        context.coordinator.updatePlaybackTitle(title, item: controller.player?.currentItem)
        let currentURL = (controller.player?.currentItem?.asset as? AVURLAsset)?.url
        if context.coordinator.lastReplayRequest != replayRequest {
            context.coordinator.lastReplayRequest = replayRequest
            controller.player?.seek(to: .zero)
            controller.player?.play()
            onDebug("Replay requested")
            return
        }

        guard currentURL != streamURL || context.coordinator.lastPlaybackGeneration != playbackGeneration else { return }

        context.coordinator.lastPlaybackGeneration = playbackGeneration
        let oldPlayer = controller.player
        let player = context.coordinator.makePlayer(for: streamURL, title: title)
        controller.player = player
        context.coordinator.stop(oldPlayer)
        if let resumePosition, resumePosition.isFinite, resumePosition > 0 {
            player.seek(
                to: CMTime(seconds: resumePosition, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            onDebug("Resuming refreshed stream at \(Int(resumePosition))s")
        }
        player.play()
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.stop(controller.player)
        controller.player = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            playbackTitle: title,
            onTapped: onTapped,
            onPlaybackPausedChanged: onPlaybackPausedChanged,
            onEnded: onEnded,
            onPlaybackFailure: onPlaybackFailure,
            onDebug: onDebug
        )
    }

    final class Coordinator: NSObject {
        var lastReplayRequest = 0
        var lastPlaybackGeneration = 0
        var onTapped: () -> Void
        var onPlaybackPausedChanged: (Bool) -> Void
        var onPlaybackFailure: (Double?) -> Void
        private var playbackTitle: String
        private var displayedResolution: String?
        private let onEnded: () -> Void
        private let onDebug: (String) -> Void
        private var statusObservation: NSKeyValueObservation?
        private var playbackObservation: NSKeyValueObservation?
        private var endObserver: NSObjectProtocol?
        private var stallObserver: NSObjectProtocol?
        private var accessLogObserver: NSObjectProtocol?
        private weak var tapRecognizer: UITapGestureRecognizer?

        init(
            playbackTitle: String,
            onTapped: @escaping () -> Void,
            onPlaybackPausedChanged: @escaping (Bool) -> Void,
            onEnded: @escaping () -> Void,
            onPlaybackFailure: @escaping (Double?) -> Void,
            onDebug: @escaping (String) -> Void
        ) {
            self.playbackTitle = playbackTitle
            self.onTapped = onTapped
            self.onPlaybackPausedChanged = onPlaybackPausedChanged
            self.onEnded = onEnded
            self.onPlaybackFailure = onPlaybackFailure
            self.onDebug = onDebug
        }

        deinit {
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
            playbackObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
                Task { @MainActor in
                    self?.onPlaybackPausedChanged(player.timeControlStatus == .paused)
                }
            }
        }

        private func observe(_ item: AVPlayerItem) {
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
            ) { [weak self] _ in
                self?.onDebug("AVPlayerItem playback stalled")
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

private struct PlaybackCompleteOverlay: View {
    private enum FocusTarget {
        case replay
        case back
    }

    var onReplay: () -> Void
    var onBack: () -> Void
    @FocusState private var focusedTarget: FocusTarget?

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()

            HStack(spacing: 28) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.backward")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: 260, height: 88)
                }
                .buttonStyle(.borderedProminent)
                .focused($focusedTarget, equals: .back)

                Button(action: onReplay) {
                    Label("Replay", systemImage: "arrow.counterclockwise")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: 260, height: 88)
                }
                .buttonStyle(.bordered)
                .focused($focusedTarget, equals: .replay)
            }
            .padding(30)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        }
        .onAppear {
            focusedTarget = .back
        }
    }
}

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
