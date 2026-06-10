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
    @Published private(set) var appDataCacheCreatedAt: Date?
    @Published private(set) var xAPICacheGeneratedAt: Date?
    @Published private(set) var cardCheckHits: Int = 0
    @Published private(set) var cardCheckMisses: Int = 0
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
    @Published var prefersMP4Playback: Bool {
        didSet {
            defaults.set(prefersMP4Playback, forKey: Keys.prefersMP4Playback)
            defaults.removeObject(forKey: Keys.dailyCache)
        }
    }

    private let discovery: BroadcastDiscovery
    private let defaults: UserDefaults
    private let tokenStore: KeychainTokenStore
    private let calendar: Calendar
    private let pageSize = 10
    private let maximumRequestedLimit = 20
    private let cacheVersion = 25
    private let cardCacheVersion = 2
    private let xAPICacheURL = URL(string: "https://www.sighmon.com/spacex-tv/x-cache.json")!
    private var cachedBroadcasts: [Broadcast] = []
    private var requestedLimit = 0
    private var cardResolutionCache = CardResolutionCache()

    var hasXAPIBearerToken: Bool {
        !xAPIBearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canLoadMore: Bool {
        usesXAPIBearerToken
            && hasXAPIBearerToken
            && requestedLimit < maximumRequestedLimit
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
        self.prefersMP4Playback = defaults.object(forKey: Keys.prefersMP4Playback) as? Bool ?? false

        if let data = defaults.data(forKey: Keys.cardResolutionCache),
           let decoded = try? JSONDecoder().decode(CardResolutionCache.self, from: data),
           decoded.version == cardCacheVersion {
            cardResolutionCache = decoded
        }
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
        self.appDataCacheCreatedAt = Date(timeIntervalSince1970: 1_780_000_000)
        self.xAPICacheGeneratedAt = Date(timeIntervalSince1970: 1_779_996_400)
        self.cardCheckHits = 0
        self.cardCheckMisses = 0
        self.xAPIBearerToken = "preview-token"
        self.usesXAPIBearerToken = false
        self.showsPlayerDebugOverlay = false
        self.showsNextLaunchCountdown = true
        self.prefersMP4Playback = false
        self.cardResolutionCache = CardResolutionCache()
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
        appDataCacheCreatedAt = nil
        xAPICacheGeneratedAt = nil
        cardCheckHits = 0
        cardCheckMisses = 0
        do {
            let result = try await discoverRecentSpaceXBroadcasts(limit: pageSize)
            let cacheCreatedAt = Date()
            cachedBroadcasts = result.broadcasts
            broadcasts = result.broadcasts
            requestedLimit = pageSize
            debugLines = result.report.lines
            appDataCacheCreatedAt = cacheCreatedAt
            xAPICacheGeneratedAt = result.report.xAPICacheGeneratedAt
            cardCheckHits = result.report.cardCheckHits
            cardCheckMisses = result.report.cardCheckMisses
            saveDailyCache(
                broadcasts: result.broadcasts,
                debugLines: result.report.lines,
                requestedLimit: pageSize,
                createdAt: cacheCreatedAt,
                xAPICacheGeneratedAt: result.report.xAPICacheGeneratedAt,
                cardCheckHits: result.report.cardCheckHits,
                cardCheckMisses: result.report.cardCheckMisses
            )
            saveCardResolutionCache()
            loadingState = .loaded
        } catch {
            cachedBroadcasts = []
            broadcasts = []
            requestedLimit = 0
            appDataCacheCreatedAt = nil
            xAPICacheGeneratedAt = nil
            cardCheckHits = 0
            cardCheckMisses = 0
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
            let cacheCreatedAt = Date()
            cachedBroadcasts = result.broadcasts
            broadcasts = result.broadcasts
            requestedLimit = targetLimit
            debugLines = result.report.lines
            appDataCacheCreatedAt = cacheCreatedAt
            xAPICacheGeneratedAt = result.report.xAPICacheGeneratedAt
            cardCheckHits = result.report.cardCheckHits
            cardCheckMisses = result.report.cardCheckMisses
            saveDailyCache(
                broadcasts: result.broadcasts,
                debugLines: result.report.lines,
                requestedLimit: targetLimit,
                createdAt: cacheCreatedAt,
                xAPICacheGeneratedAt: result.report.xAPICacheGeneratedAt,
                cardCheckHits: result.report.cardCheckHits,
                cardCheckMisses: result.report.cardCheckMisses
            )
            saveCardResolutionCache()
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
        // Copy the cache value so we can pass it inout across the async boundary without
        // violating actor isolation on the stored property. Write it back after the call
        // returns (the callee mutates the local copy during probing).
        var cache = cardResolutionCache
        let result: BroadcastDiscoveryResult
        if usesXAPIBearerToken, !token.isEmpty {
            result = try await discovery.discoverRecentSpaceXBroadcasts(
                limit: limit,
                xAPIBearerToken: token,
                prefersMP4Playback: prefersMP4Playback,
                cardCache: &cache
            )
        } else {
            result = try await discovery.discoverRecentSpaceXBroadcasts(
                limit: limit,
                xAPICacheURL: xAPICacheURL,
                prefersMP4Playback: prefersMP4Playback,
                cardCache: &cache
            )
        }
        cardResolutionCache = cache
        return result
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
        appDataCacheCreatedAt = cache.createdAt
        xAPICacheGeneratedAt = cache.xAPICacheGeneratedAt
        cardCheckHits = cache.cardCheckHits
        cardCheckMisses = cache.cardCheckMisses
        loadingState = .loaded
        return true
    }

    private func saveDailyCache(
        broadcasts: [Broadcast],
        debugLines: [String],
        requestedLimit: Int,
        createdAt: Date,
        xAPICacheGeneratedAt: Date?,
        cardCheckHits: Int,
        cardCheckMisses: Int
    ) {
        let cache = DailyBroadcastCache(
            version: cacheVersion,
            createdAt: createdAt,
            requestedLimit: requestedLimit,
            xAPICacheGeneratedAt: xAPICacheGeneratedAt,
            cardCheckHits: cardCheckHits,
            cardCheckMisses: cardCheckMisses,
            broadcasts: broadcasts,
            debugLines: debugLines
        )

        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: Keys.dailyCache)
        }
    }

    private func saveCardResolutionCache() {
        var cache = cardResolutionCache
        cache.version = cardCacheVersion
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: Keys.cardResolutionCache)
        }
    }

    func clearCaches() {
        // Clear the per-card resolution cache (the one that lets us skip re-checks for unchanged posts)
        cardResolutionCache = CardResolutionCache()
        defaults.removeObject(forKey: Keys.cardResolutionCache)

        // Clear the daily full result cache
        defaults.removeObject(forKey: Keys.dailyCache)

        // Reset published snapshot state so UI (footer, etc.) reflects cleared state
        appDataCacheCreatedAt = nil
        xAPICacheGeneratedAt = nil
        cardCheckHits = 0
        cardCheckMisses = 0
    }

    private func showMissingTokenState() {
        cachedBroadcasts = []
        broadcasts = []
        requestedLimit = 0
        isLoadingMore = false
        appDataCacheCreatedAt = nil
        xAPICacheGeneratedAt = nil
        debugLines = ["No X API Bearer Token configured"]
        loadingState = .failed(BroadcastDiscoveryError.missingBearerToken.errorDescription ?? "Add an X API Bearer Token in Settings.")
    }
}

private enum Keys {
    static let xAPIBearerToken = "xAPIBearerToken"
    static let usesXAPIBearerToken = "usesXAPIBearerToken"
    static let showsPlayerDebugOverlay = "showsPlayerDebugOverlay"
    static let showsNextLaunchCountdown = "showsNextLaunchCountdown"
    static let prefersMP4Playback = "prefersMP4Playback"
    static let dailyCache = "dailyBroadcastCache"
    static let cardResolutionCache = "cardResolutionCache"
}

private struct DailyBroadcastCache: Codable {
    var version: Int?
    var createdAt: Date
    var requestedLimit: Int?
    var xAPICacheGeneratedAt: Date?
    var cardCheckHits: Int = 0
    var cardCheckMisses: Int = 0
    var broadcasts: [Broadcast]
    var debugLines: [String]
}
