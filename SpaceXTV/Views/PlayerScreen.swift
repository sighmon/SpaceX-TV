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

    init(broadcast: Broadcast) {
        self.broadcast = broadcast
    }

    func start() async {
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
        var request = URLRequest(url: streamURL)
        request.setValue("Mozilla/5.0 AppleTV SpaceXTV/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://x.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            debugLines.append("HLS preflight HTTP \(statusCode), \(data.count) bytes")

            if let preview = String(data: data.prefix(120), encoding: .utf8) {
                debugLines.append("HLS preview: \(preview.replacingOccurrences(of: "\n", with: " "))")
            }
        } catch {
            debugLines.append("HLS preflight failed: \(error.localizedDescription)")
        }
    }
}

struct PlayerScreen: View {
    @EnvironmentObject private var library: BroadcastLibrary
    @StateObject private var model: PlayerViewModel

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
                    TVPlayerView(streamURL: url) { line in
                        model.appendPlayerDebug(line)
                    }
                    .ignoresSafeArea()

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
    }
}

struct TVPlayerView: UIViewControllerRepresentable {
    var streamURL: URL
    var onDebug: (String) -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = context.coordinator.makePlayer(for: streamURL)
        controller.showsPlaybackControls = true
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        let currentURL = (controller.player?.currentItem?.asset as? AVURLAsset)?.url
        guard currentURL != streamURL else { return }

        controller.player = context.coordinator.makePlayer(for: streamURL)
        controller.player?.play()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDebug: onDebug)
    }

    final class Coordinator: NSObject {
        private let onDebug: (String) -> Void
        private var statusObservation: NSKeyValueObservation?

        init(onDebug: @escaping (String) -> Void) {
            self.onDebug = onDebug
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
            observe(item)
            return AVPlayer(playerItem: item)
        }

        private func observe(_ item: AVPlayerItem) {
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
