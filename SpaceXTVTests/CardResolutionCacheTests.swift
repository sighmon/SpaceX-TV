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
            isLive: true,
            contentKind: .video,
            validFor: .resolvedStream,
            now: checkedAt
        )

        XCTAssertEqual(cache.resolution(for: candidate, now: checkedAt.addingTimeInterval(3_599))?.streamURL, streamURL)
        XCTAssertNil(cache.resolution(for: candidate, now: checkedAt.addingTimeInterval(3_600)))
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

    func testMediaFingerprintChangesWhenVariantChanges() {
        let discovery = BroadcastDiscovery()
        let first = makeMedia(variantURL: "https://video.twimg.com/variant-a.mp4", bitRate: 832_000)
        let updated = makeMedia(variantURL: "https://video.twimg.com/variant-b.mp4", bitRate: 2_176_000)

        XCTAssertNotEqual(discovery.mediaFingerprint(first), discovery.mediaFingerprint(updated))
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
