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
    @Published private(set) var isLoadingMore = false
    @Published private(set) var debugLines: [String] = []
    @Published var xAPIBearerToken: String {
        didSet {
            tokenStore.save(xAPIBearerToken)
            defaults.removeObject(forKey: Keys.dailyCache)
        }
    }
    @Published var usesXAPIBearerToken: Bool {
        didSet {
            defaults.set(usesXAPIBearerToken, forKey: Keys.usesXAPIBearerToken)
            defaults.removeObject(forKey: Keys.dailyCache)
        }
    }
    @Published var showsPlayerDebugOverlay: Bool {
        didSet {
            defaults.set(showsPlayerDebugOverlay, forKey: Keys.showsPlayerDebugOverlay)
        }
    }
    @Published var showsNextLaunchCountdown: Bool {
        didSet {
            defaults.set(showsNextLaunchCountdown, forKey: Keys.showsNextLaunchCountdown)
        }
    }

    private let discovery: BroadcastDiscovery
    private let defaults: UserDefaults
    private let tokenStore: KeychainTokenStore
    private let calendar: Calendar
    private let pageSize = 10
    private let maximumRequestedLimit = 20
    private let cacheVersion = 16
    private let xAPICacheURL = URL(string: "https://www.sighmon.com/spacex-tv/x-cache.json")!
    private var cachedBroadcasts: [Broadcast] = []
    private var requestedLimit = 0

    var hasXAPIBearerToken: Bool {
        !xAPIBearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canLoadMore: Bool {
        requestedLimit < maximumRequestedLimit
    }

    init(
        discovery: BroadcastDiscovery = BroadcastDiscovery(),
        defaults: UserDefaults = .standard,
        tokenStore: KeychainTokenStore = KeychainTokenStore(),
        calendar: Calendar = .current
    ) {
        self.discovery = discovery
        self.defaults = defaults
        self.tokenStore = tokenStore
        self.calendar = calendar
        self.broadcasts = []
        let keychainToken = tokenStore.token()
        if keychainToken.isEmpty, let legacyToken = defaults.string(forKey: Keys.xAPIBearerToken), !legacyToken.isEmpty {
            self.xAPIBearerToken = legacyToken
            tokenStore.save(legacyToken)
        } else {
            self.xAPIBearerToken = keychainToken
        }
        defaults.removeObject(forKey: Keys.xAPIBearerToken)
        self.usesXAPIBearerToken = defaults.bool(forKey: Keys.usesXAPIBearerToken)
        self.showsPlayerDebugOverlay = defaults.bool(forKey: Keys.showsPlayerDebugOverlay)
        self.showsNextLaunchCountdown = defaults.object(forKey: Keys.showsNextLaunchCountdown) as? Bool ?? true
    }

#if DEBUG
    init(
        previewBroadcasts: [Broadcast],
        debugLines: [String] = ["Loaded preview broadcasts"]
    ) {
        self.discovery = BroadcastDiscovery()
        self.defaults = .standard
        self.tokenStore = KeychainTokenStore()
        self.calendar = .current
        self.broadcasts = previewBroadcasts
        self.cachedBroadcasts = previewBroadcasts
        self.requestedLimit = previewBroadcasts.count
        self.debugLines = debugLines
        self.xAPIBearerToken = "preview-token"
        self.usesXAPIBearerToken = false
        self.showsPlayerDebugOverlay = false
        self.showsNextLaunchCountdown = true
        self.loadingState = .loaded
    }
#endif

    func load() async {
        if restoreDailyCache(minimumLimit: pageSize) {
            return
        }
        await refresh()
    }

    func refresh() async {
        loadingState = .loading
        isLoadingMore = false
        debugLines = ["Starting refresh"]
        do {
            let result = try await discoverRecentSpaceXBroadcasts(limit: pageSize)
            cachedBroadcasts = result.broadcasts
            broadcasts = result.broadcasts
            requestedLimit = pageSize
            debugLines = result.report.lines
            saveDailyCache(
                broadcasts: result.broadcasts,
                debugLines: result.report.lines,
                requestedLimit: pageSize
            )
            loadingState = .loaded
        } catch {
            cachedBroadcasts = []
            broadcasts = []
            requestedLimit = 0
            if let failure = error as? BroadcastDiscoveryFailure {
                debugLines = failure.report.lines
            }
            loadingState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func loadMore() async {
        guard !isLoadingMore else { return }
        guard canLoadMore else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        let targetLimit = min(requestedLimit + pageSize, maximumRequestedLimit)
        if requestedLimit >= targetLimit {
            broadcasts = cachedBroadcasts
            return
        }

        do {
            let result = try await discoverRecentSpaceXBroadcasts(limit: targetLimit)
            cachedBroadcasts = result.broadcasts
            broadcasts = result.broadcasts
            requestedLimit = targetLimit
            debugLines = result.report.lines
            saveDailyCache(
                broadcasts: result.broadcasts,
                debugLines: result.report.lines,
                requestedLimit: targetLimit
            )
        } catch {
            if let failure = error as? BroadcastDiscoveryFailure {
                debugLines = failure.report.lines
            } else {
                debugLines.append("Load more failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
        }
    }

    private func discoverRecentSpaceXBroadcasts(limit: Int) async throws -> BroadcastDiscoveryResult {
        let token = xAPIBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if usesXAPIBearerToken, !token.isEmpty {
            return try await discovery.discoverRecentSpaceXBroadcasts(
                limit: limit,
                xAPIBearerToken: token
            )
        }

        return try await discovery.discoverRecentSpaceXBroadcasts(
            limit: limit,
            xAPICacheURL: xAPICacheURL
        )
    }

    private func restoreDailyCache(minimumLimit: Int) -> Bool {
        guard let data = defaults.data(forKey: Keys.dailyCache),
              let cache = try? JSONDecoder().decode(DailyBroadcastCache.self, from: data),
              cache.version == cacheVersion,
              (cache.requestedLimit ?? 0) >= minimumLimit,
              calendar.isDate(cache.createdAt, inSameDayAs: Date()) else {
            return false
        }

        cachedBroadcasts = cache.broadcasts
        broadcasts = cache.broadcasts
        requestedLimit = cache.requestedLimit ?? minimumLimit
        debugLines = ["Loaded \(broadcasts.count) broadcasts from today's cache"] + cache.debugLines
        loadingState = .loaded
        return true
    }

    private func saveDailyCache(broadcasts: [Broadcast], debugLines: [String], requestedLimit: Int) {
        let cache = DailyBroadcastCache(
            version: cacheVersion,
            createdAt: Date(),
            requestedLimit: requestedLimit,
            broadcasts: broadcasts,
            debugLines: debugLines
        )

        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: Keys.dailyCache)
        }
    }

    private func showMissingTokenState() {
        cachedBroadcasts = []
        broadcasts = []
        requestedLimit = 0
        isLoadingMore = false
        debugLines = ["No X API Bearer Token configured"]
        loadingState = .failed(BroadcastDiscoveryError.missingBearerToken.errorDescription ?? "Add an X API Bearer Token in Settings.")
    }
}

private enum Keys {
    static let xAPIBearerToken = "xAPIBearerToken"
    static let usesXAPIBearerToken = "usesXAPIBearerToken"
    static let showsPlayerDebugOverlay = "showsPlayerDebugOverlay"
    static let showsNextLaunchCountdown = "showsNextLaunchCountdown"
    static let dailyCache = "dailyBroadcastCache"
}

private struct DailyBroadcastCache: Codable {
    var version: Int?
    var createdAt: Date
    var requestedLimit: Int?
    var broadcasts: [Broadcast]
    var debugLines: [String]
}
