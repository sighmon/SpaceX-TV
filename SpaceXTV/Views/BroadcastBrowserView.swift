import SwiftUI

struct BroadcastBrowserView: View {
    @EnvironmentObject private var library: BroadcastLibrary
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var selectedBroadcast: Broadcast?
    @Binding var selectedGallery: Broadcast?
    @Binding var selectedCollection: Broadcast?
    @Binding var showsSettings: Bool
    @State private var nextLaunch: NextLaunch?
    @State private var nextLaunchError: String?
    @State private var isLoadingNextLaunch = false
    @State private var showsHomeFooter = false
    @State private var paranoidTapCount = 0
    @State private var cardFilter: CardFilter = .all
    @FocusState private var focusedHeaderControl: HeaderControl?
    @FocusState private var focusedID: Broadcast.ID?
    private let launchScheduleService = SpaceXLaunchScheduleService()
    private let loadsNextLaunch: Bool
    private let spaceXLogoAspectRatio: CGFloat = 1
#if os(tvOS)
    private let headerControlHeight: CGFloat = 76
#else
    private let headerControlHeight: CGFloat = 68
#endif

    private enum CardFilter: String, CaseIterable, Identifiable, Hashable {
        case all
        case broadcasts
        case films
        case flightTests
        case talks

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .broadcasts: return "Broadcasts"
            case .films: return "Films"
            case .flightTests: return "Flight Tests"
            case .talks: return "Talks"
            }
        }
    }

    private enum HeaderControl: Hashable {
        case cardFilter(CardFilter)
        case settings
        case refresh
    }

    init(
        selectedBroadcast: Binding<Broadcast?>,
        selectedGallery: Binding<Broadcast?>,
        selectedCollection: Binding<Broadcast?> = .constant(nil),
        showsSettings: Binding<Bool>,
        previewNextLaunch: NextLaunch? = nil
    ) {
        self._selectedBroadcast = selectedBroadcast
        self._selectedGallery = selectedGallery
        self._selectedCollection = selectedCollection
        self._showsSettings = showsSettings
        self._nextLaunch = State(initialValue: previewNextLaunch)
        self.loadsNextLaunch = previewNextLaunch == nil
    }

    private var visibleBroadcasts: [Broadcast] {
        library.broadcasts
    }

    /// When filter chips are hidden, always show every shelf.
    private var activeCardFilter: CardFilter {
        library.showsCardFilters ? cardFilter : .all
    }

    private var isFilterActive: Bool {
        library.showsCardFilters && cardFilter != .all
    }

    private var xBroadcasts: [Broadcast] {
        guard activeCardFilter == .all || activeCardFilter == .broadcasts else { return [] }
        return visibleBroadcasts.filter {
            $0.sourceKind == .xBroadcast && !$0.isStarshipFlightTest
        }
    }

    private var starshipFilms: [Broadcast] {
        guard activeCardFilter == .all || activeCardFilter == .films else { return [] }
        return visibleBroadcasts.filter {
            $0.sourceKind == .hls && $0.subtitle.hasPrefix("Starship film")
        }
    }

    private var starshipTalks: [Broadcast] {
        guard activeCardFilter == .all || activeCardFilter == .talks else { return [] }
        return visibleBroadcasts.filter {
            $0.sourceKind == .hls && $0.subtitle.hasPrefix("Starship talk")
        }
    }

    private var starshipFlightTests: [Broadcast] {
        guard activeCardFilter == .all || activeCardFilter == .flightTests else { return [] }
        return visibleBroadcasts.filter(\.isStarshipFlightTest)
    }

    private var hasMatchingCards: Bool {
        !xBroadcasts.isEmpty
            || !starshipFilms.isEmpty
            || !starshipFlightTests.isEmpty
            || !starshipTalks.isEmpty
    }

    /// Pagination only applies to the X broadcasts shelf (not films/talks/tests).
    private var showsBroadcastsLoadMore: Bool {
        library.canLoadMore
            && (activeCardFilter == .all || activeCardFilter == .broadcasts)
    }

    private var hasLoadedCards: Bool {
        guard case .loaded = library.loadingState else { return false }
        return !visibleBroadcasts.isEmpty
    }

    private var firstVisibleCardID: Broadcast.ID? {
        xBroadcasts.first?.id
            ?? starshipFilms.first?.id
            ?? starshipFlightTests.first?.id
            ?? starshipTalks.first?.id
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.20, green: 0.22, blue: 0.24), Color(red: 0.02, green: 0.03, blue: 0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            GeometryReader { proxy in
                let screenWidth = proxy.size.width
                let horizontalPadding = horizontalPadding(for: screenWidth)
                let contentWidth = max(0, screenWidth - (horizontalPadding * 2))

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(width: contentWidth)
                            .frame(width: contentWidth, alignment: .leading)
                            .frame(minHeight: headerContentHeight(for: screenWidth), alignment: .leading)
                            .padding(.bottom, headerBottomSpacing(for: screenWidth))
                            .zIndex(1)

                        countdown(width: contentWidth)
                            .padding(
                                .bottom,
                                // Match the tighter filters→cards gap when chips are shown;
                                // otherwise keep the original countdown→cards spacing.
                                library.showsCardFilters
                                    ? headerBottomSpacing(for: screenWidth)
                                    : verticalSpacing(for: screenWidth)
                            )
                            .zIndex(0)

                        if library.showsCardFilters {
                            filterBar(width: contentWidth)
                                .padding(.bottom, headerBottomSpacing(for: screenWidth))
                                .zIndex(1)
                        }

                        content(width: contentWidth)
                            .zIndex(0)
                        if hasLoadedCards || showsHomeFooter {
                            homeFooter(width: contentWidth)
                                .opacity(showsHomeFooter ? 1 : 0)
                                .padding(.top, footerTopSpacing(for: screenWidth))
                                .zIndex(0)
                        }
                    }
                        .frame(width: contentWidth, alignment: .leading)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding(for: screenWidth))
                }
                .frame(width: screenWidth)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // .navigationTitle("SpaceX Live")
        .task {
            guard case .idle = library.loadingState else { return }
            await library.load()
            await considerNearLaunchRefresh()
        }
        .task(id: library.showsNextLaunchCountdown) {
            guard library.showsNextLaunchCountdown else {
                clearNextLaunch()
                return
            }
            guard loadsNextLaunch else { return }
            await loadNextLaunch()
            await considerNearLaunchRefresh()
        }
        // Sleep until T−5 (or run immediately if already inside the window) so a long-lived
        // home screen still auto-refreshes when the countdown crosses into the window.
        .task(id: nearLaunchWatchID) {
            await watchNearLaunchWindow()
        }
        .onChange(of: library.xAPIBearerToken) { _, _ in
            Task { await library.load() }
        }
        .onChange(of: library.usesXAPIBearerToken) { _, _ in
            Task { await library.load() }
        }
        .onChange(of: library.loadingState) { _, newState in
            updateHomeFooterVisibility()
            if case .loaded = newState {
                Task { await considerNearLaunchRefresh() }
            }
        }
        .onChange(of: nextLaunch?.launchDate) { _, _ in
            Task { await considerNearLaunchRefresh() }
        }
        .onAppear {
            updateHomeFooterVisibility()
        }
    }

    /// Cancels/restarts the T−5 watch when countdown is toggled or the launch date changes.
    private var nearLaunchWatchID: String {
        guard library.showsNextLaunchCountdown, let nextLaunch else {
            return "none"
        }
        return "\(nextLaunch.launchDate.timeIntervalSince1970)"
    }

    private func header(width: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if library.showsSpaceXLogos {
                    Image("SpaceX")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.white)
                        .frame(
                            width: logoWidth(for: width),
                            height: logoHeight(for: width),
                            alignment: .leading
                        )
                }
            }

            Spacer(minLength: 32)

            HStack(spacing: 14) {
                headerButton(systemImage: "gear", control: .settings) {
                    showsSettings = true
                }

                headerButton(systemImage: "arrow.clockwise", control: .refresh) {
                    Task {
                        await library.refresh()
                        await loadNextLaunch()
                    }
                }
            }
        }
    }

    private func filterBar(width: CGFloat) -> some View {
        HStack(spacing: 14) {
            ForEach(CardFilter.allCases) { filter in
                filterChip(filter)
            }
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func filterChip(_ filter: CardFilter) -> some View {
        let isSelected = cardFilter == filter
        let isFocused = focusedHeaderControl == .cardFilter(filter)
        // Focused chips use the same solid light fill as selected ones, so text stays dark.
        let isHighlighted = isSelected || isFocused

        return Button {
            cardFilter = filter
        } label: {
            Text(filter.title)
#if os(tvOS)
                .font(.callout.weight(.semibold))
#else
                .font(.subheadline.weight(.semibold))
#endif
                .foregroundStyle(isHighlighted ? Color.black : Color.white.opacity(0.86))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    chipBackground(isSelected: isSelected, isFocused: isFocused),
                    in: Capsule()
                )
        }
        // Custom style + disabled system focus plate so chips never scale/overlap on tvOS.
        .buttonStyle(FilterChipButtonStyle())
        .focused($focusedHeaderControl, equals: .cardFilter(filter))
        .focusEffectDisabled()
#if os(tvOS)
        // onMoveCommand replaces system focus movement for every direction, so left/right/down
        // must be handled here too. Only Up is special-cased (header is top-trailing).
        .onMoveCommand { direction in
            handleFilterMoveCommand(direction, from: filter)
        }
#endif
        .animation(.easeOut(duration: 0.16), value: isSelected)
        .animation(.easeOut(duration: 0.16), value: isFocused)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func chipBackground(isSelected: Bool, isFocused: Bool) -> Color {
        if isFocused {
            return .white
        }
        if isSelected {
            // Mid gray between unselected (0.12) and focus white.
            return .white.opacity(0.42)
        }
        return .white.opacity(0.12)
    }

#if os(tvOS)
    private func handleFilterMoveCommand(_ direction: MoveCommandDirection, from filter: CardFilter) {
        switch direction {
        case .up:
            focusedHeaderControl = .settings
        case .left:
            if let previous = adjacentFilter(filter, offset: -1) {
                focusedHeaderControl = .cardFilter(previous)
            }
        case .right:
            if let next = adjacentFilter(filter, offset: 1) {
                focusedHeaderControl = .cardFilter(next)
            }
        case .down:
            // Destination only — avoid clearing header focus first (can flash another target).
            focusedID = firstVisibleCardID
        default:
            break
        }
    }

    private func adjacentFilter(_ filter: CardFilter, offset: Int) -> CardFilter? {
        let all = CardFilter.allCases
        guard let index = all.firstIndex(of: filter) else { return nil }
        let nextIndex = all.index(index, offsetBy: offset)
        guard all.indices.contains(nextIndex) else { return nil }
        return all[nextIndex]
    }
#endif

    private func headerButton(systemImage: String, control: HeaderControl, action: @escaping () -> Void) -> some View {
        let isFocused = focusedHeaderControl == control

        return Button(action: action) {
            Image(systemName: systemImage)
#if os(tvOS)
                .font(.system(size: 38, weight: .semibold))
#else
                .font(.system(size: 30, weight: .semibold))
#endif
                .frame(width: 58, height: 58)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .focused($focusedHeaderControl, equals: control)
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.16), value: isFocused)
    }

    @ViewBuilder
    private func countdown(width: CGFloat) -> some View {
        if !library.showsNextLaunchCountdown {
            EmptyView()
        } else if let nextLaunch {
            NextLaunchCountdownView(launch: nextLaunch, width: width)
        } else if isLoadingNextLaunch {
            HStack(spacing: 12) {
                ProgressView()
                Text("Loading next launch...")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.74))
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        } else if let nextLaunchError {
            Label(nextLaunchError, systemImage: "clock.badge.exclamationmark")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.74))
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func loadNextLaunch() async {
        guard library.showsNextLaunchCountdown else {
            clearNextLaunch()
            return
        }
        guard !isLoadingNextLaunch else { return }
        isLoadingNextLaunch = true
        defer { isLoadingNextLaunch = false }

        do {
            nextLaunch = try await launchScheduleService.nextLaunch()
            nextLaunchError = nil
        } catch {
            nextLaunch = nil
            nextLaunchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func considerNearLaunchRefresh() async {
        guard library.showsNextLaunchCountdown else { return }
        guard let nextLaunch else { return }
        await library.refreshInBackgroundNearLaunch(launchDate: nextLaunch.launchDate)
    }

    /// Waits until the launch enters the near-launch window, then attempts a background refresh.
    private func watchNearLaunchWindow() async {
        guard library.showsNextLaunchCountdown else { return }
        guard let launchDate = nextLaunch?.launchDate else { return }

        let windowStart = launchDate.addingTimeInterval(-BroadcastLibrary.nearLaunchRefreshWindow)
        let delay = windowStart.timeIntervalSinceNow
        if delay > 0 {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
        }

        guard !Task.isCancelled else { return }
        await considerNearLaunchRefresh()
    }

    private func clearNextLaunch() {
        nextLaunch = nil
        nextLaunchError = nil
        isLoadingNextLaunch = false
    }

    private func updateHomeFooterVisibility() {
        if hasLoadedCards {
            withAnimation(.easeInOut(duration: 1.4).delay(0.25)) {
                showsHomeFooter = true
            }
        } else {
            showsHomeFooter = false
        }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        switch library.loadingState {
        case .idle, .loading:
            ProgressView("Finding recent broadcasts...")
                .font(.title2)
                .frame(maxWidth: .infinity, minHeight: 260, alignment: .center)
        case .loaded:
            broadcastGrid(width: width)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 20) {
                Label("Broadcasts unavailable", systemImage: "exclamationmark.triangle")
                    .font(.title2.weight(.semibold))
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                DebugLogView(lines: library.debugLines)
                HStack(spacing: 16) {
                    Button {
                        Task { await library.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.title3.weight(.semibold))
                    }
                    if !library.hasXAPIBearerToken {
                        Button {
                            showsSettings = true
                        } label: {
                            Label("Add Token", systemImage: "key.fill")
                                .font(.title3.weight(.semibold))
                        }
                    }
                }
            }
            .padding(28)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func broadcastGrid(width: CGFloat) -> some View {
        let spacing = gridSpacing(for: width)
        let columnCount = gridColumnCount(for: width)
        let cardWidth = (width - (spacing * CGFloat(columnCount - 1))) / CGFloat(columnCount)

        return Grid(alignment: .leading, horizontalSpacing: spacing, verticalSpacing: spacing) {
            if !hasMatchingCards {
                GridRow {
                    filterEmptyState(width: width)
                        .gridCellColumns(columnCount)
                }
                .id("filter-empty")
            }

            if !xBroadcasts.isEmpty {
                broadcastRows(xBroadcasts, columnCount: columnCount, cardWidth: cardWidth)
            }

            if showsBroadcastsLoadMore {
                GridRow {
                    loadMoreButton(width: width)
                        .gridCellColumns(columnCount)
                }
                .id("load-more")
            }

            if !starshipFilms.isEmpty {
                GridRow {
                    sectionHeader("STARSHIP FILMS", width: width)
                        .gridCellColumns(columnCount)
                }
                .id("starship-films-header")
                broadcastRows(starshipFilms, columnCount: columnCount, cardWidth: cardWidth)
            }

            if !starshipFlightTests.isEmpty {
                GridRow {
                    sectionHeader("STARSHIP TEST FLIGHTS", width: width)
                        .gridCellColumns(columnCount)
                }
                .id("starship-flight-tests-header")
                broadcastRows(starshipFlightTests, columnCount: columnCount, cardWidth: cardWidth)
            }

            if !starshipTalks.isEmpty {
                GridRow {
                    sectionHeader("STARSHIP TALKS", width: width)
                        .gridCellColumns(columnCount)
                }
                .id("starship-talks-header")
                broadcastRows(starshipTalks, columnCount: columnCount, cardWidth: cardWidth)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func filterEmptyState(width: CGFloat) -> some View {
        let detail: String
        if isFilterActive {
            detail = "No \(cardFilter.title.lowercased()) available"
        } else {
            detail = "No broadcasts available"
        }

        return VStack(alignment: .leading, spacing: 12) {
            Label(isFilterActive ? "No matches" : "Nothing here yet", systemImage: "line.3.horizontal.decrease.circle")
                .font(.title2.weight(.semibold))
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
            if isFilterActive {
                Button("Show All") {
                    cardFilter = .all
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(28)
        .frame(width: width, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func broadcastRows(_ broadcasts: [Broadcast], columnCount: Int, cardWidth: CGFloat) -> some View {
        ForEach(Array(stride(from: 0, to: broadcasts.count, by: columnCount)), id: \.self) { startIndex in
            let endIndex = min(startIndex + columnCount, broadcasts.count)
            GridRow {
                ForEach(broadcasts[startIndex ..< endIndex]) { broadcast in
                    broadcastButton(broadcast, width: cardWidth)
                }

                if endIndex - startIndex < columnCount {
                    ForEach(0 ..< (columnCount - (endIndex - startIndex)), id: \.self) { _ in
                        Color.clear
                            .frame(width: cardWidth)
                            .gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
    }

    private func broadcastButton(_ broadcast: Broadcast, width: CGFloat) -> some View {
        Button {
            switch broadcast.contentKind {
            case .video:
                selectedBroadcast = broadcast
            case .gallery:
                selectedGallery = broadcast
            case .collection:
                selectedCollection = broadcast
            }
        } label: {
            BroadcastCard(broadcast: broadcast, isFocused: focusedID == broadcast.id)
                .frame(width: width)
                .contentShape(BroadcastCard.shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focusedID, equals: broadcast.id)
    }

    private func loadMoreButton(width: CGFloat) -> some View {
        Button {
            Task { await library.loadMore() }
        } label: {
            HStack(spacing: 14) {
                if library.isLoadingMore {
                    ProgressView()
                } else {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                }
                Text(library.isLoadingMore ? "Loading more broadcasts..." : "Load More")
                    .font(.title3.weight(.semibold))
            }
            .frame(width: width)
            .frame(minHeight: 86)
        }
        .buttonStyle(.bordered)
        .disabled(library.isLoadingMore)
    }

    private func sectionHeader(
        _ title: String,
        width: CGFloat,
        showsDivider: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white.opacity(0.72))

            if showsDivider {
                Divider()
                    .overlay(.white.opacity(0.22))
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func homeFooter(width: CGFloat) -> some View {
        VStack(spacing: 18) {
            if library.showsSpaceXLogos {
                Image("SpaceX")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: footerLogoWidth(for: width))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.leading, 50)
                    .opacity(0.58)
            }

            Divider()
                .overlay(.white.opacity(0.22))

            Button {
                paranoidTapCount += 1
                if paranoidTapCount >= 10 {
                    library.showsSpaceXLogos.toggle()
                    paranoidTapCount = 0
                }
            } label: {
                Text("ONLY THE PARANOID SURVIVE")
                    .font(.title2.weight(.bold))
                    .tracking(2.4)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(width: width, alignment: .center)
                    .padding(.top, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(cacheFooterText)
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.46))
                .frame(width: width, alignment: .center)
                .padding(.top, 8)

            HStack(spacing: 5) {
                Text("T+")
                    .foregroundStyle(.white.opacity(0.38))

                Text(formattedViewingTime)
                    .foregroundStyle(.white.opacity(0.68))
            }
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(width: width, alignment: .center)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Time watched \(formattedViewingTime)")
        }
        .frame(width: width, alignment: .center)
    }

    private var cacheFooterText: String {
        let xAPIDate = library.xAPICacheGeneratedAt.map(cacheDateFormatter.string(from:)) ?? "Unavailable"
        let appDataDate = library.appDataCacheCreatedAt.map(cacheDateFormatter.string(from:)) ?? "Unavailable"
        return "X API cache: \(xAPIDate)\nApp cache: \(appDataDate)\nCard checks: \(library.cardCheckHits) hits, \(library.cardCheckMisses) misses"
    }

    private var cacheDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    private var formattedViewingTime: String {
        let totalSeconds = max(0, Int(library.totalViewingTime.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func horizontalPadding(for width: CGFloat) -> CGFloat {
        if horizontalSizeClass == .compact { return 24 }
        return width < 900 ? 36 : 84
    }

    private func verticalPadding(for width: CGFloat) -> CGFloat {
        width < 900 ? 28 : 54
    }

    private func verticalSpacing(for width: CGFloat) -> CGFloat {
        width < 900 ? 28 : 42
    }

    private func headerBottomSpacing(for width: CGFloat) -> CGFloat {
        verticalSpacing(for: width) * 0.5
    }

    private func headerContentHeight(for width: CGFloat) -> CGFloat {
        max(headerControlHeight, library.showsSpaceXLogos ? logoHeight(for: width) : 0)
    }

    private func footerTopSpacing(for width: CGFloat) -> CGFloat {
        width < 900 ? 42 : 64
    }

    private func gridSpacing(for width: CGFloat) -> CGFloat {
        width < 900 ? 32 : 56
    }

    private func gridColumnCount(for width: CGFloat) -> Int {
        horizontalSizeClass == .regular && width >= 620 ? 2 : 1
    }

    private func logoWidth(for width: CGFloat) -> CGFloat {
        width < 700 ? 112 : 140
    }

    private func logoHeight(for width: CGFloat) -> CGFloat {
        logoWidth(for: width) / spaceXLogoAspectRatio
    }

    private func footerLogoWidth(for width: CGFloat) -> CGFloat {
        width < 700 ? 88 : 108
    }
}

private struct NextLaunchCountdownView: View {
    var launch: NextLaunch
    var width: CGFloat

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = CountdownRemaining(from: context.date, to: launch.launchDate)

            Group {
                if width < 760 {
                    VStack(alignment: .leading, spacing: 18) {
                        launchSummary
                        countdownUnits(for: remaining)
                    }
                } else {
                    HStack(alignment: .bottom, spacing: 28) {
                        launchSummary
                        countdownUnits(for: remaining)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var launchSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("NEXT LAUNCH")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.58))

            Text(launch.title)
                .font((width < 760 ? Font.title3 : Font.title2).weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)

            launchMetadata
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func countdownUnits(for remaining: CountdownRemaining) -> some View {
        HStack(spacing: 0) {
            CountdownUnit(value: remaining.days, label: "DAYS", font: countdownFont, width: countdownUnitWidth)
            CountdownSeparator(font: countdownFont)
            CountdownUnit(value: remaining.hours, label: "HRS", font: countdownFont, width: countdownUnitWidth)
            CountdownSeparator(font: countdownFont)
            CountdownUnit(value: remaining.minutes, label: "MIN", font: countdownFont, width: countdownUnitWidth)
            CountdownSeparator(font: countdownFont)
            CountdownUnit(value: remaining.seconds, label: "SEC", font: countdownFont, width: countdownUnitWidth)
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .padding(.trailing, width < 760 ? 0 : -countdownTrailingCorrection)
        .frame(maxWidth: width < 760 ? .infinity : nil, alignment: width < 760 ? .leading : .trailing)
        .accessibilityLabel(remaining.accessibilityText)
    }

    private var countdownFont: Font {
        (width < 760 ? Font.title3 : Font.title2).weight(.semibold).monospacedDigit()
    }

    private var countdownUnitWidth: CGFloat {
#if os(tvOS)
        width < 760 ? 70 : 82
#else
        width < 420 ? 44 : 54
#endif
    }

    private var countdownTrailingCorrection: CGFloat {
#if os(tvOS)
        0
#else
        12
#endif
    }

    private var launchMetadata: some View {
        HStack(spacing: 10) {
            if let vehicle = launch.vehicle, !vehicle.isEmpty {
                Text(vehicle)
            }
            if let launchSite = launch.launchSite, !launchSite.isEmpty {
                Text(launchSite)
            }
            Text(dateFormatter.string(from: launch.launchDate))
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white.opacity(0.66))
        .lineLimit(2)
    }
}

private struct CountdownUnit: View {
    var value: Int
    var label: String
    var font: Font
    var width: CGFloat

    var body: some View {
        VStack(spacing: 5) {
            Text(String(format: "%02d", value))
                .font(font)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: true, vertical: false)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.24), value: value)
                .frame(width: width, alignment: .center)

            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.54))
        }
        .frame(width: width)
    }
}

private struct CountdownSeparator: View {
    var font: Font

    var body: some View {
        VStack(spacing: 5) {
            Text(":")
                .font(font)
                .foregroundStyle(.white.opacity(0.46))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Text(" ")
                .font(.caption2.weight(.bold))
                .hidden()
        }
        .accessibilityHidden(true)
    }
}

private struct CountdownRemaining {
    var days: Int
    var hours: Int
    var minutes: Int
    var seconds: Int
    var isElapsed: Bool

    init(from now: Date, to launchDate: Date) {
        let totalSeconds = max(0, Int(launchDate.timeIntervalSince(now)))
        days = totalSeconds / 86_400
        hours = (totalSeconds % 86_400) / 3_600
        minutes = (totalSeconds % 3_600) / 60
        seconds = totalSeconds % 60
        isElapsed = launchDate <= now
    }

    var accessibilityText: String {
        if isElapsed {
            return "Launch time reached"
        }
        return "\(days) days, \(hours) hours, \(minutes) minutes, \(seconds) seconds until launch"
    }
}

private struct DebugLogView: View {
    var lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Debug")
                .font(.headline)
            ForEach(Array(lines.suffix(18).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct BroadcastCard: View {
    var broadcast: Broadcast
    var isFocused: Bool
    /// When set, overrides the usual title/tweet text in the card body.
    var titleOverride: String? = nil
    /// When set, overrides metadata (date / media summary).
    var metadataOverride: String? = nil
    /// When set, overrides the trailing action glyph.
    var actionSymbolOverride: String? = nil

    /// Continuous radius aligned with system focus lockups on tvOS; tighter on iOS.
#if os(tvOS)
    static let cornerRadius: CGFloat = 32
#else
    static let cornerRadius: CGFloat = 8
#endif

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private let aspectRatio: CGFloat = 16.0 / 9.0
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Rectangle()
            .fill(.clear)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                background
            }
            .overlay {
                LinearGradient(
                    colors: [
                        .black.opacity(0.10),
                        .black.opacity(0.56),
                        .black.opacity(0.86),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .bottomLeading) {
                cardContent
                    .padding(.leading, 24)
                    .padding(.trailing, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
            }
            .overlay(alignment: .topTrailing) {
                cardBadges
                    .padding(14)
            }
            .frame(maxWidth: .infinity)
            .clipShape(Self.shape)
            .background(.white.opacity(isFocused ? 0.20 : 0.08), in: Self.shape)
            .scaleEffect(isFocused ? 1.04 : 1)
            .animation(.easeOut(duration: 0.16), value: isFocused)
    }

    private var cardContent: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                if let titleOverride {
                    Text(titleOverride)
                        .font(primaryTextFont)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                } else if broadcast.sourceKind == .hls || broadcast.isStarshipFlightTest {
                    Text(broadcast.title)
                        .font(primaryTextFont)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                } else if let tweetText = broadcast.tweetText, !tweetText.isEmpty {
                    Text(displayText(from: tweetText))
                        .font(primaryTextFont)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                } else {
                    Text(broadcast.subtitle)
                        .font(primaryTextFont)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                metadata
            }
            .frame(maxWidth: .infinity, alignment: .bottomLeading)

            Image(systemName: actionSymbolOverride ?? cardActionSymbol)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
        }
    }

    private var cardActionSymbol: String {
        switch broadcast.contentKind {
        case .gallery:
            return "photo"
        case .collection:
            return "rectangle.stack"
        case .video:
            return "play.fill"
        }
    }

    private var primaryTextFont: Font {
        .callout.weight(.semibold)
    }

    @ViewBuilder
    private var cardBadges: some View {
        HStack(spacing: 8) {
            if broadcast.isLive == true {
                Text("LIVE")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.red, in: Capsule())
            } else if broadcast.isUpcoming {
                Text("UPCOMING")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.gray, in: Capsule())
                    .accessibilityLabel("Upcoming")
            }

            if broadcast.sourceKind == .xBroadcast && broadcast.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.black.opacity(0.56), in: Circle())
                    .accessibilityLabel("Pinned X post")
            }
        }
    }

    @ViewBuilder
    private var metadata: some View {
        if let metadataOverride {
            Text(metadataOverride)
                .lineLimit(1)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.gray.opacity(0.6))
        } else if let publishedAt = broadcast.publishedAt {
            HStack(spacing: 10) {
                Text(dateFormatter.string(from: publishedAt))
                if let summary = broadcast.mediaSummaryLabel {
                    Text(summary)
                }
            }
            .lineLimit(1)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.gray.opacity(0.6))
        } else if let summary = broadcast.mediaSummaryLabel {
            Text(summary)
                .lineLimit(1)
                .font(.caption2.weight(.medium))
            .foregroundStyle(.gray.opacity(0.6))
        }
    }

    @ViewBuilder
    private var background: some View {
        if let thumbnailURL = broadcast.thumbnailURL {
            RemoteThumbnailImage(url: thumbnailURL, fallback: fallbackBackground)
        } else {
            fallbackBackground
        }
    }

    private var fallbackBackground: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.12, blue: 0.14), Color(red: 0.02, green: 0.03, blue: 0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image("SpaceX")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 180, height: 96)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func displayText(from text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.hasPrefix("http://") && !$0.hasPrefix("https://") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct RemoteThumbnailImage<Fallback: View>: View {
    var url: URL
    var fallback: Fallback
    @StateObject private var loader = ThumbnailImageLoader()

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fallback
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: url) {
            await loader.load(url)
        }
    }
}

@MainActor
private final class ThumbnailImageLoader: ObservableObject {
    @Published var image: UIImage?
    private var loadedURL: URL?

    func load(_ url: URL) async {
        guard loadedURL != url || image == nil else { return }
        image = nil

        let urls = candidateURLs(for: url)
        for candidateURL in urls {
            if await loadImage(candidateURL) {
                loadedURL = url
                return
            }

            guard !Task.isCancelled else {
                return
            }
        }
    }

    private func loadImage(_ url: URL) async -> Bool {
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 AppleTV SpaceXTV/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200 ..< 300).contains(statusCode) else {
                print("[SpaceXTV] Thumbnail HTTP \(statusCode): \(url.absoluteString)")
                return false
            }
            guard let decodedImage = UIImage(data: data) else {
                print("[SpaceXTV] Thumbnail decode failed, \(data.count) bytes: \(url.absoluteString)")
                return false
            }
            image = decodedImage
            print("[SpaceXTV] Thumbnail loaded: \(url.absoluteString)")
            return true
        } catch {
            print("[SpaceXTV] Thumbnail load failed: \(error.localizedDescription) \(url.absoluteString)")
            return false
        }
    }

    private func candidateURLs(for url: URL) -> [URL] {
        var urls: [URL] = []
        func append(_ nextURL: URL?) {
            guard let nextURL, !urls.contains(nextURL) else { return }
            urls.append(nextURL)
        }

        append(url)
        guard url.host?.lowercased().hasSuffix("twimg.com") == true,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return urls
        }

        let originalName = components.queryItems?.first { $0.name == "name" }?.value
        let originalFormat = components.queryItems?.first { $0.name == "format" }?.value
        let names = [originalName, "4096x4096", "orig", "large", "medium", "small"]
            .compactMap { $0 }
        let formats = [originalFormat, "jpg", "png", "webp"]
            .compactMap { $0 }

        for name in names {
            append(thumbnailURL(updating: components, name: name, format: nil))
            for format in formats {
                append(thumbnailURL(updating: components, name: name, format: format))
            }
        }

        var noQueryComponents = components
        noQueryComponents.queryItems = nil
        append(noQueryComponents.url)

        return urls
    }

    private func thumbnailURL(updating components: URLComponents, name: String, format: String?) -> URL? {
        var nextComponents = components
        var queryItems = nextComponents.queryItems ?? []
        if let index = queryItems.firstIndex(where: { $0.name == "name" }) {
            queryItems[index].value = name
        } else {
            queryItems.append(URLQueryItem(name: "name", value: name))
        }

        if let format {
            if let index = queryItems.firstIndex(where: { $0.name == "format" }) {
                queryItems[index].value = format
            } else {
                queryItems.append(URLQueryItem(name: "format", value: format))
            }
        }

        nextComponents.queryItems = queryItems
        return nextComponents.url
    }
}

/// Draws the label only — no system chrome or hover/focus scale that can overlap neighbors on tvOS.
private struct FilterChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

extension Broadcast {
    var isStarshipFlightTest: Bool {
        subtitle.hasPrefix("Starship flight test")
    }
}

#if DEBUG
private extension Broadcast {
    static let previewBroadcasts: [Broadcast] = [
        Broadcast(
            id: UUID(uuidString: "3B246719-1357-4D5E-8E6F-87D652C64F01")!,
            title: "Starship Flight Test",
            subtitle: "Live broadcast",
            sourceURL: URL(string: "https://x.com/SpaceX/status/preview-starship")!,
            sourceKind: .xBroadcast,
            tweetText: "Watch Starship's next integrated flight test live from Starbase.",
            publishedAt: Date().addingTimeInterval(-3 * 60),
            artworkName: "SpaceX",
            isPinned: true,
            isLive: true
        ),
        Broadcast(
            id: UUID(uuidString: "7A2799E0-B06F-4D9B-A450-B76093C978E0")!,
            title: "Falcon 9 Mission",
            subtitle: "Launch webcast",
            sourceURL: URL(string: "https://x.com/SpaceX/status/preview-falcon-9")!,
            sourceKind: .xBroadcast,
            tweetText: "Falcon 9 launches a rideshare mission to orbit from Cape Canaveral.",
            publishedAt: Date(timeIntervalSince1970: 1_779_264_000),
            artworkName: "SpaceX",
            isPinned: true
        ),
        Broadcast(
            id: UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!,
            title: "Starship's Thirteenth Flight Test",
            subtitle: "Livestream not started",
            sourceURL: URL(string: "https://x.com/i/broadcasts/preview-not-started")!,
            sourceKind: .xBroadcast,
            tweetText: "Watch Starship's thirteenth flight test — live coverage has not started yet.",
            publishedAt: Date().addingTimeInterval(-2 * 60 * 60),
            thumbnailURL: URL(string: "https://pbs.twimg.com/media/HNWqJ_TXcAADsAJ.jpg"),
            artworkName: "play.tv",
            isLive: false,
            isUpcoming: true
        ),
        Broadcast(
            id: UUID(uuidString: "18189ACD-8B1F-422D-AE12-9940D5266774")!,
            title: "Launch Photos",
            subtitle: "Mission gallery",
            sourceURL: URL(string: "https://x.com/SpaceX/status/preview-gallery")!,
            sourceKind: .xBroadcast,
            contentKind: .gallery,
            tweetText: "Photos from Falcon 9's liftoff and droneship landing.",
            publishedAt: Date(timeIntervalSince1970: 1_778_400_000),
            galleryImages: [
                GalleryImage(url: URL(string: "https://example.com/spacex-preview-1.jpg")!, width: 1600, height: 900),
                GalleryImage(url: URL(string: "https://example.com/spacex-preview-2.jpg")!, width: 1600, height: 900),
                GalleryImage(url: URL(string: "https://example.com/spacex-preview-3.jpg")!, width: 1600, height: 900),
            ],
            artworkName: "SpaceX"
        ),
        Broadcast(
            id: UUID(uuidString: "9C1D2E3F-4A5B-6C7D-8E9F-0A1B2C3D4E5F")!,
            title: "Multi-clip highlight",
            subtitle: "X media collection · 2 videos · 1 photo",
            sourceURL: URL(string: "https://x.com/SpaceX/status/preview-collection")!,
            sourceKind: .xBroadcast,
            contentKind: .collection,
            tweetText: "Highlights from today's static fire and pad operations.",
            publishedAt: Date(timeIntervalSince1970: 1_777_900_000),
            thumbnailURL: URL(string: "https://example.com/spacex-preview-collection.jpg"),
            galleryImages: [
                GalleryImage(url: URL(string: "https://example.com/spacex-preview-photo.jpg")!, width: 1600, height: 900),
            ],
            mediaItems: [
                PostMediaItem(
                    id: "v1",
                    kind: .video,
                    streamURL: URL(string: "https://example.com/video-1.mp4"),
                    thumbnailURL: URL(string: "https://example.com/spacex-preview-v1.jpg")
                ),
                PostMediaItem(
                    id: "p1",
                    kind: .photo,
                    thumbnailURL: URL(string: "https://example.com/spacex-preview-photo.jpg"),
                    photoURL: URL(string: "https://example.com/spacex-preview-photo.jpg"),
                    width: 1600,
                    height: 900
                ),
                PostMediaItem(
                    id: "v2",
                    kind: .video,
                    streamURL: URL(string: "https://example.com/video-2.mp4"),
                    thumbnailURL: URL(string: "https://example.com/spacex-preview-v2.jpg")
                ),
            ],
            artworkName: "SpaceX"
        ),
        Broadcast(
            id: UUID(uuidString: "83B1868E-4B52-48BA-B1C7-9102D456A4A0")!,
            title: "Dragon Departure",
            subtitle: "Live broadcast",
            sourceURL: URL(string: "https://x.com/SpaceX/status/preview-dragon")!,
            sourceKind: .xBroadcast,
            tweetText: "Dragon autonomously undocks from the space station before returning to Earth.",
            publishedAt: Date(timeIntervalSince1970: 1_777_536_000),
            artworkName: "SpaceX"
        ),
    ]
}

private extension NextLaunch {
    static let preview = NextLaunch(
        title: "Falcon 9 - Starlink",
        vehicle: "Falcon 9",
        launchSite: "SLC-40",
        launchDate: Date().addingTimeInterval(2 * 86_400 + 4 * 3_600 + 18 * 60),
        windowCloseDate: nil,
        isLaunchTimePrecise: true,
        sourceURL: URL(string: "https://www.spacex.com/launches/preview")!,
        imageURL: nil
    )
}

#Preview("Broadcast Browser") {
    @Previewable @State var selectedBroadcast: Broadcast?
    @Previewable @State var selectedGallery: Broadcast?
    @Previewable @State var selectedCollection: Broadcast?
    @Previewable @State var showsSettings = false

    BroadcastBrowserView(
        selectedBroadcast: $selectedBroadcast,
        selectedGallery: $selectedGallery,
        selectedCollection: $selectedCollection,
        showsSettings: $showsSettings,
        previewNextLaunch: .preview
    )
    .environmentObject(BroadcastLibrary(previewBroadcasts: Broadcast.previewBroadcasts))
}
#endif
