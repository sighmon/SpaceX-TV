import SwiftUI

struct BroadcastBrowserView: View {
    @EnvironmentObject private var library: BroadcastLibrary
    @Binding var selectedBroadcast: Broadcast?
    @Binding var showsSettings: Bool
    @FocusState private var focusedID: Broadcast.ID?

    private var visibleBroadcasts: [Broadcast] {
        library.broadcasts
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.20, green: 0.22, blue: 0.24), Color(red: 0.02, green: 0.03, blue: 0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 42) {
                    header
                    content
                }
                .padding(.horizontal, 84)
                .padding(.vertical, 54)
            }
        }
        // .navigationTitle("SpaceX Live")
        .task {
            guard case .idle = library.loadingState else { return }
            await library.load()
        }
        .onChange(of: library.xAPIBearerToken) { _, _ in
            Task { await library.load() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Image("SpaceX")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: 140, alignment: .leading)
            }

            Spacer(minLength: 32)

            HStack(spacing: 14) {
                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 58, height: 58)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await library.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 58, height: 58)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !library.hasXAPIBearerToken {
            MissingTokenView {
                showsSettings = true
            }
        } else {
            switch library.loadingState {
            case .idle, .loading:
                ProgressView("Finding recent broadcasts...")
                    .font(.title2)
                    .frame(maxWidth: .infinity, minHeight: 260, alignment: .center)
            case .loaded:
                broadcastGrid
            case .failed(let message):
                VStack(alignment: .leading, spacing: 20) {
                    Label("Broadcasts unavailable", systemImage: "exclamationmark.triangle")
                        .font(.title2.weight(.semibold))
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    DebugLogView(lines: library.debugLines)
                    Button {
                        Task { await library.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .padding(28)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var broadcastGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 56),
                GridItem(.flexible(), spacing: 56),
            ],
            alignment: .leading,
            spacing: 56
        ) {
            ForEach(visibleBroadcasts) { broadcast in
                Button {
                    selectedBroadcast = broadcast
                } label: {
                    BroadcastCard(broadcast: broadcast, isFocused: focusedID == broadcast.id)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .focused($focusedID, equals: broadcast.id)
                .task {
                    await library.loadMoreIfNeeded(currentBroadcast: broadcast)
                }
            }

            if library.isLoadingMore {
                HStack(spacing: 14) {
                    ProgressView()
                    Text("Loading more broadcasts...")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .gridCellColumns(2)
            }
        }
    }
}

private struct MissingTokenView: View {
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Add your X API token", systemImage: "key.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)

            Text("SpaceX broadcasts are loaded through the X API. Add a Bearer Token in Settings to fetch the latest posts and streams.")
                .font(.body)
                .foregroundStyle(.gray)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                openSettings()
            } label: {
                Label("Open Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct DebugLogView: View {
    var lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Debug")
                .font(.headline)
            ForEach(Array(lines.suffix(18).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct BroadcastCard: View {
    var broadcast: Broadcast
    var isFocused: Bool
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            background

            LinearGradient(
                colors: [
                    .black.opacity(0.12),
                    .black.opacity(0.62),
                    .black.opacity(0.88),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    if let tweetText = broadcast.tweetText, !tweetText.isEmpty {
                        Text(displayText(from: tweetText))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(4)
                    } else {
                        Text(broadcast.subtitle)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                    }

                    if let publishedAt = broadcast.publishedAt {
                        Text(dateFormatter.string(from: publishedAt))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.gray.opacity(0.6))
                    }
                }

                 Spacer(minLength: 12)
                 Image(systemName: "play.fill")
                     .font(.title3.weight(.bold))
                     .foregroundStyle(.white)
            }
            .padding(26)
        }
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .bottomLeading)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(.white.opacity(isFocused ? 0.20 : 0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(isFocused ? 0.65 : 0.12), lineWidth: isFocused ? 4 : 1)
        }
        .scaleEffect(isFocused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.16), value: isFocused)
    }

    @ViewBuilder
    private var background: some View {
        if let thumbnailURL = broadcast.thumbnailURL {
            AsyncImage(url: thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    fallbackBackground
                case .empty:
                    fallbackBackground
                @unknown default:
                    fallbackBackground
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300)
            .clipped()
        } else {
            fallbackBackground
        }
    }

    private var fallbackBackground: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.12, blue: 0.14), Color(red: 0.02, green: 0.03, blue: 0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image("SpaceX")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 180, height: 96)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func displayText(from text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.hasPrefix("http://") && !$0.hasPrefix("https://") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
