import Foundation

struct Broadcast: Identifiable, Hashable, Codable {
    enum SourceKind: String, Codable {
        case xBroadcast
        case hls
        case youtube
    }

    enum ContentKind: String, Codable {
        case video
        case gallery
        case collection
    }

    let id: UUID
    var title: String
    var subtitle: String
    var sourceURL: URL
    var sourceKind: SourceKind
    var contentKind: ContentKind
    var streamURL: URL?
    var fallbackStreamURL: URL?
    var tweetText: String?
    var publishedAt: Date?
    var thumbnailURL: URL?
    var galleryImages: [GalleryImage]
    var mediaItems: [PostMediaItem]
    var artworkName: String
    var isPinned: Bool
    var isLive: Bool?

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        sourceURL: URL,
        sourceKind: SourceKind,
        contentKind: ContentKind = .video,
        streamURL: URL? = nil,
        fallbackStreamURL: URL? = nil,
        tweetText: String? = nil,
        publishedAt: Date? = nil,
        thumbnailURL: URL? = nil,
        galleryImages: [GalleryImage] = [],
        mediaItems: [PostMediaItem] = [],
        artworkName: String,
        isPinned: Bool = false,
        isLive: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.sourceURL = sourceURL
        self.sourceKind = sourceKind
        self.contentKind = contentKind
        self.streamURL = streamURL
        self.fallbackStreamURL = fallbackStreamURL
        self.tweetText = tweetText
        self.publishedAt = publishedAt
        self.thumbnailURL = thumbnailURL
        self.galleryImages = galleryImages
        self.mediaItems = mediaItems
        self.artworkName = artworkName
        self.isPinned = isPinned
        self.isLive = isLive
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case sourceURL
        case sourceKind
        case contentKind
        case streamURL
        case fallbackStreamURL
        case tweetText
        case publishedAt
        case thumbnailURL
        case galleryImages
        case mediaItems
        case artworkName
        case isPinned
        case isLive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decode(String.self, forKey: .subtitle)
        sourceURL = try container.decode(URL.self, forKey: .sourceURL)
        sourceKind = try container.decode(SourceKind.self, forKey: .sourceKind)
        contentKind = try container.decodeIfPresent(ContentKind.self, forKey: .contentKind) ?? .video
        streamURL = try container.decodeIfPresent(URL.self, forKey: .streamURL)
        fallbackStreamURL = try container.decodeIfPresent(URL.self, forKey: .fallbackStreamURL)
        tweetText = try container.decodeIfPresent(String.self, forKey: .tweetText)
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        galleryImages = try container.decodeIfPresent([GalleryImage].self, forKey: .galleryImages) ?? []
        mediaItems = try container.decodeIfPresent([PostMediaItem].self, forKey: .mediaItems) ?? []
        artworkName = try container.decode(String.self, forKey: .artworkName)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isLive = try container.decodeIfPresent(Bool.self, forKey: .isLive)
    }

    var videoMediaItems: [PostMediaItem] {
        mediaItems.filter { $0.kind == .video }
    }

    var photoMediaItems: [PostMediaItem] {
        mediaItems.filter { $0.kind == .photo }
    }

    var mediaSummaryLabel: String? {
        switch contentKind {
        case .gallery:
            let count = galleryImages.count
            guard count > 0 else { return nil }
            return count == 1 ? "1 photo" : "\(count) photos"
        case .collection:
            return PostMediaItem.summaryLabel(for: mediaItems)
        case .video:
            return nil
        }
    }

    /// Builds a playable video broadcast for one item in a multi-media post.
    func videoBroadcast(for item: PostMediaItem, index: Int, totalVideos: Int) -> Broadcast {
        let subtitle: String
        if totalVideos > 1 {
            subtitle = "Video \(index) of \(totalVideos)"
        } else {
            subtitle = self.subtitle
        }

        return Broadcast(
            title: title,
            subtitle: subtitle,
            sourceURL: sourceURL,
            sourceKind: sourceKind,
            contentKind: .video,
            streamURL: item.streamURL,
            fallbackStreamURL: fallbackStreamURL,
            tweetText: tweetText,
            publishedAt: publishedAt,
            thumbnailURL: item.thumbnailURL ?? thumbnailURL,
            artworkName: artworkName,
            isPinned: isPinned,
            isLive: isLive
        )
    }

    /// Builds a gallery broadcast from the photo items in this post.
    func photoGalleryBroadcast(images: [GalleryImage]? = nil) -> Broadcast {
        let images = images ?? galleryImagesFromMediaItems
        return Broadcast(
            title: title,
            subtitle: subtitle,
            sourceURL: sourceURL,
            sourceKind: sourceKind,
            contentKind: .gallery,
            tweetText: tweetText,
            publishedAt: publishedAt,
            thumbnailURL: images.first?.url ?? thumbnailURL,
            galleryImages: images,
            artworkName: "photo.on.rectangle",
            isPinned: isPinned
        )
    }

    private var galleryImagesFromMediaItems: [GalleryImage] {
        if !galleryImages.isEmpty {
            return galleryImages
        }
        return photoMediaItems.compactMap { item in
            guard let url = item.thumbnailURL ?? item.photoURL else { return nil }
            return GalleryImage(
                url: url,
                width: item.width,
                height: item.height,
                altText: item.altText
            )
        }
    }
}

struct PostMediaItem: Hashable, Codable, Identifiable {
    enum Kind: String, Codable {
        case video
        case photo
    }

    var id: String
    var kind: Kind
    var streamURL: URL?
    var thumbnailURL: URL?
    var photoURL: URL?
    var width: Int?
    var height: Int?
    var altText: String?

    init(
        id: String,
        kind: Kind,
        streamURL: URL? = nil,
        thumbnailURL: URL? = nil,
        photoURL: URL? = nil,
        width: Int? = nil,
        height: Int? = nil,
        altText: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.streamURL = streamURL
        self.thumbnailURL = thumbnailURL
        self.photoURL = photoURL
        self.width = width
        self.height = height
        self.altText = altText
    }

    static func summaryLabel(for items: [PostMediaItem]) -> String? {
        let videoCount = items.filter { $0.kind == .video }.count
        let photoCount = items.filter { $0.kind == .photo }.count
        var parts: [String] = []
        if videoCount > 0 {
            parts.append(videoCount == 1 ? "1 video" : "\(videoCount) videos")
        }
        if photoCount > 0 {
            parts.append(photoCount == 1 ? "1 photo" : "\(photoCount) photos")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }
}

struct GalleryImage: Hashable, Codable, Identifiable {
    var id: URL { url }
    var url: URL
    var width: Int?
    var height: Int?
    var altText: String?
}

struct ResolvedBroadcast: Codable, Hashable {
    var title: String?
    var streamURL: URL
    var thumbnailURL: URL?
    var isLive: Bool?
}
