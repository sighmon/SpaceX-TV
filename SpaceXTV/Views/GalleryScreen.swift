import SwiftUI
import UIKit

struct GalleryScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var library: BroadcastLibrary
    var gallery: Broadcast
    var onDismiss: (() -> Void)?
    @StateObject private var imageStore = GalleryImageStore()
    @State private var loadError = false
    @State private var selectedImageID: GalleryImage.ID?
    @State private var viewingStartedAt: Date?
#if os(tvOS)
    @State private var isSlideshowPlaying = false
    @State private var imageDisplayMode: GalleryImageDisplayMode = .fill
    @State private var showsPlaybackIcon = false
    @State private var showsCompletionOverlay = false
    @State private var navigationTask: Task<Void, Never>?
    @State private var slideshowTask: Task<Void, Never>?
    @State private var playbackIconHideTask: Task<Void, Never>?
#else
    @State private var dismissalState = GalleryDismissalState()
    @GestureState private var dismissDrag = GalleryDismissDrag()
    private var dismissDragOffset: CGFloat { dismissDrag.offset }
#endif

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if gallery.galleryImages.isEmpty {
                ContentUnavailableView(
                    "Images unavailable",
                    systemImage: "photo.on.rectangle",
                    description: Text("This post did not include image URLs.")
                )
            } else {
                TabView(selection: $selectedImageID) {
                    ForEach(gallery.galleryImages) { image in
#if os(tvOS)
                        GalleryImagePage(image: image, store: imageStore, displayMode: imageDisplayMode)
                            .tag(image.id as GalleryImage.ID?)
#else
                        GalleryImagePage(image: image, store: imageStore, onDismissEligibilityChanged: { allowed in
                            dismissalState.allowedByImage[image.id] = allowed
                        })
                            .tag(image.id as GalleryImage.ID?)
#endif
                    }
                }
#if os(tvOS)
                .tabViewStyle(.page(indexDisplayMode: .always))
#else
                .tabViewStyle(.page(indexDisplayMode: .automatic))
#endif
                .ignoresSafeArea()
            }

#if os(tvOS)
            if showsPlaybackIcon {
                Image(systemName: isSlideshowPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 128, height: 128)
                    .background(.black.opacity(0.54), in: Circle())
                    .transition(.scale.combined(with: .opacity))
            }
#endif
        }
#if !os(tvOS)
        .offset(y: dismissDragOffset)
#endif
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
#if !os(tvOS)
        .ignoresSafeArea(.all)
#endif
#if os(tvOS)
        .animation(.easeOut(duration: 0.18), value: showsPlaybackIcon)
#endif
        .onAppear {
            selectedImageID = selectedImageID ?? gallery.galleryImages.first?.id
            startViewingIfNeeded()
        }
        .task(id: selectedImageID) {
            guard !gallery.galleryImages.isEmpty else { return }
            await imageStore.prefetch(gallery.galleryImages.map(\.url), around: selectedIndex)
        }
        .alert("Image could not be loaded", isPresented: $loadError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The current image has been kept on screen. Try again when your connection is available.")
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                startViewingIfNeeded()
            } else {
                commitViewingTime()
            }
        }
#if os(tvOS)
        .focusable(true)
        .contentShape(Rectangle())
        .onTapGesture {
            toggleSlideshow()
        }
        .onPlayPauseCommand {
            toggleSlideshow()
        }
        .onMoveCommand { direction in
            switch direction {
            case .left:
                moveSelection(by: -1)
            case .right:
                moveSelection(by: 1)
            case .up, .down:
                toggleImageDisplayMode()
            default:
                break
            }
        }
        .onDisappear {
            commitViewingTime()
            stopSlideshow()
            navigationTask?.cancel()
            imageStore.cancelAll()
            playbackIconHideTask?.cancel()
        }
        .fullScreenCover(isPresented: $showsCompletionOverlay) {
            GalleryCompleteOverlay(
                onBack: {
                    showsCompletionOverlay = false
                    close()
                },
                onReplay: {
                    showsCompletionOverlay = false
                    replaySlideshow()
                }
            )
            .preferredColorScheme(.dark)
        }
