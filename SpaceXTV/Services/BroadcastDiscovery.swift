import Foundation

enum BroadcastDiscoveryError: LocalizedError {
    case missingBearerToken
    case noStatusesFound
    case noBroadcastsFound
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingBearerToken:
            "Add an X API Bearer Token in Settings to load SpaceX broadcasts."
        case .noStatusesFound:
            "No recent SpaceX broadcasts were returned by the X API."
        case .noBroadcastsFound:
            "No recent SpaceX statuses with bundled broadcasts or image galleries were found."
        case .invalidResponse:
            "X returned a response the app could not read."
        }
    }
}

struct BroadcastDiscovery {
    var session: URLSession = .shared
    private let timelineFetchMultiplier = 2
    private let minimumTimelineFetchLimit = 25
    private let maximumTimelineFetchLimit = 100
    private let starshipPlaylistURL = URL(string: "https://content.spacex.com/api/spacex-website/media-playlist/starship")!
    private let starshipFlightTestsPlaylistURL = URL(string: "https://content.spacex.com/api/spacex-website/media-playlist/starship-flight-tests")!
    private let launchTilesURL = URL(string: "https://content.spacex.com/api/spacex-website/launches-page-tiles")!
    private let missionsBaseURL = URL(string: "https://content.spacex.com/api/spacex-website/missions/")!

    var resolver: BroadcastResolver {
        BroadcastResolver(session: session)
    }

    func discoverRecentSpaceXBroadcasts(
        limit: Int = 10,
        xAPIBearerToken: String?,
        prefersMP4Playback: Bool = true
    ) async throws -> BroadcastDiscoveryResult {
        var report = DiscoveryReport()
        report.add("Starting SpaceX post discovery")
        report.add("SpaceX CMS playback preference: \(prefersMP4Playback ? "MP4" : "HLS")")
        let timelineLimit = timelineFetchLimit(for: limit)
        report.add("X API timeline fetch limit: \(timelineLimit)")

        let candidates = try await recentSpaceXBroadcastCandidates(
            timelineLimit: timelineLimit,
            xAPIBearerToken: xAPIBearerToken,
            report: &report
        )
        report.add("Candidate statuses: \(candidates.count)")

        return try await discoveryResult(from: candidates, prefersMP4Playback: prefersMP4Playback, report: &report)
    }

    func discoverRecentSpaceXBroadcasts(
        limit: Int = 10,
        xAPICacheURL: URL,
        prefersMP4Playback: Bool = true
    ) async throws -> BroadcastDiscoveryResult {
        var report = DiscoveryReport()
        report.add("Starting SpaceX post discovery")
        report.add("SpaceX CMS playback preference: \(prefersMP4Playback ? "MP4" : "HLS")")
        let timelineLimit = timelineFetchLimit(for: limit)
        report.add("X API cache target timeline limit: \(timelineLimit)")

        let candidates = try await recentSpaceXBroadcastCandidatesFromCache(
            cacheURL: xAPICacheURL,
            timelineLimit: timelineLimit,
            report: &report
        )
        report.add("Candidate statuses: \(candidates.count)")

        return try await discoveryResult(from: candidates, prefersMP4Playback: prefersMP4Playback, report: &report)
    }

    private func discoveryResult(
        from initialCandidates: [BroadcastCandidate],
        prefersMP4Playback: Bool,
        report: inout DiscoveryReport
    ) async throws -> BroadcastDiscoveryResult {
        var candidates = deduplicatedCandidates(initialCandidates)
        var appendedStarshipFilmCandidates: [BroadcastCandidate] = []
        var appendedStarshipFlightTestCandidates: [BroadcastCandidate] = []
        do {
            appendedStarshipFilmCandidates = try await recentStarshipFilmCandidates(
                prefersMP4Playback: prefersMP4Playback,
                report: &report
            )
            report.add("Starship film candidates: \(appendedStarshipFilmCandidates.count)")
        } catch {
            report.add("Starship film discovery failed: \(debugMessage(for: error))")
        }
        do {
            appendedStarshipFlightTestCandidates = try await starshipFlightTestCandidates(
                prefersMP4Playback: prefersMP4Playback,
                report: &report
            )
            report.add("Starship flight test candidates: \(appendedStarshipFlightTestCandidates.count)")
        } catch {
            report.add("Starship flight test discovery failed: \(debugMessage(for: error))")
        }
        candidates = candidates.sortedByPublishedDateDescending()
        let mergedCandidateCount = candidates.count + appendedStarshipFilmCandidates.count + appendedStarshipFlightTestCandidates.count
        report.add("Merged candidates: \(mergedCandidateCount)")

        guard mergedCandidateCount > 0 else {
            throw BroadcastDiscoveryFailure(error: BroadcastDiscoveryError.noStatusesFound, report: report)
        }

        var selectedXItems: [DiscoveredBroadcastItem] = []
        let xCandidates = candidates.filter { !$0.isAppendedSpaceXContent }
        for (index, candidate) in xCandidates.prefix(80).enumerated() {
            let statusURL = candidate.statusURL

            if !candidate.galleryImages.isEmpty, candidate.streamURL == nil, !candidate.allowsDeferredStreamResolution {
                report.add("Adding gallery \(index + 1): \(statusURL.lastPathComponent), images \(candidate.galleryImages.count)")
                selectedXItems.append(DiscoveredBroadcastItem(candidate: candidate, broadcast: gallery(from: candidate)))
                continue
            }

            report.add("Probing \(index + 1): \(statusURL.lastPathComponent)")

            do {
                let streamURL: URL
                let resolvedThumbnailURL: URL?
                let isLive: Bool?
                if let apiStreamURL = candidate.streamURL {
                    streamURL = apiStreamURL
                    resolvedThumbnailURL = nil
                    isLive = nil
                    report.add("Using X API media variant for \(statusURL.lastPathComponent)")
                } else {
                    let resolved = try await resolver.resolveStatusURL(statusURL)
                    streamURL = resolved.streamURL
                    resolvedThumbnailURL = resolved.thumbnailURL
                    isLive = resolved.isLive
                    report.add("Found page stream for \(statusURL.lastPathComponent)")
                    report.add("Page thumbnail for \(statusURL.lastPathComponent): \(resolvedThumbnailURL == nil ? "missing" : "present")")
                }

                report.add("Found stream for \(statusURL.lastPathComponent)")
                selectedXItems.append(DiscoveredBroadcastItem(
                    candidate: candidate,
                    broadcast: broadcast(
                        from: candidate,
                        streamURL: streamURL,
                        thumbnailURL: candidate.thumbnailURL ?? resolvedThumbnailURL,
                        isLive: isLive
                    )
                ))
            } catch {
                if candidate.allowsDeferredStreamResolution {
                    report.add("Deferring stream resolution for linked broadcast \(statusURL.lastPathComponent): \(debugMessage(for: error))")
                    selectedXItems.append(DiscoveredBroadcastItem(candidate: candidate, broadcast: broadcast(from: candidate, streamURL: nil)))
                } else {
                    report.add("No stream for \(statusURL.lastPathComponent): \(debugMessage(for: error))")
                }
            }
        }

        let selectedStarshipItems = (
            appendedStarshipFilmCandidates.sortedByPublishedDateDescending()
            + appendedStarshipFlightTestCandidates.sortedByPublishedDateDescending()
        )
            .map { candidate in
                DiscoveredBroadcastItem(candidate: candidate, broadcast: broadcast(from: candidate, streamURL: nil))
            }
        report.add("Adding \(selectedStarshipItems.count) SpaceX Starship items after X posts")

        let broadcasts = (
            selectedXItems
        )
        .sorted { $0.candidate.isSortedBefore($1.candidate) }
        .map(\.broadcast)
        + selectedStarshipItems
            .map(\.broadcast)

        guard !broadcasts.isEmpty else {
            throw BroadcastDiscoveryFailure(error: BroadcastDiscoveryError.noBroadcastsFound, report: report)
        }

        report.add("Discovery complete: \(broadcasts.count) posts")
        return BroadcastDiscoveryResult(broadcasts: broadcasts, report: report)
    }

