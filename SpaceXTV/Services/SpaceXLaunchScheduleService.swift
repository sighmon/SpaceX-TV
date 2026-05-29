import Foundation

enum SpaceXLaunchScheduleError: LocalizedError {
    case invalidResponse
    case noUpcomingLaunch

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "SpaceX returned launch data the app could not read."
        case .noUpcomingLaunch:
            "No upcoming SpaceX launch was returned."
        }
    }
}

struct SpaceXLaunchScheduleService {
    var session: URLSession = .shared

    private let tilesURL = URL(string: "https://content.spacex.com/api/spacex-website/launches-page-tiles/upcoming")!
    private let timingsURL = URL(string: "https://sxcontent9668.azureedge.us/cms-assets/future_missions.json")!

    func nextLaunch(now: Date = Date()) async throws -> NextLaunch {
        async let tiles = fetchUpcomingLaunchTiles()
        async let timings = fetchUpcomingLaunchTimings()
        return try nextLaunch(from: await tiles, timings: await timings, now: now)
    }

    private func fetchUpcomingLaunchTiles() async throws -> [SpaceXLaunchTile] {
        let data = try await data(from: tilesURL)
        do {
            return try JSONDecoder().decode([SpaceXLaunchTile].self, from: data)
        } catch {
            throw SpaceXLaunchScheduleError.invalidResponse
        }
    }

    private func fetchUpcomingLaunchTimings() async throws -> [String: SpaceXLaunchTiming] {
        let data = try await data(from: timingsURL)
        do {
            return try JSONDecoder().decode([String: SpaceXLaunchTiming].self, from: data)
        } catch {
            throw SpaceXLaunchScheduleError.invalidResponse
        }
    }

    private func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 AppleTV SpaceXTV/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            throw SpaceXLaunchScheduleError.invalidResponse
        }
        return data
    }

    private func nextLaunch(
        from tiles: [SpaceXLaunchTile],
        timings: [String: SpaceXLaunchTiming],
        now: Date
    ) throws -> NextLaunch {
        let launches = tiles.compactMap { tile -> NextLaunch? in
            guard let timing = timings[tile.correlationId],
                  let launchDate = timing.launchDate else {
                return nil
            }

            return NextLaunch(
                title: tile.displayTitle,
                vehicle: tile.vehicle,
                launchSite: tile.launchSite,
                launchDate: launchDate,
                windowCloseDate: timing.windowCloseDate,
                isLaunchTimePrecise: timing.isPrimaryLaunchTimeGiven,
                sourceURL: tile.sourceURL,
                imageURL: tile.imageURL
            )
        }

        if let next = launches
            .filter({ $0.launchDate >= now })
            .min(by: { $0.launchDate < $1.launchDate }) {
            return next
        }

        if let first = launches.min(by: { $0.launchDate > $1.launchDate }) {
            return first
        }

        throw SpaceXLaunchScheduleError.noUpcomingLaunch
    }
}

private struct SpaceXLaunchTile: Decodable {
    var correlationId: String
    var title: String
    var shortTitle: String?
    var link: String
    var vehicle: String?
    var launchSite: String?
    var imageDesktop: SpaceXLaunchImage?

    var displayTitle: String {
        guard let shortTitle, !shortTitle.isEmpty else { return title }
        return shortTitle
    }

    var sourceURL: URL {
        URL(string: "https://www.spacex.com/launches/\(link)") ?? URL(string: "https://www.spacex.com/launches")!
    }

    var imageURL: URL? {
        imageDesktop?.formats?.large?.url ?? imageDesktop?.url
    }
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

private struct SpaceXLaunchTiming: Decodable {
    var primaryLaunchDate: SpaceXTimestamp?
    var primaryLaunchWindow: SpaceXLaunchWindow?
    var tZeroLaunchDate: SpaceXTimestamp?
    var tZeroPaused: Bool?
    var isPrimaryLaunchTimeGiven: Bool

    enum CodingKeys: String, CodingKey {
        case primaryLaunchDate = "PrimaryLaunchDate"
        case primaryLaunchWindow = "PrimaryLaunchWindow"
        case tZeroLaunchDate = "TZeroLaunchDate"
        case tZeroPaused = "TZeroPaused"
        case isPrimaryLaunchTimeGiven = "IsPrimaryLaunchTimeGiven"
    }

    var launchDate: Date? {
        if tZeroPaused != true, let tZeroLaunchDate {
            return tZeroLaunchDate.date
        }
        return primaryLaunchWindow?.open.date ?? primaryLaunchDate?.date
    }

    var windowCloseDate: Date? {
        primaryLaunchWindow?.close.date
    }
}

private struct SpaceXLaunchWindow: Decodable {
    var open: SpaceXTimestamp
    var close: SpaceXTimestamp

    enum CodingKeys: String, CodingKey {
        case open = "Open"
        case close = "Close"
    }
}

private struct SpaceXTimestamp: Decodable {
    var seconds: TimeInterval

    enum CodingKeys: String, CodingKey {
        case seconds = "Seconds"
    }

    var date: Date {
        Date(timeIntervalSince1970: seconds)
    }
}
