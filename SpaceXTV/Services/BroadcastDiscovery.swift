import Foundation

enum BroadcastDiscoveryError: LocalizedError {
    case noStatusesFound
    case noBroadcastsFound
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noStatusesFound:
            "No recent SpaceX status links were found on X."
        case .noBroadcastsFound:
            "No recent SpaceX statuses with bundled broadcasts were found."
        case .invalidResponse:
            "X returned a response the app could not read."
        }
    }
}

struct BroadcastDiscovery {
    var session: URLSession = .shared
    var resolver: BroadcastResolver {
        BroadcastResolver(session: session)
    }

    func discoverRecentSpaceXBroadcasts(limit: Int = 10, xAPIBearerToken: String?) async throws -> BroadcastDiscoveryResult {
        var report = DiscoveryReport()
        report.add("Starting SpaceX broadcast discovery")

        let candidates = try await recentSpaceXBroadcastCandidates(
            xAPIBearerToken: xAPIBearerToken,
            report: &report
        )
        report.add("Candidate statuses: \(candidates.count)")

        guard !candidates.isEmpty else {
            throw BroadcastDiscoveryFailure(error: BroadcastDiscoveryError.noStatusesFound, report: report)
        }

        var broadcasts: [Broadcast] = []
        for (index, candidate) in candidates.prefix(80).enumerated() {
            guard broadcasts.count < limit else { break }
            let statusURL = candidate.statusURL
            report.add("Probing \(index + 1): \(statusURL.lastPathComponent)")

            do {
                let streamURL: URL
                if let apiStreamURL = candidate.streamURL {
                    streamURL = apiStreamURL
                    report.add("Using X API media variant for \(statusURL.lastPathComponent)")
                } else {
                    streamURL = try await resolver.streamURL(fromStatusURL: statusURL)
                    report.add("Found page stream for \(statusURL.lastPathComponent)")
                }

                report.add("Found stream for \(statusURL.lastPathComponent)")
                broadcasts.append(
                    Broadcast(
                        title: candidate.title,
                        subtitle: candidate.subtitle,
                        sourceURL: statusURL,
                        sourceKind: .xBroadcast,
                        streamURL: streamURL,
                        tweetText: candidate.tweetText,
                        publishedAt: candidate.publishedAt,
                        thumbnailURL: candidate.thumbnailURL,
                        artworkName: "antenna.radiowaves.left.and.right"
                    )
                )
            } catch {
                report.add("No stream for \(statusURL.lastPathComponent): \(debugMessage(for: error))")
            }
        }

        guard !broadcasts.isEmpty else {
            throw BroadcastDiscoveryFailure(error: BroadcastDiscoveryError.noBroadcastsFound, report: report)
        }

        report.add("Discovery complete: \(broadcasts.count) broadcasts")
        return BroadcastDiscoveryResult(broadcasts: broadcasts, report: report)
    }

    private func recentSpaceXBroadcastCandidates(xAPIBearerToken: String?, report: inout DiscoveryReport) async throws -> [BroadcastCandidate] {
        if let xAPIBearerToken, !xAPIBearerToken.isEmpty {
            report.add("Using X API for timeline discovery")
            do {
                let apiCandidates = try await recentSpaceXBroadcastCandidatesFromAPI(
                    bearerToken: xAPIBearerToken,
                    report: &report
                )
                if !apiCandidates.isEmpty {
                    return apiCandidates
                }
                report.add("X API returned no statuses; falling back to profile scraping")
            } catch {
                report.add("X API discovery failed: \(debugMessage(for: error))")
                report.add("Falling back to profile scraping")
            }
        } else {
            report.add("No X API Bearer Token configured")
        }

        let profileURLs = [
            URL(string: "https://x.com/spacex")!,
            URL(string: "https://mobile.x.com/spacex")!,
            URL(string: "https://twitter.com/spacex")!,
        ]

        var discoveredIDs: [String] = []
        for profileURL in profileURLs {
            report.add("Fetching profile: \(profileURL.absoluteString)")
            do {
                let ids = try await statusIDs(from: profileURL, report: &report)
                report.add("Profile yielded \(ids.count) status IDs")
                discoveredIDs.append(contentsOf: ids)
            } catch {
                report.add("Profile fetch failed: \(debugMessage(for: error))")
            }
        }

        let uniqueIDs = Array(Set(discoveredIDs))
            .sorted { lhs, rhs in
                (UInt64(lhs) ?? 0) > (UInt64(rhs) ?? 0)
            }

        report.add("Unique status IDs: \(uniqueIDs.count)")
        return uniqueIDs.compactMap { id in
            URL(string: "https://x.com/spacex/status/\(id)").map {
                BroadcastCandidate(statusURL: $0, streamURL: nil, subtitle: "X status \(id)")
            }
        }
    }

    private func recentSpaceXBroadcastCandidatesFromAPI(bearerToken: String, report: inout DiscoveryReport) async throws -> [BroadcastCandidate] {
        let user = try await xAPIUser(username: "spacex", bearerToken: bearerToken, report: &report)
        let timeline = try await xAPIPosts(userID: user.id, bearerToken: bearerToken, report: &report)
        report.add("X API returned \(timeline.posts.count) SpaceX posts")
        report.add("X API included \(timeline.mediaByKey.count) media objects")

        return timeline.posts.compactMap { post in
            guard let statusURL = URL(string: "https://x.com/spacex/status/\(post.id)") else {
                return nil
            }

            let media = post.attachments?.mediaKeys?
                .compactMap { timeline.mediaByKey[$0] }
                ?? []
            let variant = bestVariant(from: media)

            if let variant {
                report.add("API media variant for \(post.id): \(variant.contentType ?? "unknown") \(variant.bitRate.map(String.init) ?? "adaptive")")
            } else {
                report.add("No API media variant for \(post.id); will page-probe")
            }

            return BroadcastCandidate(
                statusURL: statusURL,
                streamURL: variant?.url,
                title: post.broadcastTitle,
                subtitle: variant.map { "X API media \($0.contentType ?? "variant")" } ?? "X status \(post.id)",
                tweetText: post.text,
                publishedAt: post.createdAt,
                thumbnailURL: media.compactMap(\.previewImageURL).first
            )
        }
    }