    private func broadcast(from candidate: BroadcastCandidate, streamURL: URL?, thumbnailURL: URL? = nil, isLive: Bool? = nil) -> Broadcast {
        Broadcast(
            title: candidate.title,
            subtitle: candidate.subtitle,
            sourceURL: candidate.statusURL,
            sourceKind: candidate.sourceKind,
            streamURL: streamURL,
            tweetText: candidate.tweetText,
            publishedAt: candidate.publishedAt,
            thumbnailURL: thumbnailURL ?? candidate.thumbnailURL,
            artworkName: candidate.artworkName,
            isPinned: candidate.isPinned,
            isLive: isLive
        )
    }

    private func gallery(from candidate: BroadcastCandidate) -> Broadcast {
        Broadcast(
            title: candidate.title,
            subtitle: candidate.subtitle,
            sourceURL: candidate.statusURL,
            sourceKind: .xBroadcast,
            contentKind: .gallery,
            tweetText: candidate.tweetText,
            publishedAt: candidate.publishedAt,
            thumbnailURL: candidate.thumbnailURL ?? candidate.galleryImages.first?.url,
            galleryImages: candidate.galleryImages,
            artworkName: "photo.on.rectangle",
            isPinned: candidate.isPinned
        )
    }

    private func recentSpaceXBroadcastCandidates(timelineLimit: Int, xAPIBearerToken: String?, report: inout DiscoveryReport) async throws -> [BroadcastCandidate] {
        guard let xAPIBearerToken, !xAPIBearerToken.isEmpty else {
            report.add("No X API Bearer Token configured")
            throw BroadcastDiscoveryError.missingBearerToken
        }

        report.add("Using X API for timeline discovery")
        return try await recentSpaceXBroadcastCandidatesFromAPI(
            timelineLimit: timelineLimit,
            bearerToken: xAPIBearerToken,
            report: &report
        )
    }

    private func recentSpaceXBroadcastCandidatesFromAPI(timelineLimit: Int, bearerToken: String, report: inout DiscoveryReport) async throws -> [BroadcastCandidate] {
        let user = try await xAPIUser(username: "spacex", bearerToken: bearerToken, report: &report)
        let pinnedTimeline: XAPITimeline?
        if let pinnedTweetID = user.pinnedTweetID {
            report.add("X API pinned SpaceX post: \(pinnedTweetID)")
            pinnedTimeline = try? await xAPIPosts(ids: [pinnedTweetID], bearerToken: bearerToken, report: &report)
            if pinnedTimeline == nil {
                report.add("Pinned post fetch failed; continuing with timeline")
            }
        } else {
            pinnedTimeline = nil
            report.add("X API returned no pinned SpaceX post")
        }

        let timeline = try await xAPIPosts(userID: user.id, maxResults: timelineLimit, bearerToken: bearerToken, report: &report)
        report.add("X API returned \(timeline.posts.count) SpaceX posts")
        report.add("X API included \(timeline.mediaByKey.count) media objects")

        return recentSpaceXBroadcastCandidates(pinnedTimeline: pinnedTimeline, timeline: timeline, report: &report)
    }

    private func recentSpaceXBroadcastCandidatesFromCache(cacheURL: URL, timelineLimit: Int, report: inout DiscoveryReport) async throws -> [BroadcastCandidate] {
        report.add("Using X API cache for timeline discovery")
        report.add("X API cache GET: \(cacheURL.absoluteString)")
        var request = URLRequest(url: cacheURL)
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        report.add("X API cache HTTP \(statusCode), \(data.count) bytes")

        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            throw BroadcastDiscoveryError.invalidResponse
        }

        let cache: XAPICacheResponse
        do {
            cache = try xAPIDecoder().decode(XAPICacheResponse.self, from: data)
        } catch {
            report.add("X API cache decode failed: \(debugMessage(for: error))")
            throw BroadcastDiscoveryFailure(error: BroadcastDiscoveryError.invalidResponse, report: report)
        }

        if let generatedAt = cache.generatedAt {
            report.setXAPICacheGeneratedAt(generatedAt)
            report.add("X API cache generated at: \(ISO8601DateFormatter().string(from: generatedAt))")
        }
        report.add("X API cache source: \(cache.source ?? "unknown")")

