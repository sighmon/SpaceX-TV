import SwiftUI

struct GalleryScreen: View {
    @Environment(\.dismiss) private var dismiss
    var gallery: Broadcast
    @State private var selectedImageID: GalleryImage.ID?
#if os(tvOS)
    @State private var isSlideshowPlaying = false
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
                        GalleryImagePage(image: image)
                            .tag(image.id as GalleryImage.ID?)
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
                showsBackButton = false
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

private struct GalleryImagePage: View {
    var image: GalleryImage
    @State private var baseScale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
#if !os(tvOS)
    @State private var baseOffset: CGSize = .zero
    @State private var gestureOffset: CGSize = .zero
#endif

    private var effectiveScale: CGFloat {
        min(max(baseScale * gestureScale, 1), 5)
    }

    var body: some View {
        GeometryReader { proxy in
            AsyncImage(url: image.url, transaction: Transaction(animation: .easeOut(duration: 0.18))) { phase in
                switch phase {
                case .success(let loadedImage):
                    imageView(loadedImage, in: proxy.size)
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
    private func imageView(_ loadedImage: Image, in viewportSize: CGSize) -> some View {
        let fittedImage = loadedImage
            .resizable()
            .scaledToFit()
            .scaleEffect(effectiveScale)
#if !os(tvOS)
            .offset(clampedCurrentOffset(in: viewportSize))
#endif
            .frame(width: viewportSize.width, height: viewportSize.height)

#if os(tvOS)
        fittedImage
#else
        fittedImage
            .gesture(zoomGesture(in: viewportSize))
            .simultaneousGesture(
                panGesture(in: viewportSize),
                including: effectiveScale > 1 ? .gesture : .none
            )
            .simultaneousGesture(doubleTapGesture(in: viewportSize))
#endif
    }

#if !os(tvOS)
    private func zoomGesture(in viewportSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                gestureScale = value
            }
            .onEnded { value in
                baseScale = min(max(baseScale * value, 1), 5)
                gestureScale = 1
                baseOffset = clampedOffset(baseOffset, scale: baseScale, in: viewportSize)
                if baseScale <= 1 {
                    baseOffset = .zero
                    gestureOffset = .zero
                }
            }
    }

    private func panGesture(in viewportSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard effectiveScale > 1 else {
                    gestureOffset = .zero
                    return
                }
                gestureOffset = value.translation
            }
            .onEnded { value in
                guard effectiveScale > 1 else {
                    baseOffset = .zero
                    gestureOffset = .zero
                    return
                }
                let proposedOffset = CGSize(
                    width: baseOffset.width + value.translation.width,
                    height: baseOffset.height + value.translation.height
                )
                baseOffset = clampedOffset(proposedOffset, scale: effectiveScale, in: viewportSize)
                gestureOffset = .zero
            }
    }

    private func doubleTapGesture(in viewportSize: CGSize) -> some Gesture {
        TapGesture(count: 2)
            .onEnded {
                withAnimation(.easeOut(duration: 0.18)) {
                    if effectiveScale > 1.01 {
                        baseScale = 1
                    } else {
                        baseScale = zoomToFillScale(in: viewportSize)
                    }
                    gestureScale = 1
                    baseOffset = .zero
                    gestureOffset = .zero
                }
            }
    }

    private func clampedCurrentOffset(in viewportSize: CGSize) -> CGSize {
        let proposedOffset = CGSize(
            width: baseOffset.width + gestureOffset.width,
            height: baseOffset.height + gestureOffset.height
        )
        return clampedOffset(proposedOffset, scale: effectiveScale, in: viewportSize)
    }

    private func clampedOffset(_ offset: CGSize, scale: CGFloat, in viewportSize: CGSize) -> CGSize {
        guard scale > 1 else { return .zero }
        let limits = panLimits(scale: scale, in: viewportSize)
        return CGSize(
            width: min(max(offset.width, -limits.width), limits.width),
            height: min(max(offset.height, -limits.height), limits.height)
        )
    }

    private func panLimits(scale: CGFloat, in viewportSize: CGSize) -> CGSize {
        let fittedSize = fittedImageSize(in: viewportSize)
        return CGSize(
            width: max(0, (fittedSize.width * scale - viewportSize.width) / 2),
            height: max(0, (fittedSize.height * scale - viewportSize.height) / 2)
        )
    }

    private func zoomToFillScale(in viewportSize: CGSize) -> CGFloat {
        let fittedSize = fittedImageSize(in: viewportSize)
        guard fittedSize.width > 0, fittedSize.height > 0 else { return 1 }
        let scale = max(
            viewportSize.width / fittedSize.width,
            viewportSize.height / fittedSize.height
        )
        return min(max(scale, 1), 5)
    }

    private func fittedImageSize(in viewportSize: CGSize) -> CGSize {
        guard viewportSize.width > 0,
              viewportSize.height > 0,
              let width = image.width,
              let height = image.height,
              width > 0,
              height > 0 else {
            return viewportSize
        }

        let imageAspectRatio = CGFloat(width) / CGFloat(height)
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
#endif

    private var unavailable: some View {
        ContentUnavailableView(
            "Image unavailable",
            systemImage: "photo",
            description: Text("The image could not be loaded.")
        )
    }
}
