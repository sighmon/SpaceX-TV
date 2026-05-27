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
            VStack(alignment: .leading, spacing: 16) {
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

                VStack(alignment: .leading, spacing: 8) {
                    if let tweetText = gallery.tweetText, !tweetText.isEmpty {
                        Text(displayText(from: tweetText))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                    }

                    Text(positionText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(16)
                .frame(maxWidth: 620, alignment: .leading)
                .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.top, 18)
            .padding(.leading, 22)
#endif
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
#if os(tvOS)
        .animation(.easeOut(duration: 0.18), value: showsPlaybackIcon)
#endif
        .onAppear {
            selectedImageID = selectedImageID ?? gallery.galleryImages.first?.id
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

    private func displayText(from text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.hasPrefix("http://") && !$0.hasPrefix("https://") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

private struct GalleryImagePage: View {
    var image: GalleryImage

    var body: some View {
        GeometryReader { proxy in
            AsyncImage(url: image.url, transaction: Transaction(animation: .easeOut(duration: 0.18))) { phase in
                switch phase {
                case .success(let loadedImage):
                    loadedImage
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
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

    private var unavailable: some View {
        ContentUnavailableView(
            "Image unavailable",
            systemImage: "photo",
            description: Text("The image could not be loaded.")
        )
    }
}