        let pinnedTimeline = cache.pinned.map(xAPITimeline(from:))
        let timeline = xAPITimeline(from: cache.timeline)
        let limitedTimeline = XAPITimeline(
            posts: Array(timeline.posts.prefix(timelineLimit)),
            mediaByKey: timeline.mediaByKey,
            includedPostsByID: timeline.includedPostsByID
        )
        report.add("X API cache returned \(limitedTimeline.posts.count) SpaceX posts")
        report.add("X API cache included \(limitedTimeline.mediaByKey.count) media objects")

        return recentSpaceXBroadcastCandidates(pinnedTimeline: pinnedTimeline, timeline: limitedTimeline, report: &report)
    }

    private func recentSpaceXBroadcastCandidates(pinnedTimeline: XAPITimeline?, timeline: XAPITimeline, report: inout DiscoveryReport) -> [BroadcastCandidate] {
        let pinnedCandidates = pinnedTimeline?.posts.compactMap {
            candidate(from: $0, timeline: pinnedTimeline ?? .empty, isPinned: true, report: &report)
        } ?? []

        let timelineCandidates = timeline.posts.compactMap {
            candidate(from: $0, timeline: timeline, isPinned: false, report: &report)
        }

        return deduplicatedCandidates(pinnedCandidates + timelineCandidates)
    }

    private func xAPITimeline(from response: XAPIPostsResponse) -> XAPITimeline {
        let mediaByKey = Dictionary(
            uniqueKeysWithValues: (response.includes?.media ?? []).map { ($0.mediaKey, $0) }
        )
        let includedPostsByID = Dictionary(
            uniqueKeysWithValues: (response.includes?.tweets ?? []).map { ($0.id, $0) }
        )

        return XAPITimeline(posts: response.data ?? [], mediaByKey: mediaByKey, includedPostsByID: includedPostsByID)
    }

    private func candidate(
        from post: XAPIPost,
        timeline: XAPITimeline,
        isPinned: Bool,
        report: inout DiscoveryReport
    ) -> BroadcastCandidate? {
        guard let statusURL = URL(string: "https://x.com/spacex/status/\(post.id)") else {
            return nil
        }
        let linkedBroadcastURL = post.broadcastURLFromEntities

        let ownMedia = mediaObjects(from: post, mediaByKey: timeline.mediaByKey)
        let quotedPost = post.quotedTweetID.flatMap { timeline.includedPostsByID[$0] }
        let quotedMedia = quotedPost.map { mediaObjects(from: $0, mediaByKey: timeline.mediaByKey) } ?? []
        let media = ownMedia.isEmpty ? quotedMedia : ownMedia
        let mediaSource = ownMedia.isEmpty && !quotedMedia.isEmpty ? "quoted status \(quotedPost?.id ?? "")" : "status"
        let variant = bestVariant(from: media)
        let galleryImages = galleryImages(from: media)
        let thumbnailURL = media.compactMap(\.thumbnailURL).first ?? galleryImages.first?.url ?? post.thumbnailURLFromEntities ?? quotedPost?.thumbnailURLFromEntities

        logVideoVariants(for: post.id, media: media, selectedVariant: variant, report: &report)
        if let variant {
            report.add("API media variant for \(post.id) from \(mediaSource): \(variant.debugDescription)")
        } else if let linkedBroadcastURL {
            report.add("Broadcast link for \(post.id): \(linkedBroadcastURL.absoluteString)")
        } else if !galleryImages.isEmpty {
            report.add("Image gallery for \(post.id) from \(mediaSource): \(galleryImages.count) photos")
        } else {
            report.add("No API media variant for \(post.id); will page-probe")
        }
        if let quotedTweetID = post.quotedTweetID {
            report.add("Quoted status for \(post.id): \(quotedTweetID), media objects \(quotedMedia.count)")
        }
        report.add("Thumbnail for \(post.id): \(thumbnailURL == nil ? "missing" : "present"), media objects \(media.count), URL images \(post.urlImageCount)")

        let subtitlePrefix = isPinned ? "Pinned SpaceX status" : "X status"
        return BroadcastCandidate(
            statusURL: linkedBroadcastURL ?? statusURL,
            dedupeKey: candidateDedupeKey(
                post: post,
                statusURL: statusURL,
                linkedBroadcastURL: linkedBroadcastURL,
                variant: variant,
                galleryImages: galleryImages,
                quotedPostID: quotedPost?.id
            ),
            streamURL: variant?.url,
            title: post.broadcastTitle,
            subtitle: candidateSubtitle(
                postID: post.id,
                isPinned: isPinned,
                variant: variant,
                linkedBroadcastURL: linkedBroadcastURL,
                fallbackPrefix: subtitlePrefix
            ),
            tweetText: post.text,
            publishedAt: post.createdAt,
            thumbnailURL: thumbnailURL,
            galleryImages: galleryImages,
            allowsDeferredStreamResolution: linkedBroadcastURL != nil,
            isPinned: isPinned
        )
    }

    private func logVideoVariants(
        for postID: String,
        media: [XAPIMedia],
        selectedVariant: XAPIMediaVariant?,
        report: inout DiscoveryReport
    ) {
        let variants = media.flatMap { $0.variants ?? [] }
            .filter { $0.url.scheme?.hasPrefix("http") == true }

        guard !variants.isEmpty else { return }

        let summary = variants
            .sorted { lhs, rhs in
                if (lhs.bitRate ?? 0) != (rhs.bitRate ?? 0) {
                    return (lhs.bitRate ?? 0) > (rhs.bitRate ?? 0)
                }
                return lhs.url.absoluteString < rhs.url.absoluteString
            }
            .map(\.debugDescription)
            .joined(separator: " | ")

        report.add("API media variants for \(postID): \(summary)")
        if let selectedVariant {
            report.add("Selected media variant for \(postID): \(selectedVariant.debugDescription)")
        }
    }

    private func candidateDedupeKey(
        post: XAPIPost,
        statusURL: URL,
        linkedBroadcastURL: URL?,
        variant: XAPIMediaVariant?,
        galleryImages: [GalleryImage],
        quotedPostID: String?
    ) -> String {
        if let linkedBroadcastURL,
           let broadcastID = xBroadcastID(from: linkedBroadcastURL) {
            return "broadcast:\(broadcastID)"
        }

        if let variant {
            return "stream:\(variant.url.absoluteString)"
        }

        if !galleryImages.isEmpty {
            return "gallery:\(quotedPostID ?? post.id)"
        }

        if let normalizedText = post.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !normalizedText.isEmpty {
            return "text:\(normalizedText)"
        }

        return "status:\(statusURL.absoluteString)"
    }

    private func xBroadcastID(from url: URL) -> String? {
        let pathComponents = url.pathComponents
        guard let broadcastsIndex = pathComponents.firstIndex(of: "broadcasts"),
              pathComponents.indices.contains(pathComponents.index(after: broadcastsIndex)) else {
            return nil
        }
        return pathComponents[pathComponents.index(after: broadcastsIndex)]
    }

    private func candidateSubtitle(
        postID: String,
        isPinned: Bool,
        variant: XAPIMediaVariant?,
        linkedBroadcastURL: URL?,
        fallbackPrefix: String
    ) -> String {
        if let variant {
            return "\(isPinned ? "Pinned " : "")X API media \(variant.contentType ?? "variant")"
        }

        if linkedBroadcastURL != nil {
            return "\(isPinned ? "Pinned " : "")X broadcast link"
        }

        return "\(fallbackPrefix) \(postID)"
    }

    private func galleryImages(from media: [XAPIMedia]) -> [GalleryImage] {
        media
            .filter { $0.type == "photo" }
            .compactMap { media in
                guard let url = media.fullSizePhotoURL else { return nil }
                return GalleryImage(
                    url: url,
                    width: media.width,
                    height: media.height,
                    altText: media.altText
                )
            }
    }

    private func mediaObjects(from post: XAPIPost, mediaByKey: [String: XAPIMedia]) -> [XAPIMedia] {
        post.attachments?.mediaKeys?
            .compactMap { mediaByKey[$0] }
            ?? []
    }

    private func deduplicatedCandidates(_ candidates: [BroadcastCandidate]) -> [BroadcastCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.dedupeKey).inserted }
    }

    private func recentStarshipFilmCandidates(
        prefersMP4Playback: Bool,
        report: inout DiscoveryReport
    ) async throws -> [BroadcastCandidate] {
        report.add("SpaceX CMS GET: \(starshipPlaylistURL.path)")
        let data = try await spaceXCMSData(from: starshipPlaylistURL, report: &report)
        let playlist = try spaceXCMSDecoder().decode(SpaceXMediaPlaylist.self, from: data)

        return playlist.media.compactMap { media in
            guard let streamURL = media.bestStreamURL(prefersMP4Playback: prefersMP4Playback) else { return nil }
            return BroadcastCandidate(
                statusURL: streamURL,
                dedupeKey: "spacex-media:\(media.documentID ?? media.link ?? streamURL.absoluteString)",
                streamURL: nil,
                title: media.title,
                subtitle: media.bestSubtitle,
                tweetText: media.bestDescription,
                publishedAt: media.date,
                thumbnailURL: media.poster?.bestURL,
                sourceKind: .hls,
                artworkName: media.uhdStreamingLink == nil && media.uhdLink == nil ? "film" : "play.tv",
                isAppendedSpaceXContent: true
            )
        }
    }

    private func starshipFlightTestCandidates(
        prefersMP4Playback: Bool,
        report: inout DiscoveryReport
    ) async throws -> [BroadcastCandidate] {
        report.add("SpaceX CMS GET: \(starshipFlightTestsPlaylistURL.path)")
        let data = try await spaceXCMSData(from: starshipFlightTestsPlaylistURL, report: &report)
        let playlist = try spaceXCMSDecoder().decode(SpaceXMediaPlaylist.self, from: data)

        let playlistCandidates: [BroadcastCandidate] = playlist.media.compactMap { media in
            guard let streamURL = media.bestStarshipFlightTestURL(prefersMP4Playback: prefersMP4Playback) else { return nil }
            return BroadcastCandidate(
                statusURL: streamURL,
                dedupeKey: "spacex-starship-flight-test:\(media.starshipFlightTestKey ?? media.documentID ?? media.link ?? streamURL.absoluteString)",
                streamURL: nil,
                title: media.title,
                subtitle: media.bestStarshipFlightTestSubtitle,
                tweetText: media.bestDescription,
                publishedAt: media.date,
                thumbnailURL: media.poster?.bestURL,
                sourceKind: .hls,
                artworkName: "play.tv",
                isAppendedSpaceXContent: true
            )
        }

        let launchTileCandidates = try await starshipFlightTestLaunchTileCandidates(report: &report)
        return deduplicatedCandidates(playlistCandidates + launchTileCandidates)
    }

    private func starshipFlightTestLaunchTileCandidates(report: inout DiscoveryReport) async throws -> [BroadcastCandidate] {
        report.add("SpaceX CMS GET: \(launchTilesURL.path)")
        let data = try await spaceXCMSData(from: launchTilesURL, report: &report)
        let tiles = try JSONDecoder().decode([SpaceXStarshipLaunchTile].self, from: data)
        let flightTestTiles = tiles
            .filter(\.isStarshipFlightTest)
            .sortedByPublishedDateDescending()

        let missionsByLink = try await starshipMissions(for: flightTestTiles.map(\.link))

        return flightTestTiles.map { tile in
            let mission = missionsByLink[tile.link]
            let broadcastURL = mission?.xBroadcastURL ?? tile.sourceURL
            return BroadcastCandidate(
                statusURL: broadcastURL,
                dedupeKey: "spacex-starship-flight-test:\(tile.starshipFlightTestKey)",
                streamURL: nil,
                title: tile.displayTitle,
                subtitle: "Starship flight test",
                tweetText: mission?.summary ?? tile.description,
                publishedAt: tile.publishedAt,
                thumbnailURL: mission?.imageURL ?? tile.imageURL,
                allowsDeferredStreamResolution: mission?.xBroadcastURL != nil,
                sourceKind: .xBroadcast,
                artworkName: "play.tv",
                isAppendedSpaceXContent: true
            )
        }
    }

    private func starshipMissions(for links: [String]) async throws -> [String: SpaceXStarshipMission] {
        try await withThrowingTaskGroup(of: (String, SpaceXStarshipMission?).self) { group in
            for link in links {
                group.addTask {
                    let url = missionsBaseURL.appendingPathComponent(link)
                    var request = URLRequest(url: url)
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("Mozilla/5.0 AppleTV SpaceXTV/1.0", forHTTPHeaderField: "User-Agent")
                    request.timeoutInterval = 15

                    let data: Data
                    let response: URLResponse
                    do {
                        (data, response) = try await session.data(for: request)
                    } catch {
                        return (link, nil)
                    }
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200 ..< 300).contains(httpResponse.statusCode) else {
                        return (link, nil)
                    }

                    return (link, try? JSONDecoder().decode(SpaceXStarshipMission.self, from: data))
                }
            }

            var missions: [String: SpaceXStarshipMission] = [:]
            for try await (link, mission) in group {
                if let mission {
                    missions[link] = mission
                }
            }
            return missions
        }
    }

    private func spaceXCMSData(from url: URL, report: inout DiscoveryReport) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 AppleTV SpaceXTV/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        report.add("SpaceX CMS HTTP \(statusCode), \(data.count) bytes")

        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            throw BroadcastDiscoveryError.invalidResponse
        }

        return data
    }

    private func spaceXCMSDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = SpaceXCMSDateParser.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid SpaceX CMS date: \(value)"
            )
        }
        return decoder
    }

    private func timelineFetchLimit(for broadcastLimit: Int) -> Int {
        min(
            max(broadcastLimit * timelineFetchMultiplier, minimumTimelineFetchLimit),
            maximumTimelineFetchLimit
        )
    }

    private func xAPIUser(username: String, bearerToken: String, report: inout DiscoveryReport) async throws -> XAPIUser {
        var components = URLComponents(string: "https://api.x.com/2/users/by/username/\(username)")!
        components.queryItems = [
            URLQueryItem(name: "user.fields", value: "pinned_tweet_id"),
        ]

        guard let url = components.url else {
            throw BroadcastDiscoveryError.invalidResponse
        }

        let data = try await xAPIData(from: url, bearerToken: bearerToken, report: &report)
        do {
            return try JSONDecoder().decode(XAPIUserResponse.self, from: data).data
        } catch {
            report.add("X API user decode failed: \(debugMessage(for: error))")
            throw BroadcastDiscoveryFailure(error: BroadcastDiscoveryError.invalidResponse, report: report)
        }
    }

    private func xAPIPosts(userID: String, maxResults: Int, bearerToken: String, report: inout DiscoveryReport) async throws -> XAPITimeline {
        var components = URLComponents(string: "https://api.x.com/2/users/\(userID)/tweets")!
        components.queryItems = [
            URLQueryItem(name: "max_results", value: "\(maxResults)"),
            URLQueryItem(name: "tweet.fields", value: "created_at,entities,attachments,referenced_tweets"),
            URLQueryItem(name: "expansions", value: "attachments.media_keys,referenced_tweets.id,referenced_tweets.id.attachments.media_keys"),
            URLQueryItem(name: "media.fields", value: "type,variants,preview_image_url,url,width,height,media_key,alt_text"),
            URLQueryItem(name: "exclude", value: "retweets,replies"),
        ]

        guard let url = components.url else {
            throw BroadcastDiscoveryError.invalidResponse
        }

        let data = try await xAPIData(from: url, bearerToken: bearerToken, report: &report)
        let response: XAPIPostsResponse
        do {
            response = try xAPIDecoder().decode(XAPIPostsResponse.self, from: data)
        } catch {
            report.add("X API timeline decode failed: \(debugMessage(for: error))")
            throw BroadcastDiscoveryFailure(error: BroadcastDiscoveryError.invalidResponse, report: report)
        }
        let mediaByKey = Dictionary(
            uniqueKeysWithValues: (response.includes?.media ?? []).map { ($0.mediaKey, $0) }
        )
        let includedPostsByID = Dictionary(
            uniqueKeysWithValues: (response.includes?.tweets ?? []).map { ($0.id, $0) }
        )

        return XAPITimeline(posts: response.data ?? [], mediaByKey: mediaByKey, includedPostsByID: includedPostsByID)
    }

    private func xAPIPosts(ids: [String], bearerToken: String, report: inout DiscoveryReport) async throws -> XAPITimeline {
        var components = URLComponents(string: "https://api.x.com/2/tweets")!
        components.queryItems = [
            URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
            URLQueryItem(name: "tweet.fields", value: "created_at,entities,attachments,referenced_tweets"),
            URLQueryItem(name: "expansions", value: "attachments.media_keys,referenced_tweets.id,referenced_tweets.id.attachments.media_keys"),
            URLQueryItem(name: "media.fields", value: "type,variants,preview_image_url,url,width,height,media_key,alt_text"),
        ]

        guard let url = components.url else {
            throw BroadcastDiscoveryError.invalidResponse
        }

        let data = try await xAPIData(from: url, bearerToken: bearerToken, report: &report)
        let response: XAPIPostsResponse
        do {
            response = try xAPIDecoder().decode(XAPIPostsResponse.self, from: data)
        } catch {
            report.add("X API pinned post decode failed: \(debugMessage(for: error))")
            throw BroadcastDiscoveryFailure(error: BroadcastDiscoveryError.invalidResponse, report: report)
        }
        let mediaByKey = Dictionary(
            uniqueKeysWithValues: (response.includes?.media ?? []).map { ($0.mediaKey, $0) }
        )
        let includedPostsByID = Dictionary(
            uniqueKeysWithValues: (response.includes?.tweets ?? []).map { ($0.id, $0) }
        )

        return XAPITimeline(posts: response.data ?? [], mediaByKey: mediaByKey, includedPostsByID: includedPostsByID)
    }

    private func xAPIData(from url: URL, bearerToken: String, report: inout DiscoveryReport) async throws -> Data {
        report.add("X API GET: \(url.path)")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        report.add("X API HTTP \(statusCode), \(data.count) bytes")

        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            if let apiError = try? JSONDecoder().decode(XAPIErrorResponse.self, from: data),
               let firstError = apiError.errors?.first ?? apiError.detail.map({ XAPIError(detail: $0, title: apiError.title) }) {
                throw XAPIRequestError(message: firstError.detail ?? firstError.title ?? "X API request failed")
            }
            throw BroadcastDiscoveryError.invalidResponse
        }

        return data
    }

    private func xAPIDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = XAPIDateParser.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid X API date: \(value)"
            )
        }
        return decoder
    }

    private func debugMessage(for error: Error) -> String {
        if let decodingError = error as? DecodingError {
            return decodingError.debugDescription
        }
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private func bestVariant(from media: [XAPIMedia]) -> XAPIMediaVariant? {
        let variants = media.flatMap { $0.variants ?? [] }
            .filter { $0.url.scheme?.hasPrefix("http") == true }

        let mp4Variants = variants
            .filter { $0.contentType == "video/mp4" || $0.url.pathExtension == "mp4" }
            .sorted { ($0.bitRate ?? 0) > ($1.bitRate ?? 0) }

        if let mp4 = mp4Variants.first {
            return mp4
        }

        if let hls = variants.first(where: { variant in
            variant.contentType == "application/x-mpegURL" || variant.url.pathExtension == "m3u8"
        }) {
            return hls
        }

        return nil
    }
}

