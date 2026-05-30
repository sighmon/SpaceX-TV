import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var library: BroadcastLibrary
    @FocusState private var tokenFocused: Bool

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (version?, build?):
            return "Version \(version) (\(build))"
        case let (version?, nil):
            return "Version \(version)"
        case let (nil, build?):
            return "Build \(build)"
        default:
            return ""
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.03, blue: 0.04), Color(red: 0.09, green: 0.10, blue: 0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 22) {
                    Text("X API")
                        .font(.title2.weight(.semibold))

                    SecureField("Bearer Token", text: $library.xAPIBearerToken)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.white.opacity(tokenFocused ? 0.65 : 0.14), lineWidth: tokenFocused ? 3 : 1)
                        }
                        .focused($tokenFocused)

                    Button {
                        Task { await library.refresh() }
                    } label: {
                        Label("Refresh Broadcasts", systemImage: "arrow.clockwise")
                            .font(.title3.weight(.semibold))
                    }

                    Text("The token is saved to Keychain and used for X API timeline discovery.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 18) {
                    Text("Launches")
                        .font(.title2.weight(.semibold))

                    Toggle("Show next launch countdown", isOn: $library.showsNextLaunchCountdown)
                        .font(.body.weight(.medium))
                }
                .padding(28)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 18) {
                    Text("Playback")
                        .font(.title2.weight(.semibold))

                    Toggle("Show player debug overlay", isOn: $library.showsPlayerDebugOverlay)
                        .font(.body.weight(.medium))
                }
                .padding(28)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

                VStack(spacing: 18) {
                    Text("Made on Earth by humans")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    if !versionText.isEmpty {
                        Text(versionText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .opacity(0.6)
                    }
                }
                .padding(28)
            }
            .frame(maxWidth: 920, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 84)
            .padding(.vertical, 54)
        }
        // .navigationTitle("Settings")
    }
}
