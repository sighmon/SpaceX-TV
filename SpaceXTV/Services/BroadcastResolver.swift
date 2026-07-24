import Foundation

enum BroadcastResolverError: LocalizedError, Equatable {
    case invalidResponse
    case missingStream
    case missingBroadcastID
    case missingWebBearerToken
    /// X has published a broadcast card, but the live stream has not begun yet.
    case notStarted(scheduledStart: Date?)

    var failureTitle: String {
        switch self {
        case .notStarted:
            "Livestream not started"
        default:
            "Stream unavailable"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The resolver returned a response the app could not understand."
        case .missingStream:
            "No playable HLS or MP4 stream was found for this broadcast."
        case .missingBroadcastID:
            "The X broadcast URL did not contain a broadcast ID."
        case .missingWebBearerToken:
            "The app could not resolve X web playback credentials for this broadcast."
        case .notStarted(let scheduledStart):
            Self.notStartedMessage(scheduledStart: scheduledStart)
        }
    }

    static func notStartedMessage(scheduledStart: Date?, now: Date = Date()) -> String {
        guard let scheduledStart else {
            return "This livestream has not started yet. Check back closer to the scheduled start time."
        }

        // DateFormatter is not thread-safe; build one per call (message formatting is rare).
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let when = formatter.string(from: scheduledStart)
        if scheduledStart > now {
            return "Live coverage is scheduled to start \(when)."
        }
        return "Live coverage was scheduled for \(when) and should begin soon."
    }
}

struct BroadcastResolver {
    var session: URLSession = .shared

    private static let tweetResultFeatures: [String: Bool] = [
        "creator_subscriptions_tweet_preview_api_enabled": true,
        "premium_content_api_read_enabled": true,
        "communities_web_enable_tweet_community_results_fetch": true,
        "c9s_tweet_anatomy_moderator_badge_enabled": true,
        "responsive_web_grok_analyze_button_fetch_trends_enabled": true,
        "responsive_web_grok_analyze_post_followups_enabled": true,
        "rweb_cashtags_composer_attachment_enabled": true,
        "responsive_web_jetfuel_frame": true,
        "responsive_web_grok_share_attachment_enabled": true,
        "responsive_web_grok_annotations_enabled": true,
        "articles_preview_enabled": true,
        "responsive_web_edit_tweet_api_enabled": true,
        "graphql_is_translatable_rweb_tweet_is_translatable_enabled": true,
        "view_counts_everywhere_api_enabled": true,
        "longform_notetweets_consumption_enabled": true,
        "responsive_web_twitter_article_tweet_consumption_enabled": true,
        "tweet_awards_web_tipping_enabled": false,
        "responsive_web_grok_show_grok_translated_post": true,
        "responsive_web_grok_analysis_button_from_backend": true,
        "standardized_nudges_misinfo": true,
        "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": true,
        "longform_notetweets_rich_text_read_enabled": true,
        "longform_notetweets_inline_media_enabled": true,
        "responsive_web_grok_image_annotation_enabled": true,
        "responsive_web_grok_imagine_annotation_enabled": true,
        "responsive_web_grok_community_note_auto_translation_is_enabled": true,
        "responsive_web_enhance_cards_enabled": true,
    ]

    private static let tweetResultFieldToggles: [String: Bool] = [
        "withArticleRichContentState": true,
        "withArticlePlainText": true,
        "withGrokAnalyze": true,
        "withDisallowedReplyControls": true,
    ]