private struct BroadcastCandidate {
    var statusURL: URL
    var dedupeKey: String
    var streamURL: URL?
    var title: String = "SpaceX Broadcast"
    var subtitle: String
    var tweetText: String? = nil
    var publishedAt: Date? = nil
    var thumbnailURL: URL? = nil
    var galleryImages: [GalleryImage] = []
    var allowsDeferredStreamResolution: Bool = false
    var isPinned: Bool = false
    var sourceKind: Broadcast.SourceKind = .xBroadcast
    var artworkName: String = "antenna.radiowaves.left.and.right"
    var isAppendedSpaceXContent: Bool = false

    init(
        statusURL: URL,
        dedupeKey: String? = nil,
        streamURL: URL?,
        title: String = "SpaceX Broadcast",
        subtitle: String,
        tweetText: String? = nil,
        publishedAt: Date? = nil,
        thumbnailURL: URL? = nil,
        galleryImages: [GalleryImage] = [],
        allowsDeferredStreamResolution: Bool = false,
        isPinned: Bool = false,
        sourceKind: Broadcast.SourceKind = .xBroadcast,
        artworkName: String = "antenna.radiowaves.left.and.right",
        isAppendedSpaceXContent: Bool = false
    ) {
        self.statusURL = statusURL
        if let dedupeKey, !dedupeKey.isEmpty {
            self.dedupeKey = dedupeKey
        } else {
            self.dedupeKey = "status:\(statusURL.absoluteString)"
        }
        self.streamURL = streamURL
        self.title = title
        self.subtitle = subtitle
        self.tweetText = tweetText
        self.publishedAt = publishedAt
        self.thumbnailURL = thumbnailURL
        self.galleryImages = galleryImages
        self.allowsDeferredStreamResolution = allowsDeferredStreamResolution
        self.isPinned = isPinned
        self.sourceKind = sourceKind
        self.artworkName = artworkName
        self.isAppendedSpaceXContent = isAppendedSpaceXContent
    }
}

