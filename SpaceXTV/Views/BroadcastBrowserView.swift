import SwiftUI

struct BroadcastBrowserView: View {
    @EnvironmentObject private var library: BroadcastLibrary
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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

            GeometryReader { proxy in
                let screenWidth = proxy.size.width
                let horizontalPadding = horizontalPadding(for: screenWidth)
                let contentWidth = max(0, screenWidth - (horizontalPadding * 2))

                ScrollView {
                    VStack(alignment: .leading, spacing: verticalSpacing(for: screenWidth)) {
                        header(width: contentWidth)
                        content(width: contentWidth)
                    }
                    .frame(width: contentWidth, alignment: .leading)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding(for: screenWidth))
                }
                .frame(width: screenWidth)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // .navigationTitle("SpaceX Live")
        .task {
            guard case .idle = library.loadingState else { return }
            await library.load()
        }
        .onChange(of: library.xAPIBearerToken) { _, _ in
            Task { await library.load() }
        }
    }

    private func header(width: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Image("SpaceX")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: logoWidth(for: width), alignment: .leading)
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
    private func content(width: CGFloat) -> some View {
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
                broadcastGrid(width: width)
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

    private func broadcastGrid(width: CGFloat) -> some View {
        let columns = gridColumns(for: width)
        return LazyVGrid(
            columns: columns,
            alignment: .leading,
            spacing: gridSpacing(for: width)
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
                .gridCellColumns(columns.count)
            }
        }
    }

    private func horizontalPadding(for width: CGFloat) -> CGFloat {
        if horizontalSizeClass == .compact { return 24 }
        return width < 900 ? 36 : 84
    }

    private func verticalPadding(for width: CGFloat) -> CGFloat {
        width < 900 ? 28 : 54
    }

    private func verticalSpacing(for width: CGFloat) -> CGFloat {
        width < 900 ? 28 : 42
    }

    private func gridSpacing(for width: CGFloat) -> CGFloat {
        width < 900 ? 32 : 56
    }

    private func gridColumns(for width: CGFloat) -> [GridItem] {
        let spacing = gridSpacing(for: width)
        let columnCount = horizontalSizeClass == .regular && width >= 620 ? 2 : 1
        return Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: spacing),
            count: columnCount
        )
    }

    private func logoWidth(for width: CGFloat) -> CGFloat {
        width < 700 ? 112 : 140
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
    private let aspectRatio: CGFloat = 16.0 / 9.0
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
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
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
            RemoteThumbnailImage(url: thumbnailURL, fallback: fallbackBackground)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func displayText(from text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.hasPrefix("http://") && !$0.hasPrefix("https://") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct RemoteThumbnailImage<Fallback: View>: View {
    var url: URL
    var fallback: Fallback
    @StateObject private var loader = ThumbnailImageLoader()

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: url) {
            await loader.load(url)
        }
    }
}

@MainActor
private final class ThumbnailImageLoader: ObservableObject {
    @Published var image: UIImage?
    private var loadedURL: URL?

    func load(_ url: URL) async {
        guard loadedURL != url || image == nil else { return }
        image = nil

        let urls = candidateURLs(for: url)
        for candidateURL in urls {
            if await loadImage(candidateURL) {
                loadedURL = url
                return
            }

            guard !Task.isCancelled else {
                return
            }
        }
    }

    private func loadImage(_ url: URL) async -> Bool {
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 AppleTV SpaceXTV/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200 ..< 300).contains(statusCode) else {
                print("[SpaceXTV] Thumbnail HTTP \(statusCode): \(url.absoluteString)")
                return false
            }
            guard let decodedImage = UIImage(data: data) else {
                print("[SpaceXTV] Thumbnail decode failed, \(data.count) bytes: \(url.absoluteString)")
                return false
            }
            image = decodedImage
            print("[SpaceXTV] Thumbnail loaded: \(url.absoluteString)")
            return true
        } catch {
            print("[SpaceXTV] Thumbnail load failed: \(error.localizedDescription) \(url.absoluteString)")
            return false
        }
    }

    private func candidateURLs(for url: URL) -> [URL] {
        var urls: [URL] = []
        func append(_ nextURL: URL?) {
            guard let nextURL, !urls.contains(nextURL) else { return }
            urls.append(nextURL)
        }

        append(url)
        guard url.host?.lowercased().hasSuffix("twimg.com") == true,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return urls
        }

        let originalName = components.queryItems?.first { $0.name == "name" }?.value
        let originalFormat = components.queryItems?.first { $0.name == "format" }?.value
        let names = [originalName, "4096x4096", "orig", "large", "medium", "small"]
            .compactMap { $0 }
        let formats = [originalFormat, "jpg", "png", "webp"]
            .compactMap { $0 }

        for name in names {
            append(thumbnailURL(updating: components, name: name, format: nil))
            for format in formats {
                append(thumbnailURL(updating: components, name: name, format: format))
            }
        }

        var noQueryComponents = components
        noQueryComponents.queryItems = nil
        append(noQueryComponents.url)

        return urls
    }

    private func thumbnailURL(updating components: URLComponents, name: String, format: String?) -> URL? {
        var nextComponents = components
        var queryItems = nextComponents.queryItems ?? []
        if let index = queryItems.firstIndex(where: { $0.name == "name" }) {
            queryItems[index].value = name
        } else {
            queryItems.append(URLQueryItem(name: "name", value: name))
        }

        if let format {
            if let index = queryItems.firstIndex(where: { $0.name == "format" }) {
                queryItems[index].value = format
            } else {
                queryItems.append(URLQueryItem(name: "format", value: format))
            }
        }

        nextComponents.queryItems = queryItems
        return nextComponents.url
    }
}
