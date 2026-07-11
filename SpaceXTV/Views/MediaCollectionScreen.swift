import SwiftUI

struct MediaCollectionScreen: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var collection: Broadcast

    @State private var selectedBroadcast: Broadcast?
    @State private var selectedGallery: Broadcast?
    @FocusState private var focusedEntryID: String?

    private var entries: [MediaCollectionEntry] {
        MediaCollectionEntry.entries(from: collection)
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
                    VStack(alignment: .leading, spacing: 0) {
                        header
                            .frame(width: contentWidth, alignment: .leading)
                            .padding(.bottom, verticalSpacing(for: screenWidth))

                        mediaGrid(width: contentWidth)
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
        .navigationDestination(item: $selectedBroadcast) { broadcast in
            PlayerScreen(broadcast: broadcast)
        }
#if os(tvOS)
        .navigationDestination(item: $selectedGallery) { gallery in
            GalleryScreen(gallery: gallery)
        }
#endif
#if !os(tvOS)
        .overlay {
            if let selectedGallery {
                GalleryScreen(gallery: selectedGallery) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        self.selectedGallery = nil
                    }
                }
                .transition(.move(edge: .trailing))
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: selectedGallery?.id)
#endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let tweetText = collection.tweetText, !tweetText.isEmpty {
                Text(displayText(from: tweetText))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(collection.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
            }

            HStack(spacing: 12) {
                if let summary = collection.mediaSummaryLabel {
                    Text(summary)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }

                if let publishedAt = collection.publishedAt {
                    Text(publishedAt, format: .dateTime.month().day().year())
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.48))
                }
            }
        }
    }

    private func mediaGrid(width: CGFloat) -> some View {
        let spacing = gridSpacing(for: width)
        let columnCount = gridColumnCount(for: width)
        let cardWidth = (width - (spacing * CGFloat(max(columnCount - 1, 0)))) / CGFloat(columnCount)

        return Grid(alignment: .leading, horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(Array(stride(from: 0, to: entries.count, by: columnCount)), id: \.self) { startIndex in
                let endIndex = min(startIndex + columnCount, entries.count)
                GridRow {
                    ForEach(entries[startIndex ..< endIndex]) { entry in
                        entryButton(entry, width: cardWidth)
                    }

                    if endIndex - startIndex < columnCount {
                        ForEach(0 ..< (columnCount - (endIndex - startIndex)), id: \.self) { _ in
                            Color.clear
                                .frame(width: cardWidth)
                                .gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func entryButton(_ entry: MediaCollectionEntry, width: CGFloat) -> some View {
        Button {
            select(entry)
        } label: {
            BroadcastCard(
                broadcast: entry.cardBroadcast(from: collection),
                isFocused: focusedEntryID == entry.id,
                titleOverride: entry.title,
                actionSymbolOverride: entry.systemImage
            )
            .frame(width: width)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focusedEntryID, equals: entry.id)
    }

    private func select(_ entry: MediaCollectionEntry) {
        switch entry {
        case let .video(item, index, totalVideos):
            selectedBroadcast = collection.videoBroadcast(for: item, index: index, totalVideos: totalVideos)
        case let .photos(images):
            selectedGallery = collection.photoGalleryBroadcast(images: images)
        }
    }

    // MARK: - Layout (matches BroadcastBrowserView)

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

    private func gridColumnCount(for width: CGFloat) -> Int {
        horizontalSizeClass == .regular && width >= 620 ? 2 : 1
    }

    private func displayText(from tweetText: String) -> String {
        tweetText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.hasPrefix("http://") && !$0.hasPrefix("https://") }
            .joined(separator: " ")
    }
}

private enum MediaCollectionEntry: Identifiable {
    case video(PostMediaItem, index: Int, totalVideos: Int)
    case photos([GalleryImage])

    var id: String {
        switch self {
        case let .video(item, index, _):
            return "video:\(item.id):\(index)"
        case let .photos(images):
            let key = images.map(\.url.absoluteString).joined(separator: "|")
            return "photos:\(key)"
        }
    }

    var title: String {
        switch self {
        case let .video(_, index, totalVideos):
            return totalVideos > 1 ? "Video \(index) of \(totalVideos)" : "Video"
        case let .photos(images):
            return images.count == 1 ? "1 photo" : "\(images.count) photos"
        }
    }

    var systemImage: String {
        switch self {
        case .video:
            return "play.fill"
        case .photos:
            return "photo"
        }
    }

    func cardBroadcast(from collection: Broadcast) -> Broadcast {
        switch self {
        case let .video(item, index, totalVideos):
            return collection.videoBroadcast(for: item, index: index, totalVideos: totalVideos)
        case let .photos(images):
            // Card chrome only: use .video so metadata is just the post date.
            // Title override already shows "N photos"; selection still builds a real gallery.
            return Broadcast(
                title: collection.title,
                subtitle: collection.subtitle,
                sourceURL: collection.sourceURL,
                sourceKind: collection.sourceKind,
                contentKind: .video,
                tweetText: collection.tweetText,
                publishedAt: collection.publishedAt,
                thumbnailURL: images.first?.url ?? collection.thumbnailURL,
                artworkName: "photo.on.rectangle",
                isPinned: collection.isPinned
            )
        }
    }

    static func entries(from collection: Broadcast) -> [MediaCollectionEntry] {
        let videos = collection.videoMediaItems
        var result: [MediaCollectionEntry] = []
        var photoBuffer: [GalleryImage] = []

        func flushPhotos() {
            guard !photoBuffer.isEmpty else { return }
            result.append(.photos(photoBuffer))
            photoBuffer = []
        }

        var videoIndex = 0
        for item in collection.mediaItems {
            switch item.kind {
            case .video:
                flushPhotos()
                videoIndex += 1
                result.append(.video(item, index: videoIndex, totalVideos: max(videos.count, 1)))
            case .photo:
                let url = item.photoURL ?? item.thumbnailURL
                guard let url else { continue }
                photoBuffer.append(
                    GalleryImage(
                        url: url,
                        width: item.width,
                        height: item.height,
                        altText: item.altText
                    )
                )
            }
        }
        flushPhotos()

        // Fallback if mediaItems empty but gallery/stream present.
        if result.isEmpty {
            if !collection.galleryImages.isEmpty {
                result.append(.photos(collection.galleryImages))
            } else if collection.streamURL != nil || collection.contentKind == .video {
                let item = PostMediaItem(
                    id: collection.id.uuidString,
                    kind: .video,
                    streamURL: collection.streamURL,
                    thumbnailURL: collection.thumbnailURL
                )
                result.append(.video(item, index: 1, totalVideos: 1))
            }
        }

        return result
    }
}