private struct DiscoveredBroadcastItem {
    var candidate: BroadcastCandidate
    var broadcast: Broadcast
}

private extension BroadcastCandidate {
    func isSortedBefore(_ rhs: BroadcastCandidate) -> Bool {
        if isPinned != rhs.isPinned {
            return isPinned
        }

        switch (publishedAt, rhs.publishedAt) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return title.localizedStandardCompare(rhs.title) == .orderedAscending
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}

private extension Array where Element == BroadcastCandidate {
    func sortedByPublishedDateDescending() -> [BroadcastCandidate] {
        sorted { $0.isSortedBefore($1) }
    }
}

struct BroadcastDiscoveryResult {
    var broadcasts: [Broadcast]
    var report: DiscoveryReport
}

struct DiscoveryReport: Equatable {
    private(set) var lines: [String] = []
    private(set) var xAPICacheGeneratedAt: Date?

    mutating func add(_ line: String) {
        lines.append(line)
        print("[SpaceXTV] \(line)")
    }

    mutating func setXAPICacheGeneratedAt(_ date: Date?) {
        xAPICacheGeneratedAt = date
    }
}

struct BroadcastDiscoveryFailure: LocalizedError {
    var error: LocalizedError
    var report: DiscoveryReport

    var errorDescription: String? {
        error.errorDescription
    }
}

private struct XAPIUserResponse: Decodable {
    var data: XAPIUser
}

private struct XAPIUser: Decodable {
    var id: String
    var username: String?
    var name: String?
    var pinnedTweetID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case name
        case pinnedTweetID = "pinned_tweet_id"
    }
}

