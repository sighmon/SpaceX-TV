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
        }
    }
    @Published var showsPlayerDebugOverlay: Bool {
        didSet {
            defaults.set(showsPlayerDebugOverlay, forKey: Keys.showsPlayerDebugOverlay)
        }
    }

    private let discovery: BroadcastDiscovery
    private let defaults: UserDefaults
    private let tokenStore: KeychainTokenStore
    private let calendar: Calendar
    private let pageSize = 10
    private let maximumBroadcastLimit = 20
    private let cacheVersion = 9
    private var cachedBroadcasts: [Broadcast] = []

    var hasXAPIBearerToken: Bool {
        !xAPIBearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        self.showsPlayerDebugOverlay = defaults.bool(forKey: Keys.showsPlayerDebugOverlay)
    }

    func load() async {
        guard hasXAPIBearerToken else {
            showMissingTokenState()
            return
        }

        if restoreDailyCache(minimumLimit: pageSize) {
            return
        }
        await refresh()
    }

    func refresh() async {
        guard hasXAPIBearerToken else {
            showMissingTokenState()
            return
        }

        loadingState = .loading
        isLoadingMore = false
        debugLines = ["Starting refresh"]
        do {
            let token = xAPIBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await discovery.discoverRecentSpaceXBroadcasts(
                limit: pageSize,
                xAPIBearerToken: token.isEmpty ? nil : token
            )
            cachedBroadcasts = result.broadcasts
            broadcasts = Array(result.broadcasts.prefix(pageSize))
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
            if let failure = error as? BroadcastDiscoveryFailure {
                debugLines = failure.report.lines
            }
            loadingState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func loadMoreIfNeeded(currentBroadcast: Broadcast) async {
        guard broadcasts.last?.id == currentBroadcast.id else { return }
        await loadMore()
    }

    func loadMore() async {
        guard hasXAPIBearerToken else {
            showMissingTokenState()
            return
        }
        guard !isLoadingMore else { return }
        guard broadcasts.count < maximumBroadcastLimit else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        let targetLimit = min(broadcasts.count + pageSize, maximumBroadcastLimit)
        if cachedBroadcasts.count >= targetLimit {
            broadcasts = Array(cachedBroadcasts.prefix(targetLimit))
            return
        }

        do {
            let token = xAPIBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await discovery.discoverRecentSpaceXBroadcasts(
                limit: targetLimit,
                xAPIBearerToken: token.isEmpty ? nil : token
            )
            cachedBroadcasts = result.broadcasts
            broadcasts = Array(result.broadcasts.prefix(targetLimit))
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

    private func restoreDailyCache(minimumLimit: Int) -> Bool {
        guard let data = defaults.data(forKey: Keys.dailyCache),
              let cache = try? JSONDecoder().decode(DailyBroadcastCache.self, from: data),
              cache.version == cacheVersion,
              (cache.requestedLimit ?? 0) >= minimumLimit,
              calendar.isDate(cache.createdAt, inSameDayAs: Date()) else {
            return false
        }

        cachedBroadcasts = cache.broadcasts
        broadcasts = Array(cache.broadcasts.prefix(pageSize))
        debugLines = ["Loaded \(cache.broadcasts.count) broadcasts from today's cache"] + cache.debugLines
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
        isLoadingMore = false
        debugLines = ["No X API Bearer Token configured"]
        loadingState = .failed(BroadcastDiscoveryError.missingBearerToken.errorDescription ?? "Add an X API Bearer Token in Settings.")
    }
}

private enum Keys {
    static let xAPIBearerToken = "xAPIBearerToken"
    static let showsPlayerDebugOverlay = "showsPlayerDebugOverlay"
    static let dailyCache = "dailyBroadcastCache"
}

private struct DailyBroadcastCache: Codable {
    var version: Int?
    var createdAt: Date
    var requestedLimit: Int?
    var broadcasts: [Broadcast]
    var debugLines: [String]
}
