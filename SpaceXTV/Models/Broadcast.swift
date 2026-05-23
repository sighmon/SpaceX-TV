import Foundation

struct Broadcast: Identifiable, Hashable, Codable {
    enum SourceKind: String, Codable {
        case xBroadcast
        case hls
    }

    let id: UUID
    var title: String
    var subtitle: String
    var sourceURL: URL
    var sourceKind: SourceKind
    var streamURL: URL?
    var tweetText: String?
    var publishedAt: Date?
    var thumbnailURL: URL?
    var artworkName: String

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        sourceURL: URL,
        sourceKind: SourceKind,
        streamURL: URL? = nil,
        tweetText: String? = nil,
        publishedAt: Date? = nil,
        thumbnailURL: URL? = nil,
        artworkName: String
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.sourceURL = sourceURL
        self.sourceKind = sourceKind
        self.streamURL = streamURL
        self.tweetText = tweetText
        self.publishedAt = publishedAt
        self.thumbnailURL = thumbnailURL
        self.artworkName = artworkName
    }
}

struct ResolvedBroadcast: Codable, Hashable {
    var title: String?
    var streamURL: URL
    var thumbnailURL: URL?
    var isLive: Bool?
}
