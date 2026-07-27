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
    @Published private(set) var totalViewingTime: TimeInterval
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
    @Published var showsCardFilters: Bool {
        didSet {
            defaults.set(showsCardFilters, forKey: Keys.showsCardFilters)
        }
    }
    @Published var showsSpaceXLogos: Bool {
        didSet {
            defaults.set(showsSpaceXLogos, forKey: Keys.showsSpaceXLogos)
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
    private let cacheVersion = 28
    private let cardCacheVersion = 4
    /// When the next launch is this close and no LIVE card is present, auto-refresh in the background.
    static let nearLaunchRefreshWindow: TimeInterval = 5 * 60
    private let xAPICacheURL = URL(string: "https://www.sighmon.com/spacex-tv/x-cache.json")!
    private var cachedBroadcasts: [Broadcast] = []
    private var requestedLimit = 0
    private var cardResolutionCache = CardResolutionCache()
    private var isRefreshingInBackground = false
    /// Bumped when a foreground discovery starts so older background results never apply.
    private var discoveryGeneration = 0

    var hasXAPIBearerToken: Bool {
        !xAPIBearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canLoadMore: Bool {
        usesXAPIBearerToken
            && hasXAPIBearerToken
            && requestedLimit < maximumRequestedLimit
    }

    var hasLiveBroadcast: Bool {
        broadcasts.contains { $0.isLive == true }
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
        self.totalViewingTime = max(0, defaults.double(forKey: Keys.totalViewingTime))
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
        self.showsCardFilters = defaults.object(forKey: Keys.showsCardFilters) as? Bool ?? true
        self.showsSpaceXLogos = defaults.object(forKey: Keys.showsSpaceXLogos) as? Bool ?? false
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
        self.totalViewingTime = 0
        self.xAPIBearerToken = "preview-token"
        self.usesXAPIBearerToken = false
        self.showsPlayerDebugOverlay = false
        self.showsNextLaunchCountdown = true
        self.showsCardFilters = true
        self.showsSpaceXLogos = false
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
        discoveryGeneration += 1
        let generation = discoveryGeneration
        loadingState = .loading
        isLoadingMore = false
        debugLines = ["Starting refresh"]
        appDataCacheCreatedAt = nil
        xAPICacheGeneratedAt = nil
        cardCheckHits = 0
        cardCheckMisses = 0
        do {
            let result = try await discoverRecentSpaceXBroadcasts(limit: pageSize)
            guard generation == discoveryGeneration else { return }
            applySuccessfulDiscovery(result, requestedLimit: pageSize)
            loadingState = .loaded
        } catch {
            guard generation == discoveryGeneration else { return }
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

    /// True when launch is in the next 5 minutes and the current list has no LIVE card.
    func needsNearLaunchRefresh(launchDate: Date, now: Date = Date()) -> Bool {
        let remaining = launchDate.timeIntervalSince(now)
        guard remaining > 0, remaining <= Self.nearLaunchRefreshWindow else {
            return false
        }
        return !hasLiveBroadcast
    }

    /// Re-fetch broadcasts without clearing the grid (used at T−5 when cache has no LIVE card).
    func refreshInBackgroundNearLaunch(launchDate: Date, now: Date = Date()) async {
        guard needsNearLaunchRefresh(launchDate: launchDate, now: now) else { return }
        guard case .loaded = loadingState else { return }
        guard !isRefreshingInBackground, !isLoadingMore else { return }

        let generation = discoveryGeneration
        let limit = max(requestedLimit, pageSize)
        isRefreshingInBackground = true
        defer { isRefreshingInBackground = false }

        let remainingSeconds = max(0, Int(launchDate.timeIntervalSince(now)))
        let reason = "Near-launch background refresh (T−\(remainingSeconds)s, no LIVE card)"
        debugLines = [reason] + debugLines
        print("[SpaceXTV] \(reason)")

        do {
            let result = try await discoverRecentSpaceXBroadcasts(limit: limit)
            // Discard if a newer discovery started (manual refresh / load more) or UI left loaded state.
            guard generation == discoveryGeneration else {
                print("[SpaceXTV] Near-launch refresh discarded (superseded by newer discovery)")
                return
            }
            guard case .loaded = loadingState, !isLoadingMore else { return }
            applySuccessfulDiscovery(result, requestedLimit: limit)
            if hasLiveBroadcast {
                debugLines = ["Near-launch refresh found a LIVE card"] + result.report.lines
            } else {
                debugLines = ["Near-launch refresh completed; still no LIVE card"] + result.report.lines
            }
        } catch {
            guard generation == discoveryGeneration else { return }
            let message: String
            if let failure = error as? BroadcastDiscoveryFailure {
                message = failure.errorDescription ?? failure.localizedDescription
                debugLines = ["Near-launch refresh failed: \(message)"] + failure.report.lines
            } else {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                debugLines = ["Near-launch refresh failed: \(message)"] + debugLines
            }
            // Keep existing broadcasts visible on failure.
        }
    }

    private func applySuccessfulDiscovery(_ result: BroadcastDiscoveryResult, requestedLimit: Int) {
        let cacheCreatedAt = Date()
        cachedBroadcasts = result.broadcasts
        broadcasts = result.broadcasts
        self.requestedLimit = requestedLimit
        debugLines = result.report.lines
        appDataCacheCreatedAt = cacheCreatedAt
        xAPICacheGeneratedAt = result.report.xAPICacheGeneratedAt
        cardCheckHits = result.report.cardCheckHits
        cardCheckMisses = result.report.cardCheckMisses
        saveDailyCache(
            broadcasts: result.broadcasts,
            debugLines: result.report.lines,
            requestedLimit: requestedLimit,
            createdAt: cacheCreatedAt,
            xAPICacheGeneratedAt: result.report.xAPICacheGeneratedAt,
            cardCheckHits: result.report.cardCheckHits,
            cardCheckMisses: result.report.cardCheckMisses
        )
        saveCardResolutionCache()
    }

    func loadMore() async {
        guard !isLoadingMore else { return }
        guard canLoadMore else { return }

        discoveryGeneration += 1
        let generation = discoveryGeneration
        isLoadingMore = true
        defer { isLoadingMore = false }

        let targetLimit = min(requestedLimit + pageSize, maximumRequestedLimit)
        if requestedLimit >= targetLimit {
            broadcasts = cachedBroadcasts
            return
        }

        do {
            let result = try await discoverRecentSpaceXBroadcasts(limit: targetLimit)
            guard generation == discoveryGeneration else { return }
            applySuccessfulDiscovery(result, requestedLimit: targetLimit)
        } catch {
            guard generation == discoveryGeneration else { return }
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

    func recordViewingTime(_ duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        totalViewingTime += duration
        defaults.set(totalViewingTime, forKey: Keys.totalViewingTime)
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
    static let showsCardFilters = "showsCardFilters"
    static let showsSpaceXLogos = "showsSpaceXLogos"
    static let prefersMP4Playback = "prefersMP4Playback"
    static let dailyCache = "dailyBroadcastCache"
    static let cardResolutionCache = "cardResolutionCache"
    static let totalViewingTime = "totalViewingTime"
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