    private func xAPIUser(username: String, bearerToken: String, report: inout DiscoveryReport) async throws -> XAPIUser {
        let url = URL(string: "https://api.x.com/2/users/by/username/\(username)")!
        let data = try await xAPIData(from: url, bearerToken: bearerToken, report: &report)
        return try JSONDecoder().decode(XAPIUserResponse.self, from: data).data
    }

    private func xAPIPosts(userID: String, bearerToken: String, report: inout DiscoveryReport) async throws -> XAPITimeline {
        var components = URLComponents(string: "https://api.x.com/2/users/\(userID)/tweets")!
        components.queryItems = [
            URLQueryItem(name: "max_results", value: "100"),
            URLQueryItem(name: "tweet.fields", value: "created_at,entities,attachments"),
            URLQueryItem(name: "expansions", value: "attachments.media_keys"),
            URLQueryItem(name: "media.fields", value: "type,variants,preview_image_url,width,height,media_key"),
            URLQueryItem(name: "exclude", value: "retweets,replies"),
        ]

        guard let url = components.url else {
            throw BroadcastDiscoveryError.invalidResponse
        }

        let data = try await xAPIData(from: url, bearerToken: bearerToken, report: &report)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(XAPIPostsResponse.self, from: data)
        let mediaByKey = Dictionary(
            uniqueKeysWithValues: (response.includes?.media ?? []).map { ($0.mediaKey, $0) }
        )

        return XAPITimeline(posts: response.data ?? [], mediaByKey: mediaByKey)
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

    private func statusIDs(from url: URL, report: inout DiscoveryReport) async throws -> [String] {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 AppleTV SpaceXTV/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        report.add("HTTP \(statusCode), \(data.count) bytes")

        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode),
              let body = String(data: data, encoding: .utf8) else {
            throw BroadcastDiscoveryError.invalidResponse
        }

        let normalizedBody = body
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: #"\\u002F"#, with: "/")
            .replacingOccurrences(of: #"\u002F"#, with: "/")

        let patterns = [
            #"(?:https?:)?//(?:x|twitter)\.com/[Ss]pace[Xx]/status/([0-9]{10,})"#,
            #"/[Ss]pace[Xx]/status/([0-9]{10,})"#,
            #""status_id":"([0-9]{10,})""#,
            #""rest_id":"([0-9]{10,})""#,
        ]

        var ids: [String] = []
        for pattern in patterns {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(normalizedBody.startIndex ..< normalizedBody.endIndex, in: normalizedBody)
            let matches = regex.matches(in: normalizedBody, range: range)
            ids.append(
                contentsOf: matches.compactMap { match in
                    guard match.numberOfRanges > 1,
                          let range = Range(match.range(at: 1), in: normalizedBody) else {
                        return nil
                    }
                    return String(normalizedBody[range])
                }
            )
        }

        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func debugMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private func bestVariant(from media: [XAPIMedia]) -> XAPIMediaVariant? {
        let variants = media.flatMap { $0.variants ?? [] }
            .filter { $0.url.scheme?.hasPrefix("http") == true }

        if let hls = variants.first(where: { variant in
            variant.contentType == "application/x-mpegURL" || variant.url.pathExtension == "m3u8"
        }) {
            return hls
        }

        return variants
            .filter { $0.contentType == "video/mp4" || $0.url.pathExtension == "mp4" }
            .sorted { ($0.bitRate ?? 0) > ($1.bitRate ?? 0) }
            .first
    }
}

private struct BroadcastCandidate {
    var statusURL: URL
    var streamURL: URL?
    var title: String = "SpaceX Broadcast"
    var subtitle: String
    var tweetText: String? = nil
    var publishedAt: Date? = nil
    var thumbnailURL: URL? = nil
}

struct BroadcastDiscoveryResult {
    var broadcasts: [Broadcast]
    var report: DiscoveryReport
}

struct DiscoveryReport: Equatable {
    private(set) var lines: [String] = []

    mutating func add(_ line: String) {
        lines.append(line)
        print("[SpaceXTV] \(line)")
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
}

private struct XAPIPostsResponse: Decodable {
    var data: [XAPIPost]?
    var includes: XAPIIncludes?
}

private struct XAPIPost: Decodable {
    var id: String
    var text: String?
    var createdAt: Date?
    var attachments: XAPIPostAttachments?

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
        case attachments
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
}

private struct XAPIMedia: Decodable {
    var mediaKey: String
    var type: String?
    var variants: [XAPIMediaVariant]?
    var previewImageURL: URL?
    var width: Int?
    var height: Int?

    enum CodingKeys: String, CodingKey {
        case mediaKey = "media_key"
        case type
        case variants
        case previewImageURL = "preview_image_url"
        case width
        case height
    }
}

private struct XAPIMediaVariant: Decodable {
    var bitRate: Int?
    var contentType: String?
    var url: URL

    enum CodingKeys: String, CodingKey {
        case bitRate = "bit_rate"
        case contentType = "content_type"
        case url
    }
}

private struct XAPITimeline {
    var posts: [XAPIPost]
    var mediaByKey: [String: XAPIMedia]
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