    func resolve(_ broadcast: Broadcast) async throws -> ResolvedBroadcast {
        switch broadcast.sourceKind {
        case .hls:
            return ResolvedBroadcast(title: broadcast.title, streamURL: broadcast.sourceURL, thumbnailURL: broadcast.thumbnailURL)
        case .youtube:
            throw BroadcastResolverError.missingStream
        case .xBroadcast:
            if let streamURL = broadcast.streamURL {
                return ResolvedBroadcast(
                title: broadcast.title,
                streamURL: try await highestQualityStreamURL(from: streamURL),
                thumbnailURL: broadcast.thumbnailURL,
                isLive: broadcast.isLive
            )
        }

            let resolved = try await resolveStatusURL(broadcast.sourceURL)
            return ResolvedBroadcast(
                title: broadcast.title,
                streamURL: resolved.streamURL,
                thumbnailURL: broadcast.thumbnailURL ?? resolved.thumbnailURL,
                isLive: resolved.isLive
            )
        }
    }

    func streamURL(fromStatusURL statusURL: URL) async throws -> URL {
        try await resolveStatusURL(statusURL).streamURL
    }

    func resolveStatusURL(_ statusURL: URL) async throws -> ResolvedBroadcast {
        if let broadcastID = xBroadcastID(from: statusURL) {
            return try await xBroadcastStream(broadcastID: broadcastID)
        }

        var request = URLRequest(url: statusURL)
        request.setValue("Mozilla/5.0 AppleTV SpaceXTV/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode),
              let body = String(data: data, encoding: .utf8) else {
            throw BroadcastResolverError.invalidResponse
        }

        let normalizedBody = body
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: #"\\u002F"#, with: "/")
            .replacingOccurrences(of: #"\u002F"#, with: "/")
            .replacingOccurrences(of: "%2F", with: "/")
            .replacingOccurrences(of: "%3A", with: ":")
            .replacingOccurrences(of: "%3F", with: "?")
            .replacingOccurrences(of: "%3D", with: "=")
            .replacingOccurrences(of: "%26", with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")

        guard let streamURL = try playbackURL(inPageBody: normalizedBody) else {
            throw BroadcastResolverError.missingStream
        }

        return ResolvedBroadcast(
            title: nil,
            streamURL: try await highestQualityStreamURL(from: streamURL),
            thumbnailURL: pageThumbnailURL(in: normalizedBody)
        )
    }

    func playbackURL(inPageBody body: String) throws -> URL? {
        let range = NSRange(body.startIndex ..< body.endIndex, in: body)

        for fileExtension in ["m3u8", "mp4"] {
            let pattern = #"https:\/\/[^"'<>\s\\]+\."# + fileExtension + #"(?:\?[^"'<>\s\\]+)?"#
            let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            if let streamURL = regex.matches(in: body, range: range)
                .compactMap({ Range($0.range, in: body).map { String(body[$0]) } })
                .compactMap(URL.init(string:))
                .first {
                return streamURL
            }
        }

        return nil
    }

    private func xBroadcastID(from url: URL) -> String? {
        let pathComponents = url.pathComponents
        guard let broadcastsIndex = pathComponents.firstIndex(of: "broadcasts"),
              pathComponents.indices.contains(pathComponents.index(after: broadcastsIndex)) else {
            return nil
        }

        return pathComponents[pathComponents.index(after: broadcastsIndex)]
    }

    private func xBroadcastStream(broadcastID: String) async throws -> ResolvedBroadcast {
        let webConfiguration = try await xWebConfiguration()
        let webBearerToken = webConfiguration.bearerToken
        let guestToken = try await xGuestToken(bearerToken: webBearerToken)

        do {
            let broadcast = try await xBroadcast(
                broadcastID: broadcastID,
                bearerToken: webBearerToken,
                guestToken: guestToken
            )

            // X publishes the card (and scheduled start) before the HLS endpoint exists.
            // Only state drives this message — never rewrite auth/network failures as "not started".
            // Check before requiring media_key so pre-live payloads without one still get friendly copy.
            if broadcast.hasNotStarted {
                throw BroadcastResolverError.notStarted(scheduledStart: broadcast.scheduledStartDate)
            }

            guard let mediaKey = broadcast.mediaKey, !mediaKey.isEmpty else {
                throw BroadcastResolverError.missingStream
            }

            let source = try await xLiveVideoSource(
                mediaKey: mediaKey,
                bearerToken: webBearerToken,
                guestToken: guestToken
            )

            guard let streamURL = source.noRedirectPlaybackURL ?? source.location else {
                throw BroadcastResolverError.missingStream
            }

            var thumbnailURL = broadcast.bestThumbnailURL ?? source.thumbnailURL
            if thumbnailURL == nil {
                thumbnailURL = try? await broadcastPageThumbnailURL(broadcastID: broadcastID)
            }

            return ResolvedBroadcast(
                title: broadcast.title,
                streamURL: try await highestQualityStreamURL(from: streamURL),
                thumbnailURL: thumbnailURL,
                isLive: broadcast.isLive
            )
        } catch {
            // Preserve "not started yet" messaging; do not fall through to tweet lookup.
            if case BroadcastResolverError.notStarted = error {
                throw error
            }
            guard broadcastID.allSatisfy(\.isNumber) else {
                throw error
            }
            return try await xTweetBroadcastStream(
                tweetID: broadcastID,
                bearerToken: webBearerToken,
                guestToken: guestToken,
                queryID: webConfiguration.tweetResultByRestIDQueryID
            )
        }
    }

    private func xTweetBroadcastStream(
        tweetID: String,
        bearerToken: String,
        guestToken: String,
        queryID: String?
    ) async throws -> ResolvedBroadcast {
        let broadcast = try await xTweetBroadcast(
            tweetID: tweetID,
            bearerToken: bearerToken,
            guestToken: guestToken,
            queryID: queryID
        )

        // State-only: do not infer "not started" from a future schedule when the stream probe fails.
        // Check before requiring media_key so pre-live tweet cards without one still get friendly copy.
        if broadcast.hasNotStarted {
            throw BroadcastResolverError.notStarted(scheduledStart: broadcast.scheduledStartDate)
        }

        guard let mediaKey = broadcast.mediaKey, !mediaKey.isEmpty else {
            throw BroadcastResolverError.missingStream
        }

        let source = try await xLiveVideoSource(
            mediaKey: mediaKey,
            bearerToken: bearerToken,
            guestToken: guestToken
        )

        guard let streamURL = source.noRedirectPlaybackURL ?? source.location else {
            throw BroadcastResolverError.missingStream
        }

        return ResolvedBroadcast(
            title: broadcast.title,
            streamURL: try await highestQualityStreamURL(from: streamURL),
            thumbnailURL: broadcast.thumbnailURL ?? source.thumbnailURL,
            isLive: broadcast.isLive
        )
    }

    private func broadcastPageThumbnailURL(broadcastID: String) async throws -> URL? {
        guard let url = URL(string: "https://x.com/i/broadcasts/\(broadcastID)") else {
            return nil
        }
        let body = try await string(from: url)
        return pageThumbnailURL(in: normalizedPageBody(body))
    }

    private func xGuestToken(bearerToken: String) async throws -> String {
        let url = URL(string: "https://api.x.com/1.1/guest/activate.json")!
        var request = xWebRequest(url: url, bearerToken: bearerToken)
        request.httpMethod = "POST"

        let data = try await xAPIData(for: request)
        let response = try JSONDecoder().decode(XGuestTokenResponse.self, from: data)
        return response.guestToken
    }

    private func xBroadcast(broadcastID: String, bearerToken: String, guestToken: String) async throws -> XBroadcast {
        var components = URLComponents(string: "https://api.x.com/1.1/broadcasts/show.json")!
        components.queryItems = [
            URLQueryItem(name: "ids", value: broadcastID),
        ]

        guard let url = components.url else {
            throw BroadcastResolverError.invalidResponse
        }

        let request = xWebRequest(url: url, bearerToken: bearerToken, guestToken: guestToken)
        let data = try await xAPIData(for: request)
        let response = try JSONDecoder().decode(XBroadcastShowResponse.self, from: data)
        guard let broadcast = response.broadcasts[broadcastID] else {
            throw BroadcastResolverError.invalidResponse
        }
        return broadcast
    }

    private func xTweetBroadcast(
        tweetID: String,
        bearerToken: String,
        guestToken: String,
        queryID: String?
    ) async throws -> XTweetBroadcast {
        guard let queryID, !queryID.isEmpty else {
            throw BroadcastResolverError.invalidResponse
        }
        var components = URLComponents(string: "https://x.com/i/api/graphql/\(queryID)/TweetResultByRestId")!
        components.queryItems = [
            URLQueryItem(
                name: "variables",
                value: jsonQueryValue([
                    "tweetId": tweetID,
                    "withCommunity": false,
                    "includePromotedContent": false,
                    "withVoice": false,
                ])
            ),
            URLQueryItem(name: "features", value: jsonQueryValue(Self.tweetResultFeatures)),
            URLQueryItem(name: "fieldToggles", value: jsonQueryValue(Self.tweetResultFieldToggles)),
        ]

        guard let url = components.url else {
            throw BroadcastResolverError.invalidResponse
        }

        let request = xWebRequest(url: url, bearerToken: bearerToken, guestToken: guestToken)
        let data = try await xAPIData(for: request)
        let response = try JSONDecoder().decode(XTweetResultResponse.self, from: data)
        guard let bindingValues = response.data.tweetResult.result.card?.legacy.bindingValues else {
            throw BroadcastResolverError.missingStream
        }

        let values = Dictionary(uniqueKeysWithValues: bindingValues.map { ($0.key, $0.value) })
        // Do not require media_key before reading state — pre-live cards may omit it.
        return XTweetBroadcast(
            mediaKey: values["broadcast_media_key"]?.stringValue,
            title: values["broadcast_title"]?.stringValue,
            thumbnailURL: [
                values["broadcast_thumbnail_original"]?.imageValue?.url,
                values["broadcast_thumbnail_x_large"]?.imageValue?.url,
                values["broadcast_thumbnail"]?.imageValue?.url,
                values["broadcast_pre_live_slate_x_large"]?.imageValue?.url,
            ].compactMap { $0 }.first,
            state: values["broadcast_state"]?.stringValue,
            scheduledStartDate: Self.dateFromTweetScheduledStart(
                values["broadcast_scheduled_start_time"]
            )
        )
    }

    private static func dateFromTweetScheduledStart(_ value: XTweetResultResponse.Value?) -> Date? {
        // Tweet card bindings expose scheduled start only as string_value (epoch milliseconds).
        XBroadcast.date(fromMillisecondsString: value?.stringValue)
    }

    private func xLiveVideoSource(mediaKey: String, bearerToken: String, guestToken: String) async throws -> XLiveVideoSource {
        let url = URL(string: "https://api.x.com/1.1/live_video_stream/status/\(mediaKey)")!
        let request = xWebRequest(url: url, bearerToken: bearerToken, guestToken: guestToken)
        let data = try await xAPIData(for: request)
        return try JSONDecoder().decode(XLiveVideoStreamResponse.self, from: data).source
    }

    private func xWebRequest(url: URL, bearerToken: String, guestToken: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if let guestToken {
            request.setValue(guestToken, forHTTPHeaderField: "x-guest-token")
        }
        request.setValue("en", forHTTPHeaderField: "x-twitter-client-language")
        request.setValue("yes", forHTTPHeaderField: "x-twitter-active-user")
        request.timeoutInterval = 15
        return request
    }

    private func xWebBearerToken() async throws -> String {
        try await xWebConfiguration().bearerToken
    }

    private func xWebConfiguration() async throws -> XWebConfiguration {
        let homeURL = URL(string: "https://x.com/")!
        let home = try await string(from: homeURL)
        var bearerToken = webBearerToken(in: home)
        var tweetResultQueryID = tweetResultByRestIDQueryID(in: home)

        // X's logged-out SPA only links an entry module; guest-token and other
        // chunks are relative imports. Expand the module graph, then fetch in
        // priority order (guest-token first).
        var candidates = webScriptURLs(in: home)
        var visited = Set<URL>()
        let maxFetches = 15

        while !candidates.isEmpty,
              visited.count < maxFetches,
              bearerToken == nil || tweetResultQueryID == nil {
            let scriptURL = candidates.removeFirst()
            guard visited.insert(scriptURL).inserted else {
                continue
            }

            // One bad relative URL (e.g. doubled assets/) must not abort guest auth.
            let script: String
            do {
                script = try await string(from: scriptURL)
            } catch {
                continue
            }
            if bearerToken == nil {
                bearerToken = webBearerToken(in: script)
            }
            if tweetResultQueryID == nil {
                tweetResultQueryID = tweetResultByRestIDQueryID(in: script)
            }

            let discovered = webScriptURLs(in: script, baseURL: scriptURL)
            guard !discovered.isEmpty else {
                continue
            }

            var merged: [URL] = []
            var seen = visited
            for url in prioritizeWebScripts(discovered + candidates) where seen.insert(url).inserted {
                merged.append(url)
            }
            candidates = merged
        }

        guard let bearerToken else {
            throw BroadcastResolverError.missingWebBearerToken
        }

        return XWebConfiguration(
            bearerToken: bearerToken,
            tweetResultByRestIDQueryID: tweetResultQueryID
        )
    }

    private func string(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 AppleTV SpaceXTV/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode),
              let body = String(data: data, encoding: .utf8) else {
            throw BroadcastResolverError.invalidResponse
        }
        return body
    }

    /// Collect absolute CDN script URLs from HTML/JS, plus relative ES-module
    /// imports when `baseURL` is the module that declared them.
    func webScriptURLs(in body: String, baseURL: URL? = nil) -> [URL] {
        var urls: [URL] = []
        var seen = Set<URL>()

        // Require a real `.js` suffix (not `.jsxs` / `.json` fragments in minified bundles).
        let absolutePattern = #"https:\/\/abs\.twimg\.com\/(?:responsive-web\/client-web|x-web\/x-web)\/[^"'<>\s`]+\.js\b"#
        if let regex = try? NSRegularExpression(pattern: absolutePattern) {
            let range = NSRange(body.startIndex ..< body.endIndex, in: body)
            for match in regex.matches(in: body, range: range) {
                guard let range = Range(match.range, in: body),
                      let url = URL(string: String(body[range])),
                      seen.insert(url).inserted else {
                    continue
                }
                urls.append(url)
            }
        }

        if let baseURL {
            let relativePattern = #"["']((?:\./|\.\./)?(?:assets/)?[^"'<>\s`]+\.js)["']"#
            if let regex = try? NSRegularExpression(pattern: relativePattern) {
                let range = NSRange(body.startIndex ..< body.endIndex, in: body)
                for match in regex.matches(in: body, range: range) {
                    guard match.numberOfRanges > 1,
                          let relativeRange = Range(match.range(at: 1), in: body) else {
                        continue
                    }
                    let relative = String(body[relativeRange])
                    if relative.hasPrefix("http://") || relative.hasPrefix("https://") {
                        continue
                    }
                    // Ignore bare package-style paths that are not under this CDN module tree.
                    guard relative.hasPrefix("./")
                        || relative.hasPrefix("../")
                        || relative.hasPrefix("assets/") else {
                        continue
                    }
                    // Reject accidental matches where `.js` is only a prefix (e.g. `.jsxs`).
                    guard relative.hasSuffix(".js") else {
                        continue
                    }
                    guard let url = resolveWebScriptURL(relative: relative, baseURL: baseURL),
                          seen.insert(url).inserted else {
                        continue
                    }
                    urls.append(url)
                }
            }
        }

        return prioritizeWebScripts(urls)
    }

    /// Resolves relative ES-module paths from an X CDN script.
    ///
    /// Bare `assets/...` paths are package-root relative (same as from the entry
    /// module). Resolving them with `URL(string:relativeTo:)` against a script
    /// already under `/assets/` produces a doubled `assets/assets/` path that 404s
    /// and used to abort guest-token discovery before pre-live broadcasts could
    /// be classified as not-started.
    func resolveWebScriptURL(relative: String, baseURL: URL) -> URL? {
        if relative.hasPrefix("assets/") {
            return URL(string: relative, relativeTo: xWebPackageRoot(from: baseURL))?.absoluteURL
        }
        return URL(string: relative, relativeTo: baseURL)?.absoluteURL
    }

    /// Directory that contains the entry script and the `assets/` folder.
    /// e.g. `…/x-web/x-web/assets/foo.js` and `…/x-web/x-web/entry.js` → `…/x-web/x-web/`.
    func xWebPackageRoot(from url: URL) -> URL {
        var path = url.path
        if let assetsRange = path.range(of: "/assets/") {
            path = String(path[..<assetsRange.lowerBound]) + "/"
        } else {
            path = url.deletingLastPathComponent().path
            if !path.hasSuffix("/") {
                path += "/"
            }
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.deletingLastPathComponent()
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url ?? url.deletingLastPathComponent()
    }

    func prioritizeWebScripts(_ urls: [URL]) -> [URL] {
        urls.sorted { lhs, rhs in
            let lhsPriority = webScriptPriority(lhs)
            let rhsPriority = webScriptPriority(rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.absoluteString < rhs.absoluteString
        }
    }

    private func webScriptPriority(_ url: URL) -> Int {
        let name = url.lastPathComponent
        if name.hasPrefix("guest-token-") {
            return 0
        }
        if name.hasPrefix("main.") {
            return 1
        }
        if name.hasPrefix("entry-") || name.contains("entry-client") {
            return 2
        }
        return 3
    }

    private func webBearerToken(in body: String) -> String? {
        let patterns = [
            #"Bearer ([A-Za-z0-9%._-]+)"#,
            #"["'`](AAAAAAAA[A-Za-z0-9%._-]+)["'`]"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(body.startIndex ..< body.endIndex, in: body)
            guard let match = regex.firstMatch(in: body, range: range),
                  match.numberOfRanges > 1,
                  let tokenRange = Range(match.range(at: 1), in: body) else {
                continue
            }
            return String(body[tokenRange])
        }

        return nil
    }

    private func tweetResultByRestIDQueryID(in body: String) -> String? {
        firstMatch(
            pattern: #"queryId:"([^"]+)",operationName:"TweetResultByRestId""#,
            in: body
        ) ?? firstMatch(
            pattern: #"operationName:"TweetResultByRestId",queryId:"([^"]+)""#,
            in: body
        )
    }

    private func xAPIData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            throw BroadcastResolverError.invalidResponse
        }
        return data
    }

    private func jsonQueryValue(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private func highestQualityStreamURL(from streamURL: URL) async throws -> URL {
        guard streamURL.pathExtension.lowercased() == "m3u8" else {
            return streamURL
        }

        // Keep HLS playback on the master playlist. SpaceX/X archive streams can
        // include signed variant and segment URLs, and pinning playback to a
        // resolved child playlist can expire during long sessions or later seeks.
        return streamURL
    }

    private func pageThumbnailURL(in body: String) -> URL? {
        let patterns = [
            #"<meta[^>]+(?:property|name)=["']og:image(?::secure_url)?["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']og:image(?::secure_url)?["']"#,
            #"<meta[^>]+(?:property|name)=["']twitter:image(?::src)?["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']twitter:image(?::src)?["']"#,
            #""(?:thumbnail_image_original|thumbnail_image|preview_image_url|image_url_original|image_url_large|image_url_medium|image_url|poster_image|posterImage|thumbnailUrl|thumbnail_url)"\s*:\s*"([^"]+)""#,
        ]

        for pattern in patterns {
            guard let match = firstMatch(pattern: pattern, in: body) else {
                continue
            }
            let decoded = htmlDecoded(match)
                .replacingOccurrences(of: #"\/"#, with: "/")
            if let url = URL(string: decoded), url.scheme?.hasPrefix("http") == true {
                return url
            }
        }

        return nil
    }

    private func firstMatch(pattern: String, in body: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(body.startIndex ..< body.endIndex, in: body)
        guard let match = regex.firstMatch(in: body, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: body) else {
            return nil
        }
        return String(body[valueRange])
    }

    private func htmlDecoded(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private func normalizedPageBody(_ body: String) -> String {
        body
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: #"\\u002F"#, with: "/")
            .replacingOccurrences(of: #"\u002F"#, with: "/")
            .replacingOccurrences(of: "%2F", with: "/")
            .replacingOccurrences(of: "%3A", with: ":")
            .replacingOccurrences(of: "%3F", with: "?")
            .replacingOccurrences(of: "%3D", with: "=")
            .replacingOccurrences(of: "%26", with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

private struct XBroadcastShowResponse: Decodable {
    var broadcasts: [String: XBroadcast]
}

private struct XGuestTokenResponse: Decodable {
    var guestToken: String

    enum CodingKeys: String, CodingKey {
        case guestToken = "guest_token"
    }
}

private struct XWebConfiguration {
    var bearerToken: String
    var tweetResultByRestIDQueryID: String?
}

/// Decodes X `broadcasts/show.json` entries. Internal so tests can cover schedule/media_key edge cases.
struct XBroadcast: Decodable, Equatable {
    /// Optional so NOT_STARTED payloads can decode even if X omits media_key.
    var mediaKey: String?
    var title: String?
    var imageURL: URL?
    var imageURLOriginal: URL?
    var imageURLSmall: URL?
    var imageURLMedium: URL?
    var imageURLLarge: URL?
    var thumbnailURL: URL?
    var thumbnailURLSmall: URL?
    var thumbnailURLMedium: URL?
    var thumbnailURLLarge: URL?
    var preLiveSlateURL: URL?
    var state: String?
    var scheduledStartDate: Date?

    var bestThumbnailURL: URL? {
        [
            imageURLOriginal,
            imageURLLarge,
            imageURLMedium,
            imageURL,
            imageURLSmall,
            thumbnailURLLarge,
            thumbnailURLMedium,
            thumbnailURL,
            thumbnailURLSmall,
            preLiveSlateURL,
        ].compactMap { $0 }.first
    }

    var isLive: Bool? {
        guard let state else { return nil }
        return state.lowercased() == "running"
    }

    var hasNotStarted: Bool {
        Self.isNotStartedState(state)
    }

    enum CodingKeys: String, CodingKey {
        case mediaKey = "media_key"
        case title = "status"
        case imageURL = "image_url"
        case imageURLOriginal = "image_url_original"
        case imageURLSmall = "image_url_small"
        case imageURLMedium = "image_url_medium"
        case imageURLLarge = "image_url_large"
        case thumbnailURL = "thumbnail_url"
        case thumbnailURLSmall = "thumbnail_url_small"
        case thumbnailURLMedium = "thumbnail_url_medium"
        case thumbnailURLLarge = "thumbnail_url_large"
        case preLiveSlateURL = "pre_live_slate_url"
        case state
        case scheduledStartMs = "scheduled_start_ms"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mediaKey = try container.decodeIfPresent(String.self, forKey: .mediaKey)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        imageURL = try container.decodeIfPresent(URL.self, forKey: .imageURL)
        imageURLOriginal = try container.decodeIfPresent(URL.self, forKey: .imageURLOriginal)
        imageURLSmall = try container.decodeIfPresent(URL.self, forKey: .imageURLSmall)
        imageURLMedium = try container.decodeIfPresent(URL.self, forKey: .imageURLMedium)
        imageURLLarge = try container.decodeIfPresent(URL.self, forKey: .imageURLLarge)
        thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        thumbnailURLSmall = try container.decodeIfPresent(URL.self, forKey: .thumbnailURLSmall)
        thumbnailURLMedium = try container.decodeIfPresent(URL.self, forKey: .thumbnailURLMedium)
        thumbnailURLLarge = try container.decodeIfPresent(URL.self, forKey: .thumbnailURLLarge)
        preLiveSlateURL = try container.decodeIfPresent(URL.self, forKey: .preLiveSlateURL)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        // String or number epoch-ms (X has shipped both shapes for similar fields).
        scheduledStartDate = try container.decodeIfPresent(FlexibleMillisecondsDate.self, forKey: .scheduledStartMs)?.date
    }

    static func isNotStartedState(_ state: String?) -> Bool {
        guard let state else { return false }
        switch state.lowercased() {
        case "not_started", "pre_published":
            return true
        default:
            return false
        }
    }

    static func date(fromMillisecondsString value: String?) -> Date? {
        guard let value, let milliseconds = Double(value) else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}

/// Accepts X epoch-ms fields as either JSON string or number.
struct FlexibleMillisecondsDate: Decodable, Equatable {
    var date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            date = nil
            return
        }
        if let string = try? container.decode(String.self) {
            date = XBroadcast.date(fromMillisecondsString: string)
            return
        }
        if let int = try? container.decode(Int64.self) {
            date = Date(timeIntervalSince1970: Double(int) / 1_000)
            return
        }
        if let double = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: double / 1_000)
            return
        }
        date = nil
    }
}

private struct XTweetBroadcast {
    /// Optional so NOT_STARTED tweet cards can decode even if X omits media_key.
    var mediaKey: String?
    var title: String?
    var thumbnailURL: URL?
    var state: String?
    var scheduledStartDate: Date?

    var isLive: Bool? {
        guard let state else { return nil }
        return state.lowercased() == "running"
    }

    var hasNotStarted: Bool {
        XBroadcast.isNotStartedState(state)
    }
}

private struct XTweetResultResponse: Decodable {
    var data: DataContainer

    struct DataContainer: Decodable {
        var tweetResult: TweetResult
    }

    struct TweetResult: Decodable {
        var result: Tweet
    }

    struct Tweet: Decodable {
        var card: Card?
    }

    struct Card: Decodable {
        var legacy: Legacy
    }

    struct Legacy: Decodable {
        var bindingValues: [BindingValue]

        enum CodingKeys: String, CodingKey {
            case bindingValues = "binding_values"
        }
    }

    struct BindingValue: Decodable {
        var key: String
        var value: Value
    }

    struct Value: Decodable {
        var stringValue: String?
        var booleanValue: Bool?
        var imageValue: ImageValue?

        enum CodingKeys: String, CodingKey {
            case stringValue = "string_value"
            case booleanValue = "boolean_value"
            case imageValue = "image_value"
        }
    }

    struct ImageValue: Decodable {
        var url: URL?
    }
}

private struct XLiveVideoStreamResponse: Decodable {
    var source: XLiveVideoSource
}

private struct XLiveVideoSource: Decodable {
    var location: URL?
    var noRedirectPlaybackURL: URL?
    var sourceThumbnailURL: URL?
    var imageURL: URL?

    var thumbnailURL: URL? {
        sourceThumbnailURL ?? imageURL
    }

    enum CodingKeys: String, CodingKey {
        case location
        case noRedirectPlaybackURL = "noRedirectPlaybackUrl"
        case sourceThumbnailURL = "thumbnail_url"
        case imageURL = "image_url"
    }
}
