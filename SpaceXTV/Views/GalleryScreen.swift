import SwiftUI
#if !os(tvOS)
import UIKit
#endif

struct GalleryScreen: View {
    @Environment(\.dismiss) private var dismiss
    var gallery: Broadcast
    @State private var selectedImageID: GalleryImage.ID?
#if os(tvOS)
    @State private var isSlideshowPlaying = false
    @State private var imageDisplayMode: GalleryImageDisplayMode = .fill
    @State private var showsPlaybackIcon = false
    @State private var showsCompletionOverlay = false
    @State private var slideshowTask: Task<Void, Never>?
    @State private var playbackIconHideTask: Task<Void, Never>?
#else
    @State private var showsBackButton = true
    @State private var backButtonHideTask: Task<Void, Never>?
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
                        GalleryImagePage(image: image, displayMode: imageDisplayMode)
                            .tag(image.id as GalleryImage.ID?)
#else
                        GalleryImagePage(image: image)
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
#else
            if showsBackButton {
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 30, weight: .semibold))
                        .frame(width: 64, height: 64)
                        .background(.black.opacity(0.58), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel("Back")
                .padding(.top, 18)
                .padding(.leading, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity)
            }
#endif
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
#if os(tvOS)
        .animation(.easeOut(duration: 0.18), value: showsPlaybackIcon)
#endif
        .onAppear {
            selectedImageID = selectedImageID ?? gallery.galleryImages.first?.id
#if !os(tvOS)
            showBackButtonTemporarily()
#endif
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
            stopSlideshow()
            playbackIconHideTask?.cancel()
        }
        .fullScreenCover(isPresented: $showsCompletionOverlay) {
            GalleryCompleteOverlay(
                onBack: {
                    showsCompletionOverlay = false
                    dismiss()
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
        .statusBarHidden(!showsBackButton)
        .simultaneousGesture(
            TapGesture().onEnded {
                showBackButtonTemporarily()
            }
        )
        .animation(.easeOut(duration: 0.18), value: showsBackButton)
        .onDisappear {
            backButtonHideTask?.cancel()
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
        withAnimation(.easeOut(duration: 0.2)) {
            selectedImageID = gallery.galleryImages[nextIndex].id
        }
    }

    private func toggleImageDisplayMode() {
        withAnimation(.easeOut(duration: 0.18)) {
            imageDisplayMode = imageDisplayMode == .fill ? .fit : .fill
        }
    }

    private func toggleSlideshow() {
        guard gallery.galleryImages.count > 1 else { return }
        isSlideshowPlaying ? stopSlideshow() : startSlideshow()
        showPlaybackIconTemporarily()
    }

    private func startSlideshow() {
        isSlideshowPlaying = true
        slideshowTask?.cancel()
        slideshowTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    advanceSlideshow()
                }
            }
        }
    }

    private func stopSlideshow() {
        isSlideshowPlaying = false
        slideshowTask?.cancel()
        slideshowTask = nil
    }

    private func advanceSlideshow() {
        guard gallery.galleryImages.count > 1 else { return }
        if selectedIndex >= gallery.galleryImages.count - 1 {
            stopSlideshow()
            showsCompletionOverlay = true
            return
        }

        withAnimation(.easeOut(duration: 0.2)) {
            selectedImageID = gallery.galleryImages[selectedIndex + 1].id
        }
    }

    private func replaySlideshow() {
        selectedImageID = gallery.galleryImages.first?.id
        startSlideshow()
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
    private func showBackButtonTemporarily() {
        showsBackButton = true
        backButtonHideTask?.cancel()
        backButtonHideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.18)) {
                    showsBackButton = false
                }
            }
        }
    }
#endif
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
#if os(tvOS)
    var displayMode: GalleryImageDisplayMode

    var body: some View {
        GeometryReader { proxy in
            AsyncImage(url: image.url, transaction: Transaction(animation: .easeOut(duration: 0.18))) { phase in
                switch phase {
                case .success(let loadedImage):
                    loadedImageView(loadedImage, size: proxy.size)
                case .failure:
                    unavailable
                        .frame(width: proxy.size.width, height: proxy.size.height)
                case .empty:
                    ProgressView()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                @unknown default:
                    unavailable
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
    var body: some View {
        ZoomableRemoteImage(url: image.url)
            .ignoresSafeArea()
            .accessibilityLabel(image.altText ?? "SpaceX image")
    }
#endif

    private var unavailable: some View {
        ContentUnavailableView(
            "Image unavailable",
            systemImage: "photo",
            description: Text("The image could not be loaded.")
        )
    }
}

#if !os(tvOS)
private struct ZoomableRemoteImage: UIViewRepresentable {
    var url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
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
        imageView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.addSubview(imageView)
        let imageWidth = imageView.widthAnchor.constraint(equalToConstant: 0)
        let imageHeight = imageView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageWidth,
            imageHeight
        ])

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

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        context.coordinator.imageWidthConstraint = imageWidth
        context.coordinator.imageHeightConstraint = imageHeight
        context.coordinator.doubleTapRecognizer = doubleTap
        context.coordinator.loadImage(from: url)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.scrollView = scrollView
        context.coordinator.updateImageViewSize()
        if context.coordinator.url != url {
            scrollView.setZoomScale(1, animated: false)
            scrollView.contentOffset = .zero
            scrollView.panGestureRecognizer.isEnabled = false
            context.coordinator.loadImage(from: url)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        weak var doubleTapRecognizer: UITapGestureRecognizer?
        var imageWidthConstraint: NSLayoutConstraint?
        var imageHeightConstraint: NSLayoutConstraint?
        var url: URL?
        private var imageTask: URLSessionDataTask?

        deinit {
            imageTask?.cancel()
        }

        func loadImage(from url: URL) {
            guard self.url != url else { return }
            self.url = url
            imageTask?.cancel()
            imageView?.image = nil
            updateImageViewSize()

            imageTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self,
                      self.url == url,
                      let data,
                      let image = UIImage(data: data) else {
                    return
                }

                Task { @MainActor in
                    guard self.url == url else { return }
                    self.imageView?.image = image
                    self.scrollView?.setZoomScale(1, animated: false)
                    self.updateImageViewSize()
                    self.centerImage()
                }
            }
            imageTask?.resume()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            centerImage()
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
            imageWidthConstraint?.constant = fittedSize.width
            imageHeightConstraint?.constant = fittedSize.height
            scrollView.layoutIfNeeded()
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

            let horizontalInset = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
            let verticalInset = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
            scrollView.contentInset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: verticalInset,
                right: horizontalInset
            )
            imageView.setNeedsLayout()
        }
    }
}
#endif
