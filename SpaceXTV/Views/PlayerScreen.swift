import AVKit
import SwiftUI

@MainActor
final class PlayerViewModel: ObservableObject {
    enum State: Equatable {
        case resolving
        case ready(URL, String)
        case failed(String)
    }

    @Published private(set) var state: State = .resolving
    @Published private(set) var debugLines: [String] = []
    private let broadcast: Broadcast
    private var hasStarted = false

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
            state = .ready(resolved.streamURL, resolved.title ?? broadcast.title)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            debugLines.append("Resolve failed: \(message)")
            state = .failed(message)
        }
    }

    func appendPlayerDebug(_ line: String) {
        debugLines.append(line)
    }

    private func preflight(_ streamURL: URL) async {
        let isPlaylist = streamURL.pathExtension.lowercased() == "m3u8"
        var request = URLRequest(url: streamURL)
        request.httpMethod = isPlaylist ? "GET" : "HEAD"
        request.setValue("Mozilla/5.0 AppleTV SpaceXTV/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://x.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            debugLines.append("\(isPlaylist ? "HLS" : "Stream") preflight HTTP \(statusCode), \(data.count) bytes")

            if isPlaylist, let preview = String(data: data.prefix(120), encoding: .utf8) {
                debugLines.append("HLS preview: \(preview.replacingOccurrences(of: "\n", with: " "))")
            }
        } catch {
            debugLines.append("\(isPlaylist ? "HLS" : "Stream") preflight failed: \(error.localizedDescription)")
        }
    }
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
            case .ready(let url, _):
                ZStack(alignment: .bottomLeading) {
                    TVPlayerView(
                        streamURL: url,
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
    var replayRequest: Int
    var onTapped: () -> Void
    var onPlaybackPausedChanged: (Bool) -> Void
    var onEnded: () -> Void
    var onDebug: (String) -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = context.coordinator.makePlayer(for: streamURL)
        controller.showsPlaybackControls = true
        context.coordinator.installTapRecognizer(on: controller.view)
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.onTapped = onTapped
        context.coordinator.onPlaybackPausedChanged = onPlaybackPausedChanged
        let currentURL = (controller.player?.currentItem?.asset as? AVURLAsset)?.url
        if context.coordinator.lastReplayRequest != replayRequest {
            context.coordinator.lastReplayRequest = replayRequest
            controller.player?.seek(to: .zero)
            controller.player?.play()
            onDebug("Replay requested")
            return
        }

        guard currentURL != streamURL else { return }

        controller.player = context.coordinator.makePlayer(for: streamURL)
        controller.player?.play()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTapped: onTapped,
            onPlaybackPausedChanged: onPlaybackPausedChanged,
            onEnded: onEnded,
            onDebug: onDebug
        )
    }

    final class Coordinator: NSObject {
        var lastReplayRequest = 0
        var onTapped: () -> Void
        var onPlaybackPausedChanged: (Bool) -> Void
        private let onEnded: () -> Void
        private let onDebug: (String) -> Void
        private var statusObservation: NSKeyValueObservation?
        private var playbackObservation: NSKeyValueObservation?
        private var endObserver: NSObjectProtocol?
        private weak var tapRecognizer: UITapGestureRecognizer?

        init(
            onTapped: @escaping () -> Void,
            onPlaybackPausedChanged: @escaping (Bool) -> Void,
            onEnded: @escaping () -> Void,
            onDebug: @escaping (String) -> Void
        ) {
            self.onTapped = onTapped
            self.onPlaybackPausedChanged = onPlaybackPausedChanged
            self.onEnded = onEnded
            self.onDebug = onDebug
        }

        deinit {
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
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

        func makePlayer(for streamURL: URL) -> AVPlayer {
            let headers = [
                "User-Agent": "Mozilla/5.0 AppleTV SpaceXTV/1.0",
                "Referer": "https://x.com/",
            ]
            let asset = AVURLAsset(
                url: streamURL,
                options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
            )
            let item = AVPlayerItem(asset: asset)
            item.preferredPeakBitRate = 0
            item.preferredForwardBufferDuration = 8
            if #available(tvOS 11.0, iOS 11.0, *) {
                item.preferredMaximumResolution = CGSize(width: 3840, height: 2160)
            }
            observe(item)
            let player = AVPlayer(playerItem: item)
            observe(player)
            return player
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

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.onDebug("AVPlayerItem reached end")
                self?.onEnded()
            }

            statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                Task { @MainActor in
                    switch item.status {
                    case .unknown:
                        self?.onDebug("AVPlayerItem status: unknown")
                    case .readyToPlay:
                        self?.onDebug("AVPlayerItem status: ready")
                        if let event = item.accessLog()?.events.last {
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
                    @unknown default:
                        self?.onDebug("AVPlayerItem status: unknown future status")
                    }
                }
            }
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
