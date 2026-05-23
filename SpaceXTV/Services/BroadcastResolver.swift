import Foundation

enum BroadcastResolverError: LocalizedError {
    case invalidResponse
    case missingStream

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The resolver returned a response the app could not understand."
        case .missingStream:
            "No live HLS stream was found for this broadcast."
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

        return streamURL
    }
}
