import Combine
import Foundation

@MainActor
final class BroadcastLibrary: ObservableObject {
    enum LoadingState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var broadcasts: [Broadcast]
    @Published private(set) var loadingState: LoadingState = .idle
    @Published private(set) var debugLines: [String] = []
    @Published var xAPIBearerToken: String {
        didSet {
            defaults.set(xAPIBearerToken, forKey: Keys.xAPIBearerToken)
        }
    }
    @Published var showsPlayerDebugOverlay: Bool {
        didSet {
            defaults.set(showsPlayerDebugOverlay, forKey: Keys.showsPlayerDebugOverlay)
        }
    }

    private let discovery: BroadcastDiscovery
    private let defaults: UserDefaults
    private let calendar: Calendar

    init(
        discovery: BroadcastDiscovery = BroadcastDiscovery(),
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current
    ) {
        self.discovery = discovery
        self.defaults = defaults
        self.calendar = calendar
        self.broadcasts = []
        self.xAPIBearerToken = defaults.string(forKey: Keys.xAPIBearerToken) ?? ""
        self.showsPlayerDebugOverlay = defaults.bool(forKey: Keys.showsPlayerDebugOverlay)
    }

    func load() async {
        if restoreDailyCache() {
            return
        }
        await refresh()
    }

    func refresh() async {
        loadingState = .loading
        debugLines = ["Starting refresh"]
        do {
            let token = xAPIBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await discovery.discoverRecentSpaceXBroadcasts(
                limit: 10,
                xAPIBearerToken: token.isEmpty ? nil : token
            )
            broadcasts = result.broadcasts
            debugLines = result.report.lines
            saveDailyCache(broadcasts: result.broadcasts, debugLines: result.report.lines)
            loadingState = .loaded
        } catch {
            broadcasts = []
            if let failure = error as? BroadcastDiscoveryFailure {
                debugLines = failure.report.lines
            }
            loadingState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func restoreDailyCache() -> Bool {
        guard let data = defaults.data(forKey: Keys.dailyCache),
              let cache = try? JSONDecoder().decode(DailyBroadcastCache.self, from: data),
              calendar.isDate(cache.createdAt, inSameDayAs: Date()) else {
            return false
        }

        broadcasts = cache.broadcasts
        debugLines = ["Loaded \(cache.broadcasts.count) broadcasts from today's cache"] + cache.debugLines
        loadingState = .loaded
        return true
    }

    private func saveDailyCache(broadcasts: [Broadcast], debugLines: [String]) {
        let cache = DailyBroadcastCache(
            createdAt: Date(),
            broadcasts: broadcasts,
            debugLines: debugLines
        )

        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: Keys.dailyCache)
        }
    }
}

private enum Keys {
    static let xAPIBearerToken = "xAPIBearerToken"
    static let showsPlayerDebugOverlay = "showsPlayerDebugOverlay"
    static let dailyCache = "dailyBroadcastCache"
}

private struct DailyBroadcastCache: Codable {
    var createdAt: Date
    var broadcasts: [Broadcast]
    var debugLines: [String]
}