private struct XAPIPostsResponse: Decodable {
    var data: [XAPIPost]?
    var includes: XAPIIncludes?
}

private struct XAPICacheResponse: Decodable {
    var generatedAt: Date?
    var source: String?
    var user: XAPIUserResponse
    var pinned: XAPIPostsResponse?
    var timeline: XAPIPostsResponse

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case source
        case user
        case pinned
        case timeline
    }
}

private struct XAPIPost: Decodable {
    var id: String
    var text: String?
    var createdAt: Date?
    var entities: XAPIPostEntities?
    var attachments: XAPIPostAttachments?
    var referencedTweets: [XAPIReferencedTweet]?

    var quotedTweetID: String? {
        referencedTweets?.first { $0.type == "quoted" }?.id
    }

    var broadcastURLFromEntities: URL? {
        entities?.urls?
            .compactMap(\.bestURL)
            .first { url in
                guard let host = url.host?.lowercased() else {
                    return false
                }
                return (host == "x.com" || host == "twitter.com" || host.hasSuffix(".x.com") || host.hasSuffix(".twitter.com"))
                    && url.path.hasPrefix("/i/broadcasts/")
            }
    }

    var thumbnailURLFromEntities: URL? {
        entities?.urls?
            .flatMap { $0.images ?? [] }
            .sorted { $0.area > $1.area }
            .compactMap(\.url)
            .first
    }

    var urlImageCount: Int {
        entities?.urls?.reduce(0) { $0 + ($1.images?.count ?? 0) } ?? 0
    }