#else
        .contentShape(Rectangle())
        .statusBarHidden(true)
        .simultaneousGesture(dismissDragGesture)
        .animation(.easeOut(duration: 0.18), value: dismissDragOffset)
        .onDisappear {
            commitViewingTime()
            imageStore.cancelAll()
        }
#endif
    }

    private var selectedIndex: Int {
        guard let selectedImageID,
              let index = gallery.galleryImages.firstIndex(where: { $0.id == selectedImageID }) else {
            return 0
        }
        return index
    }

#if os(tvOS)
    private func moveSelection(by offset: Int) {
        guard gallery.galleryImages.count > 1 else { return }
        let nextIndex = (selectedIndex + offset + gallery.galleryImages.count) % gallery.galleryImages.count
        slideshowTask?.cancel()
        navigationTask?.cancel()
        navigationTask = Task { @MainActor in
            let next = gallery.galleryImages[nextIndex]
            let loaded = await imageStore.load(next.url)
            guard !Task.isCancelled else { return }
            guard loaded != nil else {
                stopSlideshow()
                loadError = true
                return
            }
            withAnimation(.easeOut(duration: 0.2)) {
                selectedImageID = next.id
            }
            if isSlideshowPlaying { startSlideshow() }
        }
    }

    private func toggleImageDisplayMode() {
        withAnimation(.easeOut(duration: 0.18)) {
            imageDisplayMode = imageDisplayMode == .fill ? .fit : .fill
        }
    }

    private func toggleSlideshow() {
        guard gallery.galleryImages.count > 1 else { return }
        navigationTask?.cancel()
        isSlideshowPlaying ? stopSlideshow() : startSlideshow()
        showPlaybackIconTemporarily()
    }

    private func startSlideshow() {
        isSlideshowPlaying = true
        slideshowTask?.cancel()
        slideshowTask = Task { @MainActor in
            while !Task.isCancelled {
                let current = gallery.galleryImages[selectedIndex]
                let loaded = await imageStore.load(current.url)
                guard !Task.isCancelled else { return }
                guard loaded != nil else {
                    stopSlideshow()
                    loadError = true
                    return
                }
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await advanceSlideshow()
            }
        }
    }

    private func stopSlideshow() {
        isSlideshowPlaying = false
        slideshowTask?.cancel()
        slideshowTask = nil
    }

    @MainActor
    private func advanceSlideshow() async {
        guard gallery.galleryImages.count > 1 else { return }
        if selectedIndex >= gallery.galleryImages.count - 1 {
            stopSlideshow()
            showsCompletionOverlay = true
            return
        }

        let currentID = selectedImageID
        let next = gallery.galleryImages[selectedIndex + 1]
        let loaded = await imageStore.load(next.url)
        guard !Task.isCancelled, selectedImageID == currentID else { return }
        guard loaded != nil else {
            stopSlideshow()
            loadError = true
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            selectedImageID = next.id
        }
    }

    private func replaySlideshow() {
        isSlideshowPlaying = true
        moveSelection(by: -selectedIndex)
    }

    private func showPlaybackIconTemporarily() {
        showsPlaybackIcon = true
        playbackIconHideTask?.cancel()
        playbackIconHideTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                showsPlaybackIcon = false
            }
        }
    }
#endif

    private var positionText: String {
        guard let selectedImageID,
              let index = gallery.galleryImages.firstIndex(where: { $0.id == selectedImageID }) else {
            return "\(gallery.galleryImages.count) photos"
        }
        return "\(index + 1) of \(gallery.galleryImages.count)"
    }

#if !os(tvOS)
    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .global)
            .updating($dismissDrag) { value, state, _ in
                // Decide once per drag: reaching the top must not turn a pan
                // already in progress into an accidental dismissal.
                if state.allowed == nil {
                    state.allowed = canDismissSelectedImage
                }
                if !canDismissSelectedImage {
                    state.allowed = false
                    state.offset = 0
                }
                dismissalState.dragAllowed = state.allowed == true
                guard state.allowed == true, isDismissDrag(value.translation) else { return }
                state.offset = min(value.translation.height, 160)
            }
            .onEnded { value in
                defer { dismissalState.dragAllowed = false }
                guard dismissalState.dragAllowed, canDismissSelectedImage,
                      isDismissDrag(value.translation),
                      value.translation.height > 120 || value.predictedEndTranslation.height > 220 else {
                    return
                }
                close()
            }
    }

    private var canDismissSelectedImage: Bool {
        guard let selectedImageID else { return true }
        return dismissalState.allowedByImage[selectedImageID] ?? true
    }

    private func isDismissDrag(_ translation: CGSize) -> Bool {
        translation.height > 0 && translation.height > abs(translation.width) * 1.35
    }

