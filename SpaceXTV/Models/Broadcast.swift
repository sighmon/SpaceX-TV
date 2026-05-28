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
        artworkName: String
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
