import Foundation

struct Broadcast: Identifiable, Hashable, Codable {
    enum SourceKind: String, Codable {
        case xBroadcast
        case hls
    }

    enum ContentKind: String, Codable {
        case video
        case gallery
    }

    let id: UUID
    var title: String
    var subtitle: String
    var sourceURL: URL
    var sourceKind: SourceKind
    var contentKind: ContentKind
    var streamURL: URL?
    var tweetText: String?
    var publishedAt: Date?
    var thumbnailURL: URL?
    var galleryImages: [GalleryImage]
    var artworkName: String
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        sourceURL: URL,
        sourceKind: SourceKind,
        contentKind: ContentKind = .video,
        streamURL: URL? = nil,
        tweetText: String? = nil,
        publishedAt: Date? = nil,
        thumbnailURL: URL? = nil,
        galleryImages: [GalleryImage] = [],
        artworkName: String,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.sourceURL = sourceURL
        self.sourceKind = sourceKind
        self.contentKind = contentKind
        self.streamURL = streamURL
        self.tweetText = tweetText
        self.publishedAt = publishedAt
        self.thumbnailURL = thumbnailURL
        self.galleryImages = galleryImages
        self.artworkName = artworkName
        self.isPinned = isPinned
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case sourceURL
        case sourceKind
        case contentKind
        case streamURL
        case tweetText
        case publishedAt
        case thumbnailURL
        case galleryImages
        case artworkName
        case isPinned
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
        tweetText = try container.decodeIfPresent(String.self, forKey: .tweetText)
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        galleryImages = try container.decodeIfPresent([GalleryImage].self, forKey: .galleryImages) ?? []
        artworkName = try container.decode(String.self, forKey: .artworkName)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
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
