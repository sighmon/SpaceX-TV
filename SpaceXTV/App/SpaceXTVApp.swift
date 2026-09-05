import SwiftUI
import UIKit

@MainActor
final class AppNavigationState: ObservableObject {
    @Published var selectedBroadcast: Broadcast?
    @Published var selectedGallery: Broadcast?
    @Published var selectedCollection: Broadcast?
    @Published var showsSettings = false
    @Published var isExternalDisplayConnected = false
    @Published private(set) var externalPlaybackPresentationGeneration = 0

    func dismissPlayer() {
        selectedBroadcast = nil
        externalPlaybackPresentationGeneration += 1
    }
}

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let library = BroadcastLibrary()
    let navigation = AppNavigationState()
    let externalPlayback = ExternalPlaybackController()

    private init() {}
}

@main
struct SpaceXTVApp: App {
    @StateObject private var library: BroadcastLibrary
    @StateObject private var navigation: AppNavigationState
    @StateObject private var externalPlayback: ExternalPlaybackController

    init() {
        let environment = AppEnvironment.shared
        _library = StateObject(wrappedValue: environment.library)
        _navigation = StateObject(wrappedValue: environment.navigation)
        _externalPlayback = StateObject(wrappedValue: environment.externalPlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(navigation)
                .environmentObject(externalPlayback)
                .preferredColorScheme(.dark)
        }
    }
}

#if os(iOS)
@MainActor
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        useHighestResolution(on: windowScene.screen)

        let environment = AppEnvironment.shared
        environment.navigation.isExternalDisplayConnected = true
        let externalDisplayScale = min(
            max(windowScene.screen.bounds.width / 1_920, 1),
            2
        )
        let rootView = RootView(
            isExternalDisplay: true,
            externalDisplayScale: externalDisplayScale
        )
            .environmentObject(environment.library)
            .environmentObject(environment.navigation)
            .environmentObject(environment.externalPlayback)
            .preferredColorScheme(.dark)

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: rootView)
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        let environment = AppEnvironment.shared
        environment.externalPlayback.stopAndClear()
        environment.navigation.isExternalDisplayConnected = false
        window = nil
    }

    private func useHighestResolution(on screen: UIScreen) {
        guard let highestResolutionMode = screen.availableModes.max(by: {
            ($0.size.width * $0.size.height) < ($1.size.width * $1.size.height)
        }) else { return }

        screen.currentMode = highestResolutionMode
    }
}
#endif
