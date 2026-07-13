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
    private let starshipTalksPlaylistURL = URL(string: "https://content.spacex.com/api/spacex-website/media-playlist/starship-talks")!
    private let launchTilesURL = URL(string: "https://content.spacex.com/api/spacex-website/launches-page-tiles")!
    private let missionsBaseURL = URL(string: "https://content.spacex.com/api/spacex-website/missions/")!

    var resolver: BroadcastResolver {
        BroadcastResolver(session: session)
    }

    func discoverRecentSpaceXBroadcasts(
        limit: Int = 10,
        xAPIBearerToken: String?,
        prefersMP4Playback: Bool = true,
        cardCache: inout CardResolutionCache
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

        return try await discoveryResult(from: candidates, prefersMP4Playback: prefersMP4Playback, cardCache: &cardCache, report: &report)
    }

    func discoverRecentSpaceXBroadcasts(
        limit: Int = 10,
        xAPICacheURL: URL,
        prefersMP4Playback: Bool = true,
        cardCache: inout CardResolutionCache
    ) async throws -> BroadcastDiscoveryResult {
        var report = DiscoveryReport()
        report.add("Starting SpaceX post discovery")
        report.add("SpaceX CMS playback preference: \(prefersMP4Playback ? "MP4" : "HLS")")
        let timelineLimit = timelineFetchLimit(for: limit)
        report.add("X API cache target timeline limit: \(timelineLimit)")

        var starshipCache: StarshipCacheSnapshot?
        let candidates = try await recentSpaceXBroadcastCandidatesFromCache(
            cacheURL: xAPICacheURL,
            timelineLimit: timelineLimit,
            cardCache: &cardCache,
            report: &report,
            starshipCache: &starshipCache
        )
        report.add("Candidate statuses: \(candidates.count)")

        return try await discoveryResult(
            from: candidates,
            prefersMP4Playback: prefersMP4Playback,
            cardCache: &cardCache,
            report: &report,
            starshipCache: starshipCache
        )
    }

    private func discoveryResult(
        from initialCandidates: [BroadcastCandidate],
        prefersMP4Playback: Bool,
        cardCache: inout CardResolutionCache,
        report: inout DiscoveryReport,
        starshipCache: StarshipCacheSnapshot? = nil
    ) async throws -> BroadcastDiscoveryResult {
        var candidates = deduplicatedCandidates(initialCandidates)
        var appendedStarshipFilmCandidates: [BroadcastCandidate] = []
        var appendedStarshipTalkCandidates: [BroadcastCandidate] = []
        var appendedStarshipFlightTestCandidates: [BroadcastCandidate] = []
        do {
            appendedStarshipFilmCandidates = try await recentStarshipFilmCandidates(
                prefersMP4Playback: prefersMP4Playback,
                report: &report,
                cachedPlaylist: starshipCache?.playlist
            )
            report.add("Starship film candidates: \(appendedStarshipFilmCandidates.count)")
        } catch {
            report.add("Starship film discovery failed: \(debugMessage(for: error))")
        }
        do {
            appendedStarshipTalkCandidates = try await recentStarshipTalkCandidates(
                prefersMP4Playback: prefersMP4Playback,
                report: &report,
                cachedPlaylist: starshipCache?.talksPlaylist
            )
            report.add("Starship talk candidates: \(appendedStarshipTalkCandidates.count)")
        } catch {
            report.add("Starship talk discovery failed: \(debugMessage(for: error))")
        }
        do {
            appendedStarshipFlightTestCandidates = try await starshipFlightTestCandidates(
                prefersMP4Playback: prefersMP4Playback,
                report: &report,
                cache: starshipCache
            )
            report.add("Starship flight test candidates: \(appendedStarshipFlightTestCandidates.count)")
        } catch {
            report.add("Starship flight test discovery failed: \(debugMessage(for: error))")
        }
        candidates = candidates.sortedByPublishedDateDescending()
        let mergedCandidateCount = candidates.count
            + appendedStarshipFilmCandidates.count
            + appendedStarshipTalkCandidates.count
            + appendedStarshipFlightTestCandidates.count
        report.add("Merged candidates: \(mergedCandidateCount)")

        guard mergedCandidateCount > 0 else {
            throw BroadcastDiscoveryFailure(error: BroadcastDiscoveryError.noStatusesFound, report: report)
        }

        var selectedXItems: [DiscoveredBroadcastItem] = []
        let xCandidates = candidates.filter { !$0.isAppendedSpaceXContent }
        for (index, candidate) in xCandidates.prefix(80).enumerated() {
            let statusURL = candidate.statusURL

            // Fast path: if we previously checked this exact card (same originating post + same content fingerprint),
            // reuse the prior classification / resolution and skip network work.
            // Multi-media posts are classified from attachments on the candidate itself. Prefer that
            // over a stale cached single-video/gallery label from older processor versions.
            if candidate.requiresMediaCollection {
                let collectionItems = candidate.playableCollectionMediaItems
                let omittedVideos = candidate.mediaItems.filter { $0.kind == .video && $0.streamURL == nil }.count
                if omittedVideos > 0 {
                    report.add(
                        "Omitting \(omittedVideos) video(s) without API stream from collection \(statusURL.lastPathComponent)"
                    )
                }
                let collectionStreamURL = collectionItems.first(where: { $0.kind == .video })?.streamURL
                if cardCache.resolution(for: candidate) != nil {
                    report.add("Using cached card check for \(statusURL.lastPathComponent)")
                    report.recordCardCheckHit()
                } else {
                    report.recordCardCheckMiss()
                    cardCache.record(
                        for: candidate,
                        streamURL: collectionStreamURL,
                        thumbnailURL: candidate.thumbnailURL ?? candidate.galleryImages.first?.url,
                        isLive: nil,
                        contentKind: .collection,
                        validFor: collectionStreamURL != nil ? .directMedia : nil
                    )
                }
                let summary = PostMediaItem.summaryLabel(for: collectionItems) ?? "mixed media"
                report.add("Adding collection \(index + 1): \(statusURL.lastPathComponent), \(summary)")
                selectedXItems.append(
                    DiscoveredBroadcastItem(
                        candidate: candidate,
                        broadcast: collection(from: candidate, mediaItems: collectionItems)
                    )
                )
                continue
            }

            if let cached = cardCache.resolution(for: candidate) {
                report.add("Using cached card check for \(statusURL.lastPathComponent)")
                report.recordCardCheckHit()
                if !cached.hasUsableContent {
                    // We previously probed this post and it contained neither a broadcast nor a gallery.
                    continue
                }
                switch cached.contentKind {
                case .gallery:
                    selectedXItems.append(DiscoveredBroadcastItem(candidate: candidate, broadcast: gallery(from: candidate)))
                case .collection:
                    // Candidate media no longer looks multi-item; fall through to video reconstruction.
                    selectedXItems.append(DiscoveredBroadcastItem(
                        candidate: candidate,
                        broadcast: broadcast(
                            from: candidate,
                            streamURL: cached.streamURL,
                            thumbnailURL: candidate.thumbnailURL ?? cached.thumbnailURL,
                            isLive: cached.isLive
                        )
                    ))
                case .video, .none:
                    selectedXItems.append(DiscoveredBroadcastItem(
                        candidate: candidate,
                        broadcast: broadcast(
                            from: candidate,
                            streamURL: cached.streamURL,
                            thumbnailURL: candidate.thumbnailURL ?? cached.thumbnailURL,
                            isLive: cached.isLive
                        )
                    ))
                }
                continue
            }

            report.recordCardCheckMiss()

            if !candidate.galleryImages.isEmpty, candidate.streamURL == nil, !candidate.allowsDeferredStreamResolution {
                report.add("Adding gallery \(index + 1): \(statusURL.lastPathComponent), images \(candidate.galleryImages.count)")
                cardCache.record(
                    for: candidate,
                    streamURL: nil,
                    thumbnailURL: candidate.thumbnailURL ?? candidate.galleryImages.first?.url,
                    isLive: nil,
                    contentKind: .gallery
                )
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
                    cardCache.record(
                        for: candidate,
                        streamURL: apiStreamURL,
                        thumbnailURL: candidate.thumbnailURL,
                        isLive: nil,
                        contentKind: .video,
                        validFor: .directMedia
                    )
                } else {
                    let resolved = try await resolver.resolveStatusURL(statusURL)
                    streamURL = resolved.streamURL
                    resolvedThumbnailURL = resolved.thumbnailURL
                    isLive = resolved.isLive
                    report.add("Found page stream for \(statusURL.lastPathComponent)")
                    report.add("Page thumbnail for \(statusURL.lastPathComponent): \(resolvedThumbnailURL == nil ? "missing" : "present")")
                    cardCache.record(
                        for: candidate,
                        streamURL: streamURL,
                        thumbnailURL: resolvedThumbnailURL,
                        isLive: isLive,
                        contentKind: .video,
                        validFor: isLive == true ? .liveStream : .resolvedStream
                    )
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
                    cardCache.record(
                        for: candidate,
                        streamURL: nil,
                        thumbnailURL: nil,
                        isLive: nil,
                        contentKind: .video,
                        validFor: .failedProbe
                    )
                    selectedXItems.append(DiscoveredBroadcastItem(candidate: candidate, broadcast: broadcast(from: candidate, streamURL: nil)))
                } else {
                    report.add("No stream for \(statusURL.lastPathComponent): \(debugMessage(for: error))")
                    cardCache.record(
                        for: candidate,
                        streamURL: nil,
                        thumbnailURL: nil,
                        isLive: nil,
                        contentKind: .video,
                        hasUsableContent: false,
                        validFor: .failedProbe
                    )
                }
            }
        }

        report.addCardCheckSummaryIfNeeded()

        let selectedStarshipItems = (
            appendedStarshipFilmCandidates.sortedByPublishedDateDescending()
            + appendedStarshipFlightTestCandidates.sortedByPublishedDateDescending()
            + appendedStarshipTalkCandidates.sortedByPublishedDateDescending()
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
        // Holding tiles without a webcast, or deferred X webcasts that have not produced a stream yet.
        let isUpcoming = isLive != true
            && (candidate.isUpcoming || (streamURL == nil && candidate.allowsDeferredStreamResolution))
        return Broadcast(
            title: candidate.title,
            subtitle: candidate.subtitle,
            sourceURL: candidate.statusURL,
            sourceKind: candidate.sourceKind,
            streamURL: streamURL,
            fallbackStreamURL: candidate.fallbackStreamURL,
            tweetText: candidate.tweetText,
            publishedAt: candidate.publishedAt,
            thumbnailURL: thumbnailURL ?? candidate.thumbnailURL,
            galleryImages: candidate.galleryImages,
            mediaItems: candidate.mediaItems,
            artworkName: candidate.artworkName,
            isPinned: candidate.isPinned,
            isLive: isLive,
            isUpcoming: isUpcoming
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
            mediaItems: candidate.mediaItems,
            artworkName: "photo.on.rectangle",
            isPinned: candidate.isPinned
        )
    }

    private func collection(from candidate: BroadcastCandidate, mediaItems: [PostMediaItem]? = nil) -> Broadcast {
        // Only include videos with a concrete API stream so the picker never offers
        // items that would all fall back to scraping the same parent status URL.
        let items = mediaItems ?? candidate.playableCollectionMediaItems
        let streamURL = items.first(where: { $0.kind == .video })?.streamURL ?? candidate.streamURL
        let galleryImages = items.compactMap { item -> GalleryImage? in
            guard item.kind == .photo else { return nil }
            guard let url = item.photoURL ?? item.thumbnailURL else { return nil }
            return GalleryImage(
                url: url,
                width: item.width,
                height: item.height,
                altText: item.altText
            )
        }
        return Broadcast(
            title: candidate.title,
            subtitle: candidate.subtitle,
            sourceURL: candidate.statusURL,
            sourceKind: .xBroadcast,
            contentKind: .collection,
            streamURL: streamURL,
            fallbackStreamURL: candidate.fallbackStreamURL,
            tweetText: candidate.tweetText,
            publishedAt: candidate.publishedAt,
            thumbnailURL: candidate.thumbnailURL ?? galleryImages.first?.url,
            galleryImages: galleryImages.isEmpty ? candidate.galleryImages : galleryImages,
            mediaItems: items,
            artworkName: "rectangle.stack",
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

    private func recentSpaceXBroadcastCandidatesFromCache(
        cacheURL: URL,
        timelineLimit: Int,
        cardCache: inout CardResolutionCache,
        report: inout DiscoveryReport,
        starshipCache: inout StarshipCacheSnapshot?
    ) async throws -> [BroadcastCandidate] {
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
            cache = try spaceXCMSDecoder().decode(XAPICacheResponse.self, from: data)
        } catch {
            report.add("X API cache decode failed: \(debugMessage(for: error))")
            throw BroadcastDiscoveryFailure(error: BroadcastDiscoveryError.invalidResponse, report: report)
        }

        if let generatedAt = cache.generatedAt {
            report.setXAPICacheGeneratedAt(generatedAt)
            report.add("X API cache generated at: \(ISO8601DateFormatter().string(from: generatedAt))")
        }
        report.add("X API cache source: \(cache.source ?? "unknown")")
        if let playlist = cache.starshipPlaylist,
           let flightTestsPlaylist = cache.starshipFlightTestsPlaylist,
           let launchTiles = cache.starshipLaunchTiles,
           let missions = cache.starshipMissions {
            let talksPlaylist = cache.starshipTalksPlaylist
            starshipCache = StarshipCacheSnapshot(
                playlist: playlist,
                flightTestsPlaylist: flightTestsPlaylist,
                talksPlaylist: talksPlaylist,
                launchTiles: launchTiles,
                missions: missions
            )
            let talksCount = talksPlaylist?.media.count ?? 0
            report.add(
                "X API cache supplied SpaceX CMS data: \(playlist.media.count) films, "
                    + "\(talksCount) talks, "
                    + "\(flightTestsPlaylist.media.count) flight test films, "
                    + "\(launchTiles.count) launch tiles, \(missions.count) missions"
            )
            if talksPlaylist == nil {
                report.add("X API cache has no Starship talks playlist; talks will use live SpaceX CMS")
            }
        } else {
            report.add("X API cache has no complete SpaceX CMS snapshot; using live SpaceX CMS")
        }
        if let processedCards = cache.processedCards,
           processedCards.version == cardCache.version {
            let mergedCount = cardCache.merge(processedCards)
            report.add("X API cache supplied \(processedCards.entries.count) processed card checks; merged \(mergedCount)")
        }

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

        return deduplicatedXCandidates(pinnedCandidates + timelineCandidates)
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
        let referencedContentPost = post.referencedContentTweetID.flatMap { timeline.includedPostsByID[$0] }
        let linkedBroadcastURL = post.broadcastURLFromEntities ?? referencedContentPost?.broadcastURLFromEntities

        let ownMedia = mediaObjects(from: post, mediaByKey: timeline.mediaByKey)
        let referencedContentMedia = referencedContentPost.map { mediaObjects(from: $0, mediaByKey: timeline.mediaByKey) } ?? []
        let media = ownMedia.isEmpty ? referencedContentMedia : ownMedia
        let mediaSource = ownMedia.isEmpty && !referencedContentMedia.isEmpty
            ? "\(post.referencedContentTweetType ?? "referenced") status \(referencedContentPost?.id ?? "")"
            : "status"
        let items = postMediaItems(from: media)
        let galleryImages = galleryImages(from: media)
        let firstVideoStreamURL = items.first(where: { $0.kind == .video && $0.streamURL != nil })?.streamURL
        let firstVideoVariant = media
            .filter(isVideoMedia)
            .compactMap { bestVariant(from: $0) }
            .first
        let thumbnailURL = media.compactMap(\.thumbnailURL).first
            ?? galleryImages.first?.url
            ?? post.thumbnailURLFromEntities
            ?? referencedContentPost?.thumbnailURLFromEntities

        logVideoVariants(for: post.id, media: media, selectedVariant: firstVideoVariant, report: &report)
        if items.filter({ $0.kind == .video }).count > 1 || (items.contains(where: { $0.kind == .video }) && !galleryImages.isEmpty) {
            let summary = PostMediaItem.summaryLabel(for: items) ?? "mixed media"
            report.add("Multi-media collection for \(post.id) from \(mediaSource): \(summary)")
        } else if let firstVideoVariant {
            report.add("API media variant for \(post.id) from \(mediaSource): \(firstVideoVariant.debugDescription)")
        } else if let linkedBroadcastURL {
            report.add("Broadcast link for \(post.id): \(linkedBroadcastURL.absoluteString)")
        } else if !galleryImages.isEmpty {
            report.add("Image gallery for \(post.id) from \(mediaSource): \(galleryImages.count) photos")
        } else {
            report.add("No API media variant for \(post.id); will page-probe")
        }
        if let referencedContentTweetID = post.referencedContentTweetID {
            report.add("\(post.referencedContentTweetType ?? "Referenced") status for \(post.id): \(referencedContentTweetID), media objects \(referencedContentMedia.count)")
        }
        report.add("Thumbnail for \(post.id): \(thumbnailURL == nil ? "missing" : "present"), media objects \(media.count), media items \(items.count), URL images \(post.urlImageCount)")

        let subtitlePrefix = isPinned ? "Pinned SpaceX status" : "X status"
        let fp = contentFingerprint(
            post: post,
            media: media,
            referencedContentPost: referencedContentPost,
            referencedContentMedia: referencedContentMedia,
            linkedBroadcastURL: linkedBroadcastURL
        )
        return BroadcastCandidate(
            statusURL: linkedBroadcastURL ?? statusURL,
            dedupeKey: candidateDedupeKey(
                post: post,
                statusURL: statusURL,
                linkedBroadcastURL: linkedBroadcastURL,
                mediaItems: items,
                firstVideoStreamURL: firstVideoStreamURL,
                galleryImages: galleryImages,
                referencedContentPostID: referencedContentPost?.id
            ),
            streamURL: firstVideoStreamURL,
            title: post.broadcastTitle,
            subtitle: candidateSubtitle(
                postID: post.id,
                isPinned: isPinned,
                mediaItems: items,
                firstVideoVariant: firstVideoVariant,
                linkedBroadcastURL: linkedBroadcastURL,
                fallbackPrefix: subtitlePrefix
            ),
            tweetText: post.text,
            publishedAt: post.createdAt,
            thumbnailURL: thumbnailURL,
            galleryImages: galleryImages,
            mediaItems: items,
            allowsDeferredStreamResolution: linkedBroadcastURL != nil,
            isPinned: isPinned,
            originalPostID: post.id,
            contentFingerprint: fp
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
        mediaItems: [PostMediaItem],
        firstVideoStreamURL: URL?,
        galleryImages: [GalleryImage],
        referencedContentPostID: String?
    ) -> String {
        if let linkedBroadcastURL,
           let broadcastID = xBroadcastID(from: linkedBroadcastURL) {
            return "broadcast:\(broadcastID)"
        }

        let videoCount = mediaItems.filter { $0.kind == .video }.count
        let photoCount = mediaItems.filter { $0.kind == .photo }.count
        if videoCount > 1 || (videoCount >= 1 && photoCount >= 1) {
            return "media-set:\(referencedContentPostID ?? post.id)"
        }

        if let firstVideoStreamURL {
            return "stream:\(firstVideoStreamURL.absoluteString)"
        }

        if !galleryImages.isEmpty {
            return "gallery:\(referencedContentPostID ?? post.id)"
        }

        if let normalizedText = post.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !normalizedText.isEmpty {
            return "text:\(normalizedText)"
        }

        return "status:\(statusURL.absoluteString)"
    }

    private func contentFingerprint(
        post: XAPIPost,
        media: [XAPIMedia],
        referencedContentPost: XAPIPost?,
        referencedContentMedia: [XAPIMedia],
        linkedBroadcastURL: URL?
    ) -> String {
        // Stable string describing the parts of the post (and referenced content post) that affect
        // whether this is a gallery, has a direct stream variant, links to a broadcast,
        // or changes the text-based dedupe. If this changes we must re-probe / re-classify.
        var parts: [String] = ["id:\(post.id)"]
        if let t = post.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            parts.append("t:\(t)")
        }
        if let ca = post.createdAt {
            parts.append("at:\(Int(ca.timeIntervalSince1970))")
        }
        if let linked = linkedBroadcastURL {
            parts.append("lnk:\(linked.absoluteString)")
        }
        let own = media.map(mediaFingerprint).sorted()
        if !own.isEmpty {
            parts.append("m:\(own.joined(separator: ","))")
        }
        if let referencedContent = post.referencedContentTweet {
            parts.append("r:\(referencedContent.type):\(referencedContent.id)")
        }
        let referencedMedia = referencedContentMedia.map(mediaFingerprint).sorted()
        if !referencedMedia.isEmpty {
            parts.append("rm:\(referencedMedia.joined(separator: ","))")
        }
        return parts.joined(separator: "|")
    }

    func mediaFingerprint(_ media: XAPIMedia) -> String {
        let variants = (media.variants ?? [])
            .map { variant in
                "\(variant.url.absoluteString):\(variant.contentType ?? ""):\(variant.bitRate.map(String.init) ?? "")"
            }
            .sorted()
            .joined(separator: ",")
        let width = media.width.map(String.init) ?? ""
        let height = media.height.map(String.init) ?? ""
        let components: [String] = [
            media.mediaKey,
            media.type ?? "",
            variants,
            media.previewImageURL?.absoluteString ?? "",
            media.url?.absoluteString ?? "",
            width,
            height,
            media.altText ?? "",
        ]
        return components.joined(separator: ":")
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
        mediaItems: [PostMediaItem],
        firstVideoVariant: XAPIMediaVariant?,
        linkedBroadcastURL: URL?,
        fallbackPrefix: String
    ) -> String {
        if let summary = PostMediaItem.summaryLabel(for: mediaItems),
           mediaItems.filter({ $0.kind == .video }).count > 1
            || (mediaItems.contains(where: { $0.kind == .video }) && mediaItems.contains(where: { $0.kind == .photo })) {
            return "\(isPinned ? "Pinned " : "")X media collection · \(summary)"
        }

        if let firstVideoVariant {
            return "\(isPinned ? "Pinned " : "")X API media \(firstVideoVariant.contentType ?? "variant")"
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

    private func postMediaItems(from media: [XAPIMedia]) -> [PostMediaItem] {
        media.compactMap { item in
            if isVideoMedia(item) {
                let variant = bestVariant(from: item)
                return PostMediaItem(
                    id: item.mediaKey,
                    kind: .video,
                    streamURL: variant?.url,
                    thumbnailURL: item.thumbnailURL,
                    width: item.width,
                    height: item.height,
                    altText: item.altText
                )
            }

            if item.type == "photo", let photoURL = item.fullSizePhotoURL {
                return PostMediaItem(
                    id: item.mediaKey,
                    kind: .photo,
                    thumbnailURL: item.thumbnailURL ?? photoURL,
                    photoURL: photoURL,
                    width: item.width,
                    height: item.height,
                    altText: item.altText
                )
            }

            return nil
        }
    }

    private func isVideoMedia(_ media: XAPIMedia) -> Bool {
        media.type == "video" || media.type == "animated_gif"
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

    func deduplicatedXCandidates(_ candidates: [BroadcastCandidate]) -> [BroadcastCandidate] {
        var result: [BroadcastCandidate] = []
        var indexByKey: [String: Int] = [:]

        for candidate in candidates {
            let keys = candidate.xCardDuplicateKeys
            guard let existingIndex = keys.compactMap({ indexByKey[$0] }).first else {
                let newIndex = result.count
                keys.forEach { indexByKey[$0] = newIndex }
                result.append(candidate)
                continue
            }

            let existing = result[existingIndex]
            if let candidateDate = candidate.publishedAt,
               let existingDate = existing.publishedAt,
               candidateDate > existingDate {
                result[existingIndex] = candidate
            }
            keys.forEach { indexByKey[$0] = existingIndex }
        }

        return result
    }

    private func recentStarshipFilmCandidates(
        prefersMP4Playback: Bool,
        report: inout DiscoveryReport,
        cachedPlaylist: SpaceXMediaPlaylist? = nil
    ) async throws -> [BroadcastCandidate] {
        let playlist: SpaceXMediaPlaylist
        if let cachedPlaylist {
            report.add("Using cached SpaceX Starship playlist")
            playlist = cachedPlaylist
        } else {
            report.add("SpaceX CMS GET: \(starshipPlaylistURL.path)")
            let data = try await spaceXCMSData(from: starshipPlaylistURL, report: &report)
            playlist = try spaceXCMSDecoder().decode(SpaceXMediaPlaylist.self, from: data)
        }

        return playlist.media.compactMap { media in
            guard let playbackURLs = media.playbackURLs(prefersMP4Playback: prefersMP4Playback) else { return nil }
            return BroadcastCandidate(
                statusURL: playbackURLs.primary,
                dedupeKey: "spacex-media:\(media.documentID ?? media.link ?? playbackURLs.primary.absoluteString)",
                streamURL: nil,
                fallbackStreamURL: playbackURLs.fallback,
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

    private func recentStarshipTalkCandidates(
        prefersMP4Playback: Bool,
        report: inout DiscoveryReport,
        cachedPlaylist: SpaceXMediaPlaylist? = nil
    ) async throws -> [BroadcastCandidate] {
        let playlist: SpaceXMediaPlaylist
        if let cachedPlaylist {
            report.add("Using cached SpaceX Starship talks playlist")
            playlist = cachedPlaylist
        } else {
            report.add("SpaceX CMS GET: \(starshipTalksPlaylistURL.path)")
            let data = try await spaceXCMSData(from: starshipTalksPlaylistURL, report: &report)
            playlist = try spaceXCMSDecoder().decode(SpaceXMediaPlaylist.self, from: data)
        }

        return playlist.media.compactMap { media in
            guard let playbackURLs = media.playbackURLs(prefersMP4Playback: prefersMP4Playback) else { return nil }
            return BroadcastCandidate(
                statusURL: playbackURLs.primary,
                dedupeKey: "spacex-starship-talk:\(media.documentID ?? media.link ?? playbackURLs.primary.absoluteString)",
                streamURL: nil,
                fallbackStreamURL: playbackURLs.fallback,
                title: media.title,
                subtitle: media.bestStarshipTalkSubtitle,
                tweetText: media.bestDescription,
                publishedAt: media.date,
                thumbnailURL: media.poster?.bestURL,
                sourceKind: .hls,
                artworkName: media.uhdStreamingLink == nil && media.uhdLink == nil ? "mic" : "play.tv",
                isAppendedSpaceXContent: true
            )
        }
    }

    private func starshipFlightTestCandidates(
        prefersMP4Playback: Bool,
        report: inout DiscoveryReport,
        cache: StarshipCacheSnapshot? = nil
    ) async throws -> [BroadcastCandidate] {
        let playlist: SpaceXMediaPlaylist
        if let cache {
            report.add("Using cached SpaceX Starship flight tests playlist")
            playlist = cache.flightTestsPlaylist
        } else {
            report.add("SpaceX CMS GET: \(starshipFlightTestsPlaylistURL.path)")
            let data = try await spaceXCMSData(from: starshipFlightTestsPlaylistURL, report: &report)
            playlist = try spaceXCMSDecoder().decode(SpaceXMediaPlaylist.self, from: data)
        }

        let playlistCandidates: [BroadcastCandidate] = playlist.media.compactMap { media in
            guard let playbackURLs = media.playbackURLs(prefersMP4Playback: prefersMP4Playback) else { return nil }
            return BroadcastCandidate(
                statusURL: playbackURLs.primary,
                dedupeKey: "spacex-starship-flight-test:\(media.starshipFlightTestKey ?? media.documentID ?? media.link ?? playbackURLs.primary.absoluteString)",
                streamURL: nil,
                fallbackStreamURL: playbackURLs.fallback,
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

        let launchTileCandidates = try await starshipFlightTestLaunchTileCandidates(
            report: &report,
            cache: cache
        )
        return deduplicatedCandidates(playlistCandidates + launchTileCandidates)
    }

    private func starshipFlightTestLaunchTileCandidates(
        report: inout DiscoveryReport,
        cache: StarshipCacheSnapshot? = nil
    ) async throws -> [BroadcastCandidate] {
        let tiles: [SpaceXStarshipLaunchTile]
        if let cache {
            report.add("Using cached SpaceX launch tiles and mission records")
            tiles = cache.launchTiles
        } else {
            report.add("SpaceX CMS GET: \(launchTilesURL.path)")
            let data = try await spaceXCMSData(from: launchTilesURL, report: &report)
            tiles = try JSONDecoder().decode([SpaceXStarshipLaunchTile].self, from: data)
        }
        let flightTestTiles = tiles
            .filter(\.isStarshipFlightTest)
            .sortedByPublishedDateDescending()

        let missionsByLink: [String: SpaceXStarshipMission]
        if let cache {
            missionsByLink = cache.missions
        } else {
            missionsByLink = try await starshipMissions(for: flightTestTiles.map(\.link))
        }

        return flightTestTiles.map { tile in
            let mission = missionsByLink[tile.link]
            let webcast = mission?.preferredWebcast
            let broadcastURL = webcast?.url ?? tile.sourceURL
            let hasPlayableWebcast = webcast?.url != nil
            return BroadcastCandidate(
                statusURL: broadcastURL,
                dedupeKey: "spacex-starship-flight-test:\(tile.starshipFlightTestKey)",
                streamURL: nil,
                title: tile.displayTitle,
                subtitle: "Starship flight test",
                tweetText: mission?.summary ?? tile.description,
                publishedAt: tile.publishedAt,
                thumbnailURL: mission?.imageURL ?? tile.imageURL,
                allowsDeferredStreamResolution: webcast?.sourceKind == .xBroadcast,
                sourceKind: webcast?.sourceKind ?? .xBroadcast,
                artworkName: "play.tv",
                isAppendedSpaceXContent: true,
                // Holding CMS entries (e.g. starship-flight-13) ship a tile before any webcast exists.
                isUpcoming: !hasPlayableWebcast
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
            URLQueryItem(name: "exclude", value: "replies"),
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

    private func bestVariant(from media: XAPIMedia) -> XAPIMediaVariant? {
        bestVariant(from: [media])
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

struct BroadcastCandidate {
    var statusURL: URL
    var dedupeKey: String
    var streamURL: URL?
    var fallbackStreamURL: URL?
    var title: String = "SpaceX Broadcast"
    var subtitle: String
    var tweetText: String? = nil
    var publishedAt: Date? = nil
    var thumbnailURL: URL? = nil
    var galleryImages: [GalleryImage] = []
    var mediaItems: [PostMediaItem] = []
    var allowsDeferredStreamResolution: Bool = false
    var isPinned: Bool = false
    var sourceKind: Broadcast.SourceKind = .xBroadcast
    var artworkName: String = "antenna.radiowaves.left.and.right"
    var isAppendedSpaceXContent: Bool = false
    /// Holding entry with no playable webcast yet (SpaceX "UPCOMING" mission tiles).
    var isUpcoming: Bool = false
    // For card check caching across refreshes: the originating X post ID and a fingerprint of
    // the post data that affects gallery classification or stream resolution.
    var originalPostID: String? = nil
    var contentFingerprint: String? = nil

    init(
        statusURL: URL,
        dedupeKey: String? = nil,
        streamURL: URL?,
        fallbackStreamURL: URL? = nil,
        title: String = "SpaceX Broadcast",
        subtitle: String,
        tweetText: String? = nil,
        publishedAt: Date? = nil,
        thumbnailURL: URL? = nil,
        galleryImages: [GalleryImage] = [],
        mediaItems: [PostMediaItem] = [],
        allowsDeferredStreamResolution: Bool = false,
        isPinned: Bool = false,
        sourceKind: Broadcast.SourceKind = .xBroadcast,
        artworkName: String = "antenna.radiowaves.left.and.right",
        isAppendedSpaceXContent: Bool = false,
        isUpcoming: Bool = false,
        originalPostID: String? = nil,
        contentFingerprint: String? = nil
    ) {
        self.statusURL = statusURL
        if let dedupeKey, !dedupeKey.isEmpty {
            self.dedupeKey = dedupeKey
        } else {
            self.dedupeKey = "status:\(statusURL.absoluteString)"
        }
        self.streamURL = streamURL
        self.fallbackStreamURL = fallbackStreamURL
        self.title = title
        self.subtitle = subtitle
        self.tweetText = tweetText
        self.publishedAt = publishedAt
        self.thumbnailURL = thumbnailURL
        self.galleryImages = galleryImages
        self.mediaItems = mediaItems
        self.allowsDeferredStreamResolution = allowsDeferredStreamResolution
        self.isPinned = isPinned
        self.sourceKind = sourceKind
        self.artworkName = artworkName
        self.isAppendedSpaceXContent = isAppendedSpaceXContent
        self.isUpcoming = isUpcoming
        self.originalPostID = originalPostID
        self.contentFingerprint = contentFingerprint
    }

    /// Videos that already have an API stream, plus photos. Used so the collection
    /// picker never lists clips that would all resolve to the same status scrape.
    var playableCollectionMediaItems: [PostMediaItem] {
        mediaItems.filter { item in
            switch item.kind {
            case .video:
                return item.streamURL != nil
            case .photo:
                return item.photoURL != nil || item.thumbnailURL != nil
            }
        }
    }

    /// Multi-video posts, or posts that mix playable video and photos, open a media picker.
    /// Videos without a stream URL are excluded so they fall through to single-video probe
    /// or gallery rather than becoming unplayable picker entries.
    var requiresMediaCollection: Bool {
        let playable = playableCollectionMediaItems
        let videoCount = playable.filter { $0.kind == .video }.count
        let photoCount = playable.filter { $0.kind == .photo }.count
        return videoCount > 1 || (videoCount >= 1 && photoCount >= 1)
    }
}

private extension BroadcastCandidate {
    var xCardDuplicateKeys: [String] {
        guard streamURL != nil || allowsDeferredStreamResolution else {
            return [dedupeKey]
        }

        let normalizedTitle = title
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()

        guard !normalizedTitle.isEmpty, normalizedTitle != "spacex broadcast" else {
            return [dedupeKey]
        }
        return [dedupeKey, "x-card-title:\(normalizedTitle)"]
    }
}

private struct DiscoveredBroadcastItem {
    var candidate: BroadcastCandidate
    var broadcast: Broadcast
}

extension BroadcastCandidate {
    func isSortedBefore(_ rhs: BroadcastCandidate) -> Bool {
        if isPinned != rhs.isPinned {
            return isPinned
        }

        // Upcoming holding cards (no webcast yet) lead their section, even without a launch date.
        if isUpcoming != rhs.isUpcoming {
            return isUpcoming
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

extension Array where Element == BroadcastCandidate {
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

    private(set) var cardCheckHits: Int = 0
    private(set) var cardCheckMisses: Int = 0

    mutating func add(_ line: String) {
        lines.append(line)
        print("[SpaceXTV] \(line)")
    }

    mutating func setXAPICacheGeneratedAt(_ date: Date?) {
        xAPICacheGeneratedAt = date
    }

    mutating func recordCardCheckHit() {
        cardCheckHits += 1
    }

    mutating func recordCardCheckMiss() {
        cardCheckMisses += 1
    }

    mutating func addCardCheckSummaryIfNeeded() {
        let total = cardCheckHits + cardCheckMisses
        if total > 0 {
            add("Card checks: \(cardCheckHits) hits, \(cardCheckMisses) misses")
        }
    }
}

struct BroadcastDiscoveryFailure: LocalizedError {
    var error: LocalizedError
    var report: DiscoveryReport

    var errorDescription: String? {
        error.errorDescription
    }
}

// Persisted cache of per-card probe / classification results.
// On refresh or next-day load we only re-probe (resolveStatusURL or gallery classification)
// for cards whose originating post content fingerprint changed. This makes subsequent
// daily updates and manual refreshes much faster: we only pay the network cost for truly
// new or edited cards.
//
// We cache both positive results (broadcasts and galleries, including deferred ones)
// and negative results (plain posts that contain neither). This avoids re-checking
// the same unchanged non-broadcast/non-gallery posts on every refresh.
struct CardResolutionCache: Codable {
    var version: Int = 4
    var entries: [String: CardResolutionEntry] = [:]

    mutating func merge(_ incoming: CardResolutionCache) -> Int {
        var mergedCount = 0
        for (key, entry) in incoming.entries {
            if let existing = entries[key], existing.lastChecked >= entry.lastChecked {
                continue
            }
            entries[key] = entry
            mergedCount += 1
        }
        pruneIfNeeded()
        return mergedCount
    }

    struct CardResolutionEntry: Codable {
        var fingerprint: String
        var lastChecked: Date
        var expiresAt: Date?
        var streamURL: URL?
        var thumbnailURL: URL?
        var isLive: Bool?
        var contentKind: Broadcast.ContentKind?
        var hasUsableContent: Bool = true
    }

    enum Validity {
        case failedProbe
        case liveStream
        case resolvedStream
        case directMedia

        var duration: TimeInterval {
            switch self {
            case .failedProbe:
                15 * 60
            case .liveStream:
                15 * 60
            case .resolvedStream:
                7 * 24 * 60 * 60
            case .directMedia:
                7 * 24 * 60 * 60
            }
        }
    }

    // Stable lookup key for a candidate. Prefer the originating X post for "this card JSON".
    // Fall back to dedupeKey for a few immutable cases (direct broadcast:/gallery:/stream:).
    private static func key(for candidate: BroadcastCandidate) -> String? {
        if let pid = candidate.originalPostID, !pid.isEmpty {
            return "post:\(pid)"
        }
        let dk = candidate.dedupeKey
        if dk.hasPrefix("broadcast:") || dk.hasPrefix("gallery:") || dk.hasPrefix("stream:") {
            return dk
        }
        return nil
    }

    /// Returns a prior successful (or safely-deferred) resolution for this candidate
    /// only if the stored fingerprint matches the candidate's current contentFingerprint.
    mutating func resolution(for candidate: BroadcastCandidate, now: Date = Date()) -> CardResolutionEntry? {
        guard let k = Self.key(for: candidate) else { return nil }
        guard let entry = entries[k] else { return nil }
        guard let fp = candidate.contentFingerprint, entry.fingerprint == fp else {
            entries.removeValue(forKey: k)
            return nil
        }
        if let expiresAt = entry.expiresAt, expiresAt <= now {
            entries.removeValue(forKey: k)
            return nil
        }
        return entry
    }

    /// Remember the outcome of a check/probe for this card (by post or dedupe key) under its current fingerprint.
    mutating func record(
        for candidate: BroadcastCandidate,
        streamURL: URL?,
        thumbnailURL: URL?,
        isLive: Bool?,
        contentKind: Broadcast.ContentKind,
        hasUsableContent: Bool = true,
        validFor validity: Validity? = nil,
        now: Date = Date()
    ) {
        guard let k = Self.key(for: candidate),
              let fp = candidate.contentFingerprint else { return }
        entries[k] = CardResolutionEntry(
            fingerprint: fp,
            lastChecked: now,
            expiresAt: validity.map { now.addingTimeInterval($0.duration) },
            streamURL: streamURL,
            thumbnailURL: thumbnailURL,
            isLive: isLive,
            contentKind: contentKind,
            hasUsableContent: hasUsableContent
        )
        pruneIfNeeded()
    }

    private mutating func pruneIfNeeded(maxEntries: Int = 400) {
        guard entries.count > maxEntries else { return }
        let sorted = entries.sorted { $0.value.lastChecked > $1.value.lastChecked }
        entries = Dictionary(uniqueKeysWithValues: sorted.prefix(maxEntries).map { ($0.key, $0.value) })
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
    var processedCards: CardResolutionCache?
    var starshipPlaylist: SpaceXMediaPlaylist?
    var starshipFlightTestsPlaylist: SpaceXMediaPlaylist?
    var starshipTalksPlaylist: SpaceXMediaPlaylist?
    var starshipLaunchTiles: [SpaceXStarshipLaunchTile]?
    var starshipMissions: [String: SpaceXStarshipMission]?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case source
        case user
        case pinned
        case timeline
        case processedCards = "processed_cards"
        case starshipPlaylist = "starship_playlist"
        case starshipFlightTestsPlaylist = "starship_flight_tests_playlist"
        case starshipTalksPlaylist = "starship_talks_playlist"
        case starshipLaunchTiles = "starship_launch_tiles"
        case starshipMissions = "starship_missions"
    }
}

private struct XAPIPost: Decodable {
    var id: String
    var text: String?
    var createdAt: Date?
    var entities: XAPIPostEntities?
    var attachments: XAPIPostAttachments?
    var referencedTweets: [XAPIReferencedTweet]?

    var referencedContentTweet: XAPIReferencedTweet? {
        referencedTweets?.first { $0.type == "quoted" || $0.type == "retweeted" }
    }

    var referencedContentTweetID: String? {
        referencedContentTweet?.id
    }

    var referencedContentTweetType: String? {
        referencedContentTweet?.type
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

struct XAPIMedia: Decodable {
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

struct XAPIMediaVariant: Decodable {
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

private struct StarshipCacheSnapshot {
    var playlist: SpaceXMediaPlaylist
    var flightTestsPlaylist: SpaceXMediaPlaylist
    var talksPlaylist: SpaceXMediaPlaylist?
    var launchTiles: [SpaceXStarshipLaunchTile]
    var missions: [String: SpaceXStarshipMission]
}

struct SpaceXPlaybackURLs: Equatable {
    var primary: URL
    var fallback: URL?

    init?(mp4: URL?, hls: URL?, prefersMP4Playback: Bool) {
        guard let primary = prefersMP4Playback ? (mp4 ?? hls) : (hls ?? mp4) else { return nil }
        self.primary = primary
        let alternate = prefersMP4Playback ? hls : mp4
        fallback = alternate == primary ? nil : alternate
    }
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

    func playbackURLs(prefersMP4Playback: Bool) -> SpaceXPlaybackURLs? {
        let mp4 = fhdLink ?? hdLink ?? uhdLink
        let hls = autoStreamingLink ?? fhdStreamingLink ?? hdStreamingLink ?? uhdStreamingLink
        return SpaceXPlaybackURLs(mp4: mp4, hls: hls, prefersMP4Playback: prefersMP4Playback)
    }

    var bestSubtitle: String {
        if uhdStreamingLink != nil || uhdLink != nil {
            return "Starship film · 4K"
        }
        return "Starship film"
    }

    var bestStarshipTalkSubtitle: String {
        if uhdStreamingLink != nil || uhdLink != nil {
            return "Starship talk · 4K"
        }
        return "Starship talk"
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

    var preferredWebcast: SpaceXWebcast? {
        webcasts?.first { $0.sourceKind == .xBroadcast }
            ?? webcasts?.first { $0.sourceKind == .youtube }
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

struct SpaceXWebcast: Decodable {
    var videoId: String?
    var streamingVideoType: String?

    var sourceKind: Broadcast.SourceKind? {
        switch streamingVideoType?.lowercased() {
        case "x.com":
            .xBroadcast
        case "youtube":
            .youtube
        default:
            nil
        }
    }

    var url: URL? {
        guard let videoId, !videoId.isEmpty else { return nil }
        switch sourceKind {
        case .xBroadcast:
            return URL(string: "https://x.com/i/broadcasts/\(videoId)")
        case .youtube:
            return URL(string: "https://www.youtube.com/watch?v=\(videoId)")
        default:
            return nil
        }
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