#endif

    private func close() {
        commitViewingTime()
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private func startViewingIfNeeded() {
        guard scenePhase == .active, viewingStartedAt == nil else { return }
        viewingStartedAt = Date()
    }

    private func commitViewingTime() {
        guard let viewingStartedAt else { return }
        library.recordViewingTime(Date().timeIntervalSince(viewingStartedAt))
        self.viewingStartedAt = nil
    }
}

#if os(tvOS)
private struct GalleryCompleteOverlay: View {
    private enum FocusTarget {
        case back
        case replay
    }

    var onBack: () -> Void
    var onReplay: () -> Void
    @FocusState private var focusedTarget: FocusTarget?

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()

            HStack(spacing: 28) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.backward")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: 260, height: 88)
                }
                .buttonStyle(.borderedProminent)
                .focused($focusedTarget, equals: .back)

                Button(action: onReplay) {
                    Label("Replay", systemImage: "arrow.counterclockwise")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: 260, height: 88)
                }
                .buttonStyle(.bordered)
                .focused($focusedTarget, equals: .replay)
            }
            .padding(30)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        }
        .onAppear {
            focusedTarget = .back
        }
    }
}
#endif

#if os(tvOS)
private enum GalleryImageDisplayMode {
    case fill
    case fit
}
#endif

private struct GalleryImagePage: View {
    var image: GalleryImage
    @ObservedObject var store: GalleryImageStore
#if os(tvOS)
    var displayMode: GalleryImageDisplayMode

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let loaded = store.images[image.url] {
                    loadedImageView(Image(uiImage: loaded), size: proxy.size)
                } else if store.failedURLs.contains(image.url) {
                    unavailable
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    ProgressView()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityLabel(image.altText ?? "SpaceX image")
    }

    @ViewBuilder
    private func loadedImageView(_ loadedImage: Image, size: CGSize) -> some View {
        switch displayMode {
        case .fill:
            loadedImage
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .ignoresSafeArea()
        case .fit:
            loadedImage
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)
                .ignoresSafeArea()
        }
    }
#else
    var onDismissEligibilityChanged: (Bool) -> Void
    @State private var sharedImage: SharedGalleryImage?

    var body: some View {
        Group {
            if let loaded = store.images[image.url] {
                ZoomableRemoteImage(image: loaded, onDismissEligibilityChanged: onDismissEligibilityChanged)
                    .contextMenu {
                        Button {
                            sharedImage = SharedGalleryImage(image: loaded)
                        } label: {
                            Label("Share or Save Image…", systemImage: "square.and.arrow.up")
                        }
                    }
                    .accessibilityAction(named: "Share or Save Image") {
                        sharedImage = SharedGalleryImage(image: loaded)
                    }
            } else if store.failedURLs.contains(image.url) {
                unavailable
            } else {
                ProgressView()
            }
        }
        .ignoresSafeArea()
        .accessibilityLabel(image.altText ?? "SpaceX image")
        .sheet(item: $sharedImage) { item in
            GalleryShareSheet(image: item.image)
        }
    }
#endif

    private var unavailable: some View {
        VStack {
            ContentUnavailableView(
                "Image unavailable",
                systemImage: "photo",
                description: Text("The image could not be loaded.")
            )
            Button("Retry") {
                Task { _ = await store.load(image.url) }
            }
            .padding(.bottom, 40)
        }
    }
}

#if !os(tvOS)
private final class GalleryDismissalState {
    // Kept outside GestureState because SwiftUI resets that state when a drag ends.
    var dragAllowed = false
    var allowedByImage: [GalleryImage.ID: Bool] = [:]
}

private struct GalleryDismissDrag {
    var allowed: Bool?
    var offset: CGFloat = 0
}