    var broadcastTitle: String {
        guard let text else {
            return "SpaceX Broadcast"
        }

        let firstLine = text
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return firstLine.isEmpty ? "SpaceX Broadcast" : firstLine
    }

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case createdAt = "created_at"
        case entities
        case attachments
        case referencedTweets = "referenced_tweets"
    }
}

private struct XAPIReferencedTweet: Decodable {
    var type: String
    var id: String
}

private struct XAPIPostEntities: Decodable {
    var urls: [XAPIURL]?
}

private struct XAPIURL: Decodable {
    var url: URL?
    var expandedURL: URL?
    var unwoundURL: URL?
    var images: [XAPIURLImage]?

    var bestURL: URL? {
        unwoundURL ?? expandedURL ?? url
    }

    enum CodingKeys: String, CodingKey {
        case url
        case expandedURL = "expanded_url"
        case unwoundURL = "unwound_url"
        case images
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = Self.decodeURL(forKey: .url, from: container)
        expandedURL = Self.decodeURL(forKey: .expandedURL, from: container)
        unwoundURL = Self.decodeURL(forKey: .unwoundURL, from: container)
        images = try? container.decodeIfPresent([XAPIURLImage].self, forKey: .images)
    }

    private static func decodeURL(forKey key: CodingKeys, from container: KeyedDecodingContainer<CodingKeys>) -> URL? {
        guard let string = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return URL(string: string)
    }
}

private struct XAPIURLImage: Decodable {
    var url: URL?
    var width: Int?
    var height: Int?

    var area: Int {
        (width ?? 0) * (height ?? 0)
    }

    enum CodingKeys: String, CodingKey {
        case url
        case width
        case height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? container.decodeIfPresent(String.self, forKey: .url) {
            url = URL(string: string)
        } else {
            url = nil
        }
        width = try? container.decodeIfPresent(Int.self, forKey: .width)
        height = try? container.decodeIfPresent(Int.self, forKey: .height)
    }
}

private struct XAPIPostAttachments: Decodable {
    var mediaKeys: [String]?

    enum CodingKeys: String, CodingKey {
        case mediaKeys = "media_keys"
    }
}

private struct XAPIIncludes: Decodable {
    var media: [XAPIMedia]?
    var tweets: [XAPIPost]?
}

private struct XAPIMedia: Decodable {
    var mediaKey: String
    var type: String?
    var variants: [XAPIMediaVariant]?
    var previewImageURL: URL?
    var url: URL?
    var width: Int?
    var height: Int?
    var altText: String?

    var thumbnailURL: URL? {
        previewImageURL ?? url
    }

    var fullSizePhotoURL: URL? {
        guard type == "photo" else { return nil }
        guard let url else { return nil }
        return Self.photoURL(url, name: "orig") ?? url
    }

    enum CodingKeys: String, CodingKey {
        case mediaKey = "media_key"
        case type
        case variants
        case previewImageURL = "preview_image_url"
        case url
        case width
        case height
        case altText = "alt_text"
    }

    private static func photoURL(_ url: URL, name: String) -> URL? {
        guard url.host?.lowercased().hasSuffix("twimg.com") == true,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        var queryItems = components.queryItems ?? []
        if let index = queryItems.firstIndex(where: { $0.name == "name" }) {
            queryItems[index].value = name
        } else {
            queryItems.append(URLQueryItem(name: "name", value: name))
        }
        components.queryItems = queryItems
        return components.url
    }
}

private struct XAPIMediaVariant: Decodable {
    var bitRate: Int?
    var contentType: String?
    var url: URL

    var debugDescription: String {
        let bitrate = bitRate.map { "\($0)bps" } ?? "adaptive"
        let type = contentType ?? url.pathExtension
        let pathHint = url.pathComponents.suffix(3).joined(separator: "/")
        return "\(type) \(bitrate) \(pathHint)"
    }

    enum CodingKeys: String, CodingKey {
        case bitRate = "bit_rate"
        case contentType = "content_type"
        case url
    }
}

private struct XAPITimeline {
    var posts: [XAPIPost]
    var mediaByKey: [String: XAPIMedia]
    var includedPostsByID: [String: XAPIPost]

    static let empty = XAPITimeline(posts: [], mediaByKey: [:], includedPostsByID: [:])
}

private struct XAPIErrorResponse: Decodable {
    var title: String?
    var detail: String?
    var errors: [XAPIError]?
}

private struct XAPIError: Decodable {
    var detail: String?
    var title: String?
}

private struct XAPIRequestError: LocalizedError {
    var message: String

    var errorDescription: String? {
        message
    }
}

private struct SpaceXMediaPlaylist: Decodable {
    var title: String
    var link: String
    var media: [SpaceXMediaItem]
}

private struct SpaceXMediaItem: Decodable {
    var documentID: String?
    var title: String
    var link: String?
    var shortDescription: String?
    var description: String?
    var date: Date?
    var hdLink: URL?
    var fhdLink: URL?
    var uhdLink: URL?
    var hdStreamingLink: URL?
    var fhdStreamingLink: URL?
    var uhdStreamingLink: URL?
    var autoStreamingLink: URL?
    var poster: SpaceXMediaPoster?

    var bestStreamURL: URL? {
        autoStreamingLink ?? fhdStreamingLink ?? hdStreamingLink ?? uhdStreamingLink ?? fhdLink ?? hdLink ?? uhdLink
    }

    func bestStreamURL(prefersMP4Playback: Bool) -> URL? {
        if prefersMP4Playback {
            return uhdLink ?? fhdLink ?? hdLink ?? autoStreamingLink ?? uhdStreamingLink ?? fhdStreamingLink ?? hdStreamingLink
        }
        return bestStreamURL
    }

    func bestStarshipFlightTestURL(prefersMP4Playback: Bool) -> URL? {
        if prefersMP4Playback {
            return uhdLink ?? fhdLink ?? hdLink ?? autoStreamingLink ?? uhdStreamingLink ?? fhdStreamingLink ?? hdStreamingLink
        }
        return bestStreamURL
    }

    var bestSubtitle: String {
        if uhdStreamingLink != nil || uhdLink != nil {
            return "Starship film · 4K"
        }
        return "Starship film"
    }

    var bestStarshipFlightTestSubtitle: String {
        if uhdStreamingLink != nil || uhdLink != nil {
            return "Starship flight test · 4K"
        }
        return "Starship flight test"
    }

