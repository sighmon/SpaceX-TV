import XCTest
@testable import SpaceXTV

final class CardResolutionCacheTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testNegativeProbeExpiresSoTransientFailureCanRetry() {
        var cache = CardResolutionCache()
        let candidate = makeCandidate(fingerprint: "unchanged")

        cache.record(
            for: candidate,
            streamURL: nil,
            thumbnailURL: nil,
            isLive: nil,
            contentKind: .video,
            hasUsableContent: false,
            validFor: .failedProbe,
            now: checkedAt
        )

        XCTAssertFalse(cache.resolution(for: candidate, now: checkedAt.addingTimeInterval(899))?.hasUsableContent ?? true)
        XCTAssertNil(cache.resolution(for: candidate, now: checkedAt.addingTimeInterval(900)))
    }

    func testResolvedStreamExpires() {
        var cache = CardResolutionCache()
        let candidate = makeCandidate(fingerprint: "unchanged")
        let streamURL = URL(string: "https://video.pscp.tv/stream.m3u8")!

        cache.record(
            for: candidate,
            streamURL: streamURL,
            thumbnailURL: nil,
            isLive: false,
            contentKind: .video,
            validFor: .resolvedStream,
            now: checkedAt
        )

        XCTAssertEqual(cache.resolution(for: candidate, now: checkedAt.addingTimeInterval(604_799))?.streamURL, streamURL)
        XCTAssertNil(cache.resolution(for: candidate, now: checkedAt.addingTimeInterval(604_800)))
    }

    func testLiveStreamExpiresQuickly() {
        var cache = CardResolutionCache()
        let candidate = makeCandidate(fingerprint: "unchanged")

        cache.record(
            for: candidate,
            streamURL: URL(string: "https://video.pscp.tv/live.m3u8")!,
            thumbnailURL: nil,
            isLive: true,
            contentKind: .video,
            validFor: .liveStream,
            now: checkedAt
        )

        XCTAssertNotNil(cache.resolution(for: candidate, now: checkedAt.addingTimeInterval(899)))
        XCTAssertNil(cache.resolution(for: candidate, now: checkedAt.addingTimeInterval(900)))
    }

    func testDirectMediaRemainsCachedForSevenDays() {
        var cache = CardResolutionCache()
        let candidate = makeCandidate(fingerprint: "unchanged")

        cache.record(
            for: candidate,
            streamURL: URL(string: "https://video.twimg.com/replay.mp4")!,
            thumbnailURL: nil,
            isLive: nil,
            contentKind: .video,
            validFor: .directMedia,
            now: checkedAt
        )

        XCTAssertNotNil(cache.resolution(for: candidate, now: checkedAt.addingTimeInterval(604_799)))
        XCTAssertNil(cache.resolution(for: candidate, now: checkedAt.addingTimeInterval(604_800)))
    }

    func testGalleryRemainsCachedWithoutExpiry() {
        var cache = CardResolutionCache()
        let candidate = makeCandidate(fingerprint: "gallery")

        cache.record(
            for: candidate,
            streamURL: nil,
            thumbnailURL: URL(string: "https://pbs.twimg.com/media/photo.jpg")!,
            isLive: nil,
            contentKind: .gallery,
            now: checkedAt
        )

        XCTAssertEqual(
            cache.resolution(for: candidate, now: checkedAt.addingTimeInterval(365 * 24 * 60 * 60))?.contentKind,
            .gallery
        )
    }

    func testFingerprintChangeInvalidatesEntry() {
        var cache = CardResolutionCache()
        let original = makeCandidate(fingerprint: "variant-a")
        let updated = makeCandidate(fingerprint: "variant-b")

        cache.record(
            for: original,
            streamURL: URL(string: "https://video.twimg.com/variant-a.mp4")!,
            thumbnailURL: nil,
            isLive: nil,
            contentKind: .video,
            validFor: .directMedia,
            now: checkedAt
        )

        XCTAssertNil(cache.resolution(for: updated, now: checkedAt))
        XCTAssertNil(cache.resolution(for: original, now: checkedAt))
    }

    func testHostedCardChecksMergeWithoutReplacingNewerDeviceResults() {
        let candidate = makeCandidate(fingerprint: "unchanged")
        var deviceCache = CardResolutionCache()
        deviceCache.record(
            for: candidate,
            streamURL: URL(string: "https://video.pscp.tv/device.m3u8")!,
            thumbnailURL: nil,
            isLive: false,
            contentKind: .video,
            validFor: .resolvedStream,
            now: checkedAt
        )

        var hostedCache = CardResolutionCache()
        hostedCache.record(
            for: candidate,
            streamURL: URL(string: "https://video.pscp.tv/hosted.m3u8")!,
            thumbnailURL: nil,
            isLive: false,
            contentKind: .video,
            validFor: .resolvedStream,
            now: checkedAt.addingTimeInterval(-60)
        )

        XCTAssertEqual(deviceCache.merge(hostedCache), 0)
        XCTAssertEqual(deviceCache.resolution(for: candidate, now: checkedAt)?.streamURL?.absoluteString, "https://video.pscp.tv/device.m3u8")

        hostedCache.record(
            for: candidate,
            streamURL: URL(string: "https://video.pscp.tv/new-hosted.m3u8")!,
            thumbnailURL: nil,
            isLive: false,
            contentKind: .video,
            validFor: .resolvedStream,
            now: checkedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(deviceCache.merge(hostedCache), 1)
        XCTAssertEqual(deviceCache.resolution(for: candidate, now: checkedAt)?.streamURL?.absoluteString, "https://video.pscp.tv/new-hosted.m3u8")
    }

    func testMediaFingerprintChangesWhenVariantChanges() {
        let discovery = BroadcastDiscovery()
        let first = makeMedia(variantURL: "https://video.twimg.com/variant-a.mp4", bitRate: 832_000)
        let updated = makeMedia(variantURL: "https://video.twimg.com/variant-b.mp4", bitRate: 2_176_000)

        XCTAssertNotEqual(discovery.mediaFingerprint(first), discovery.mediaFingerprint(updated))
    }

    func testSpaceXPlaybackPrefersMP4WithHLSFallback() {
        let mp4 = URL(string: "https://content.spacex.com/video.mp4")!
        let hls = URL(string: "https://content.spacex.com/video.m3u8")!

        let selection = SpaceXPlaybackURLs(mp4: mp4, hls: hls, prefersMP4Playback: true)

        XCTAssertEqual(selection?.primary, mp4)
        XCTAssertEqual(selection?.fallback, hls)
    }

    func testSpaceXPlaybackPrefersHLSWithMP4Fallback() {
        let mp4 = URL(string: "https://content.spacex.com/video.mp4")!
        let hls = URL(string: "https://content.spacex.com/video.m3u8")!

        let selection = SpaceXPlaybackURLs(mp4: mp4, hls: hls, prefersMP4Playback: false)

        XCTAssertEqual(selection?.primary, hls)
        XCTAssertEqual(selection?.fallback, mp4)
    }

    func testPagePlaybackUsesMP4WhenHLSIsUnavailable() throws {
        let body = """
        <video src="https://video.twimg.com/archive/high.mp4?tag=12"></video>
        """

        let streamURL = try BroadcastResolver().playbackURL(inPageBody: body)

        XCTAssertEqual(streamURL?.absoluteString, "https://video.twimg.com/archive/high.mp4?tag=12")
    }

    func testPagePlaybackStillPrefersHLSOverMP4() throws {
        let body = """
        <video src="https://video.twimg.com/archive/high.mp4"></video>
        <script>const stream = "https://video.pscp.tv/archive/master.m3u8?token=abc";</script>
        """

        let streamURL = try BroadcastResolver().playbackURL(inPageBody: body)

        XCTAssertEqual(streamURL?.absoluteString, "https://video.pscp.tv/archive/master.m3u8?token=abc")
    }

    func testSpaceXYouTubeWebcastCreatesWatchURL() {
        let webcast = SpaceXWebcast(
            videoId: "gjCSJIAKEPM",
            streamingVideoType: "youtube"
        )

        XCTAssertEqual(webcast.sourceKind, .youtube)
        XCTAssertEqual(webcast.url?.absoluteString, "https://www.youtube.com/watch?v=gjCSJIAKEPM")
    }

    func testSpaceXXWebcastStillCreatesBroadcastURL() {
        let webcast = SpaceXWebcast(
            videoId: "1YpK2V5M6Q",
            streamingVideoType: "x.com"
        )

        XCTAssertEqual(webcast.sourceKind, .xBroadcast)
        XCTAssertEqual(webcast.url?.absoluteString, "https://x.com/i/broadcasts/1YpK2V5M6Q")
    }

    @MainActor
    func testLoadMoreRequiresBearerTokenMode() {
        let broadcast = Broadcast(
            title: "Cached broadcast",
            subtitle: "X status",
            sourceURL: URL(string: "https://x.com/spacex/status/123")!,
            sourceKind: .xBroadcast,
            artworkName: "play.rectangle"
        )
        let library = BroadcastLibrary(previewBroadcasts: [broadcast])

        XCTAssertFalse(library.usesXAPIBearerToken)
        XCTAssertFalse(library.canLoadMore)

        library.usesXAPIBearerToken = true

        XCTAssertTrue(library.canLoadMore)
    }

    private func makeCandidate(fingerprint: String) -> BroadcastCandidate {
        BroadcastCandidate(
            statusURL: URL(string: "https://x.com/spacex/status/123")!,
            streamURL: nil,
            subtitle: "X status",
            originalPostID: "123",
            contentFingerprint: fingerprint
        )
    }

    private func makeMedia(variantURL: String, bitRate: Int) -> XAPIMedia {
        XAPIMedia(
            mediaKey: "media-key",
            type: "video",
            variants: [
                XAPIMediaVariant(
                    bitRate: bitRate,
                    contentType: "video/mp4",
                    url: URL(string: variantURL)!
                ),
            ],
            previewImageURL: URL(string: "https://pbs.twimg.com/media/preview.jpg"),
            url: nil,
            width: 1920,
            height: 1080,
            altText: "Launch"
        )
    }
}