private struct ZoomableRemoteImage: UIViewRepresentable {
    var image: UIImage
    var onDismissEligibilityChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = CenteringScrollView()
        scrollView.delegate = context.coordinator
        scrollView.onBoundsSizeChanged = { [weak coordinator = context.coordinator] in
            coordinator?.updateImageViewSize()
        }
        scrollView.backgroundColor = .black
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.bounces = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.delaysContentTouches = false
        scrollView.panGestureRecognizer.isEnabled = false

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = true

        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delaysTouchesBegan = false
        doubleTap.delaysTouchesEnded = false
        doubleTap.delegate = context.coordinator
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.onDismissEligibilityChanged = onDismissEligibilityChanged
        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        context.coordinator.doubleTapRecognizer = doubleTap
        context.coordinator.setImage(image)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onDismissEligibilityChanged = onDismissEligibilityChanged
        context.coordinator.scrollView = scrollView
        if context.coordinator.imageView?.image !== image {
            scrollView.setZoomScale(1, animated: false)
            scrollView.contentOffset = .zero
            scrollView.panGestureRecognizer.isEnabled = false
            context.coordinator.setImage(image)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        weak var doubleTapRecognizer: UITapGestureRecognizer?
        var onDismissEligibilityChanged: ((Bool) -> Void)?
        private var panStartedAwayFromTop = false

        private func updateDismissEligibility(_ scrollView: UIScrollView) {
            let zoomedOut = scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01
            let atTop = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 1
            onDismissEligibilityChanged?(
                !scrollView.isZooming && !panStartedAwayFromTop && (zoomedOut || atTop)
            )
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            panStartedAwayFromTop = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
                && scrollView.contentOffset.y > -scrollView.adjustedContentInset.top + 1
            updateDismissEligibility(scrollView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateDismissEligibility(scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            panStartedAwayFromTop = false
            updateDismissEligibility(scrollView)
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            onDismissEligibilityChanged?(false)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            updateDismissEligibility(scrollView)
        }

        func setImage(_ image: UIImage) {
            imageView?.image = image
            scrollView?.setZoomScale(1, animated: false)
            updateImageViewSize()
            centerImage()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            centerImage()
            updateDismissEligibility(scrollView)
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }

            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                scrollView.panGestureRecognizer.isEnabled = false
                return
            }

            let location = recognizer.location(in: imageView)
            let targetScale = zoomToFillScale(in: scrollView)
            let zoomRect = zoomRect(for: targetScale, centeredAt: location, in: scrollView)
            scrollView.zoom(to: zoomRect, animated: true)
            scrollView.panGestureRecognizer.isEnabled = true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === doubleTapRecognizer
        }

        private func zoomToFillScale(in scrollView: UIScrollView) -> CGFloat {
            let fittedSize = fittedImageSize(in: scrollView.bounds.size)
            guard fittedSize.width > 0, fittedSize.height > 0 else { return 2 }
            let scale = max(
                scrollView.bounds.width / fittedSize.width,
                scrollView.bounds.height / fittedSize.height
            )
            return min(max(scale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        }

        private func zoomRect(for scale: CGFloat, centeredAt center: CGPoint, in scrollView: UIScrollView) -> CGRect {
            let size = CGSize(
                width: scrollView.bounds.width / scale,
                height: scrollView.bounds.height / scale
            )
            return CGRect(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        }

        func updateImageViewSize() {
            guard let scrollView else { return }
            let fittedSize = fittedImageSize(in: scrollView.bounds.size)
            imageView?.frame = CGRect(origin: .zero, size: fittedSize)
            scrollView.contentSize = fittedSize
            centerImage()
        }

        private func fittedImageSize(in viewportSize: CGSize) -> CGSize {
            guard viewportSize.width > 0,
                  viewportSize.height > 0,
                  let image = imageView?.image,
                  image.size.width > 0,
                  image.size.height > 0 else {
                return viewportSize
            }

            let imageAspectRatio = image.size.width / image.size.height
            let viewportAspectRatio = viewportSize.width / viewportSize.height

            if imageAspectRatio > viewportAspectRatio {
                return CGSize(
                    width: viewportSize.width,
                    height: viewportSize.width / imageAspectRatio
                )
            } else {
                return CGSize(
                    width: viewportSize.height * imageAspectRatio,
                    height: viewportSize.height
                )
            }
        }

        private func centerImage() {
            guard let scrollView, let imageView else { return }

            let boundsSize = scrollView.bounds.size
            let contentSize = scrollView.contentSize
            let centerX = contentSize.width < boundsSize.width
                ? boundsSize.width / 2
                : contentSize.width / 2
            let centerY = contentSize.height < boundsSize.height
                ? boundsSize.height / 2
                : contentSize.height / 2
            imageView.center = CGPoint(x: centerX, y: centerY)

            if scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 {
                scrollView.contentOffset = .zero
            } else {
                scrollView.contentOffset = CGPoint(
                    x: min(max(scrollView.contentOffset.x, 0), max(0, contentSize.width - boundsSize.width)),
                    y: min(max(scrollView.contentOffset.y, 0), max(0, contentSize.height - boundsSize.height))
                )
            }

            scrollView.contentInset = .zero
            imageView.setNeedsLayout()
            updateDismissEligibility(scrollView)
        }
    }

    final class CenteringScrollView: UIScrollView {
        var onBoundsSizeChanged: (() -> Void)?
        private var lastBoundsSize: CGSize = .zero

        override func layoutSubviews() {
            super.layoutSubviews()

            guard bounds.size != lastBoundsSize else { return }
            lastBoundsSize = bounds.size
            onBoundsSizeChanged?()
        }
    }
}
#endif

// The same prepared images are used by prefetching and both gallery renderers.
@MainActor
final class GalleryImageStore: ObservableObject {
    @Published private(set) var images: [URL: UIImage] = [:]
    @Published private(set) var failedURLs: Set<URL> = []
    private var requests: [URL: (id: UUID, task: Task<UIImage?, Never>)] = [:]

    private let fetchImage: @Sendable (URL) async -> UIImage?

    init(fetchImage: @escaping @Sendable (URL) async -> UIImage? = { await GalleryImageStore.downloadImage($0) }) {
        self.fetchImage = fetchImage
    }

    func load(_ url: URL) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        if let image = images[url] { return image }
        let request: (id: UUID, task: Task<UIImage?, Never>)
        if let existing = requests[url] {
            request = existing
        } else {
            let fetchImage = self.fetchImage
            request = (UUID(), Task.detached(priority: .userInitiated) {
                await fetchImage(url)
            })
            requests[url] = request
        }
        let image = await request.task.value
        // A cancelled/evicted request must not repopulate the rolling cache.
        if requests[url]?.id == request.id {
            requests[url] = nil
            if let image {
                images[url] = image
                failedURLs.remove(url)
            } else {
                failedURLs.insert(url)
            }
        }
        return image
    }

    nonisolated private static func downloadImage(_ url: URL) async -> UIImage? {
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let image = UIImage(data: data),
                  let prepared = image.preparingForDisplay() else { return nil }
            try Task.checkCancellation()
            return prepared
        } catch {
            return nil
        }
    }

    static func windowURLs(_ urls: [URL], around index: Int) -> Set<URL> {
        guard urls.indices.contains(index) else { return [] }
        return Set((-1...2).map { urls[(index + $0 + urls.count) % urls.count] })
    }

    func prefetch(_ urls: [URL], around index: Int) async {
        guard !Task.isCancelled else { return }
        let retained = Self.windowURLs(urls, around: index)
        images = images.filter { retained.contains($0.key) }
        failedURLs.formIntersection(retained)
        for url in Array(requests.keys) where !retained.contains(url) {
            requests.removeValue(forKey: url)?.task.cancel()
        }
        await withTaskGroup(of: Void.self) { group in
            for url in retained {
                group.addTask { _ = await self.load(url) }
            }
        }
    }

    func cancelAll() {
        for request in requests.values { request.task.cancel() }
        requests.removeAll()
        images.removeAll()
        failedURLs.removeAll()
    }
}

#if !os(tvOS)
private struct SharedGalleryImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct GalleryShareSheet: UIViewControllerRepresentable {
    var image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
#endif