    var bestDescription: String? {
        [shortDescription, description?.strippingHTMLTags()]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    var starshipFlightTestKey: String? {
        StarshipFlightTestKey.normalized(link: link, title: title)
    }

    enum CodingKeys: String, CodingKey {
        case documentID = "documentId"
        case title
        case link
        case shortDescription
        case description
        case date
        case hdLink
        case fhdLink
        case uhdLink
        case hdStreamingLink
        case fhdStreamingLink
        case uhdStreamingLink
        case autoStreamingLink
        case poster
    }
}

private struct SpaceXMediaPoster: Decodable {
    var url: URL?
    var formats: Formats?

    var bestURL: URL? {
        formats?.large?.url ?? formats?.medium?.url ?? url
    }

    struct Formats: Decodable {
        var large: Format?
        var medium: Format?
        var small: Format?
    }

    struct Format: Decodable {
        var url: URL?
    }
}

private struct SpaceXStarshipLaunchTile: Decodable {
    var title: String
    var shortTitle: String?
    var link: String
    var vehicle: String?
    var launchSite: String?
    var launchDate: String?
    var launchTime: String?
    var imageDesktop: SpaceXLaunchImage?

    var displayTitle: String {
        guard let shortTitle, !shortTitle.isEmpty else { return title }
        return shortTitle
    }

    var description: String? {
        [vehicle, launchSite]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var isStarshipFlightTest: Bool {
        vehicle == "Starship" && StarshipFlightTestKey.normalized(link: link, title: title) != nil
    }

    var starshipFlightTestKey: String {
        StarshipFlightTestKey.normalized(link: link, title: title) ?? link
    }

    var sourceURL: URL {
        URL(string: "https://www.spacex.com/launches/\(link)") ?? URL(string: "https://www.spacex.com/launches")!
    }

    var imageURL: URL? {
        imageDesktop?.formats?.large?.url ?? imageDesktop?.url
    }

    var publishedAt: Date? {
        guard let launchDate else { return nil }
        return SpaceXLaunchTileDateParser.date(from: "\(launchDate) \(launchTime ?? "00:00:00")")
    }
}

private struct SpaceXStarshipMission: Decodable {
    var imageDesktop: SpaceXLaunchImage?
    var webcasts: [SpaceXWebcast]?
    var paragraphs: [SpaceXParagraph]?

    var xBroadcastURL: URL? {
        webcasts?
            .first { $0.streamingVideoType == "x.com" }?
            .xBroadcastURL
    }

    var imageURL: URL? {
        imageDesktop?.formats?.large?.url ?? imageDesktop?.url
    }

    var summary: String? {
        paragraphs?
            .compactMap { $0.content.strippingHTMLTags().trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

private struct SpaceXWebcast: Decodable {
    var videoId: String?
    var streamingVideoType: String?

    var xBroadcastURL: URL? {
        guard let videoId, !videoId.isEmpty else { return nil }
        return URL(string: "https://x.com/i/broadcasts/\(videoId)")
    }
}

private struct SpaceXParagraph: Decodable {
    var content: String
}

private struct SpaceXLaunchImage: Decodable {
    var url: URL?
    var formats: SpaceXLaunchImageFormats?
}

private struct SpaceXLaunchImageFormats: Decodable {
    var large: SpaceXLaunchImageVariant?
}

private struct SpaceXLaunchImageVariant: Decodable {
    var url: URL?
}

private enum StarshipFlightTestKey {
    static func normalized(link: String?, title: String) -> String? {
        let normalizedLink = link?.lowercased()
            .replacingOccurrences(of: "starship-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let normalizedLink, normalizedLink == "flight-test" {
            return "flight-1"
        }
        if let normalizedLink,
           normalizedLink.hasPrefix("flight-"),
           normalizedLink.dropFirst("flight-".count).allSatisfy(\.isNumber) {
            return normalizedLink
        }
        if let normalizedLink,
           normalizedLink.hasPrefix("sn"),
           normalizedLink.dropFirst(2).allSatisfy(\.isNumber) {
            return normalizedLink
        }
        if normalizedLink == "starhopper" {
            return "starhopper"
        }

        let lowercaseTitle = title.lowercased()
        if lowercaseTitle.contains("starhopper") {
            return "starhopper"
        }
        if let snRange = lowercaseTitle.range(of: #"sn\s*\d+"#, options: .regularExpression) {
            return lowercaseTitle[snRange]
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\t", with: "")
        }

        let ordinals = [
            "first": 1,
            "second": 2,
            "third": 3,
            "fourth": 4,
            "fifth": 5,
            "sixth": 6,
            "seventh": 7,
            "eighth": 8,
            "ninth": 9,
            "tenth": 10,
            "eleventh": 11,
            "twelfth": 12,
        ]
        for (word, number) in ordinals where lowercaseTitle.contains(word) && lowercaseTitle.contains("flight test") {
            return "flight-\(number)"
        }

        return nil
    }
}

private extension Array where Element == SpaceXStarshipLaunchTile {
    func sortedByPublishedDateDescending() -> [SpaceXStarshipLaunchTile] {
        sorted { lhs, rhs in
            switch (lhs.publishedAt, rhs.publishedAt) {
            case let (lhsDate?, rhsDate?):
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            }
        }
    }
}

private enum SpaceXCMSDateParser {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func date(from value: String) -> Date? {
        dayFormatter.date(from: value) ?? XAPIDateParser.date(from: value)
    }
}

private enum SpaceXLaunchTileDateParser {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Chicago")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func date(from value: String) -> Date? {
        formatter.date(from: value)
    }
}

private enum XAPIDateParser {
    private static let fractionalSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let internetDateTimeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from value: String) -> Date? {
        fractionalSecondsFormatter.date(from: value) ?? internetDateTimeFormatter.date(from: value)
    }
}

private extension String {
    func strippingHTMLTags() -> String {
        replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}

private extension DecodingError {
    var debugDescription: String {
        switch self {
        case .typeMismatch(_, let context),
             .valueNotFound(_, let context),
             .keyNotFound(_, let context),
             .dataCorrupted(let context):
            let path = context.codingPath
                .map(\.stringValue)
                .joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default:
            return localizedDescription
        }
    }
}
