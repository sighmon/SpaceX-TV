import Foundation

enum BroadcastResolverError: LocalizedError {
    case invalidResponse
    case missingStream
    case missingBroadcastID
    case missingWebBearerToken

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The resolver returned a response the app could not understand."
        case .missingStream:
            "No playable HLS stream was found for this broadcast."
        case .missingBroadcastID:
            "The X broadcast URL did not contain a broadcast ID."
        case .missingWebBearerToken:
            "The app could not resolve X web playback credentials for this broadcast."
        }
    }
}

struct BroadcastResolver {
    var session: URLSession = .shared

    func resolve(_ broadcast: Broadcast) async throws -> ResolvedBroadcast {
        switch broadcast.sourceKind {
        case .hls:
            return ResolvedBroadcast(title: broadcast.title, streamURL: broadcast.sourceURL)
        case .xBroadcast:
            if let streamURL = broadcast.streamURL {
                return ResolvedBroadcast(title: broadcast.title, streamURL: streamURL)
            }

            let streamURL = try await streamURL(fromStatusURL: broadcast.sourceURL)
            return ResolvedBroadcast(title: broadcast.title, streamURL: streamURL)
        }
    }

    func streamURL(fromStatusURL statusURL: URL) async throws -> URL {
        if let broadcastID = xBroadcastID(from: statusURL) {
            return try await xBroadcastStreamURL(broadcastID: broadcastID)
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

        let pattern = #"https:\/\/[^"'<>\s\\]+\.m3u8(?:\?[^"'<>\s\\]+)?"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(normalizedBody.startIndex ..< normalizedBody.endIndex, in: normalizedBody)

        let streamURL = regex.matches(in: normalizedBody, range: range)
            .compactMap { Range($0.range, in: normalizedBody).map { String(normalizedBody[$0]) } }
            .compactMap(URL.init(string:))
            .first { $0.host?.contains("pscp.tv") == true || $0.pathExtension == "m3u8" }

        guard let streamURL else {
            throw BroadcastResolverError.missingStream
        }

        return try await highestQualityStreamURL(from: streamURL)
    }

    private func xBroadcastID(from url: URL) -> String? {
        let pathComponents = url.pathComponents
        guard let broadcastsIndex = pathComponents.firstIndex(of: "broadcasts"),
              pathComponents.indices.contains(pathComponents.index(after: broadcastsIndex)) else {
            return nil
        }

        return pathComponents[pathComponents.index(after: broadcastsIndex)]
    }

    private func xBroadcastStreamURL(broadcastID: String) async throws -> URL {
        let webBearerToken = try await xWebBearerToken()
        let guestToken = try await xGuestToken(bearerToken: webBearerToken)
        let broadcast = try await xBroadcast(
            broadcastID: broadcastID,
            bearerToken: webBearerToken,
            guestToken: guestToken
        )
        let source = try await xLiveVideoSource(
            mediaKey: broadcast.mediaKey,
            bearerToken: webBearerToken,
            guestToken: guestToken
        )

        guard let streamURL = source.noRedirectPlaybackURL ?? source.location else {
            throw BroadcastResolverError.missingStream
        }

        return try await highestQualityStreamURL(from: streamURL)
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
        let homeURL = URL(string: "https://x.com/")!
        let home = try await string(from: homeURL)
        if let token = webBearerToken(in: home) {
            return token
        }

        let scriptURLs = webScriptURLs(in: home)
        for scriptURL in scriptURLs.prefix(10) {
            let script = try await string(from: scriptURL)
            if let token = webBearerToken(in: script) {
                return token
            }
        }

        throw BroadcastResolverError.missingWebBearerToken
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

    private func webScriptURLs(in body: String) -> [URL] {
        let pattern = #"https:\/\/abs\.twimg\.com\/responsive-web\/client-web\/[^"'<>\s]+\.js"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(body.startIndex ..< body.endIndex, in: body)
        let matches = regex?.matches(in: body, range: range) ?? []
        var seen = Set<URL>()
        let urls = matches.compactMap { match -> URL? in
            guard let range = Range(match.range, in: body),
                  let url = URL(string: String(body[range])) else {
                return nil
            }
            return seen.insert(url).inserted ? url : nil
        }

        return urls.sorted { lhs, rhs in
            let lhsIsMain = lhs.lastPathComponent.hasPrefix("main.")
            let rhsIsMain = rhs.lastPathComponent.hasPrefix("main.")
            if lhsIsMain != rhsIsMain {
                return lhsIsMain
            }
            return lhs.absoluteString < rhs.absoluteString
        }
    }

    private func webBearerToken(in body: String) -> String? {
        let patterns = [
            #"Bearer ([A-Za-z0-9%._-]+)"#,
            #""(AAAAAAAA[A-Za-z0-9%._-]+)""#,
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

    private func xAPIData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            throw BroadcastResolverError.invalidResponse
        }
        return data
    }

    private func highestQualityStreamURL(from streamURL: URL) async throws -> URL {
        guard streamURL.pathExtension.lowercased() == "m3u8" else {
            return streamURL
        }

        var request = URLRequest(url: streamURL)
        request.setValue("Mozilla/5.0 AppleTV SpaceXTV/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.periscope.tv/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode),
              let playlist = String(data: data, encoding: .utf8) else {
            return streamURL
        }

        guard let variant = highestBandwidthVariant(in: playlist, relativeTo: streamURL) else {
            return streamURL
        }

        return variant
    }

    private func highestBandwidthVariant(in playlist: String, relativeTo masterURL: URL) -> URL? {
        let lines = playlist.components(separatedBy: .newlines)
        var bestBandwidth = 0
        var bestURL: URL?
        var pendingBandwidth: Int?

        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingBandwidth = bandwidth(from: line)
                continue
            }

            guard let bandwidth = pendingBandwidth,
                  !line.isEmpty,
                  !line.hasPrefix("#"),
                  bandwidth > bestBandwidth else {
                continue
            }

            bestBandwidth = bandwidth
            bestURL = URL(string: line, relativeTo: masterURL)?.absoluteURL
            pendingBandwidth = nil
        }

        return bestURL
    }

    private func bandwidth(from streamInfo: String) -> Int? {
        guard let range = streamInfo.range(of: #"BANDWIDTH=(\d+)"#, options: .regularExpression) else {
            return nil
        }

        let value = streamInfo[range]
            .replacingOccurrences(of: "BANDWIDTH=", with: "")
        return Int(value)
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

private struct XBroadcast: Decodable {
    var mediaKey: String

    enum CodingKeys: String, CodingKey {
        case mediaKey = "media_key"
    }
}

private struct XLiveVideoStreamResponse: Decodable {
    var source: XLiveVideoSource
}

private struct XLiveVideoSource: Decodable {
    var location: URL?
    var noRedirectPlaybackURL: URL?

    enum CodingKeys: String, CodingKey {
        case location
        case noRedirectPlaybackURL = "noRedirectPlaybackUrl"
    }
}
