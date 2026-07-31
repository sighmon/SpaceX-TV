import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var library: BroadcastLibrary
    @FocusState private var tokenFocused: Bool
    @State private var showingDeleteConfirm = false

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

    private var formattedViewingTime: String {
        let totalSeconds = max(0, Int(library.totalViewingTime.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
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
                if library.showsSpaceXLogos {
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

                        Toggle("Use your Bearer Token", isOn: $library.usesXAPIBearerToken)
                            .font(.body.weight(.medium))

//                    Button {
//                        Task { await library.refresh() }
//                    } label: {
//                        Label("Refresh Broadcasts", systemImage: "arrow.clockwise")
//                            .font(.title3.weight(.semibold))
//                    }

                        Text(library.usesXAPIBearerToken ? "Using your token for X API timeline discovery." : "Using X API cache for timeline discovery.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 18) {
                    Text("Settings")
                        .font(.title2.weight(.semibold))

                    Toggle("Show next launch countdown", isOn: $library.showsNextLaunchCountdown)
                        .font(.body.weight(.medium))

                    Toggle("Show card filters", isOn: $library.showsCardFilters)
                        .font(.body.weight(.medium))

                    Toggle("Prefer MP4 playback", isOn: $library.prefersMP4Playback)
                        .font(.body.weight(.medium))
                        .onChange(of: library.prefersMP4Playback) {
                            Task { await library.refresh() }
                        }

                    Toggle("Show player debug overlay", isOn: $library.showsPlayerDebugOverlay)
                        .font(.body.weight(.medium))

                    Button("Delete Caches", role: .destructive) {
                        showingDeleteConfirm = true
                    }
                    .font(.body.weight(.medium))
                }
                .padding(28)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .confirmationDialog(
                    "Delete cached data?",
                    isPresented: $showingDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete App Cache and Card Checks", role: .destructive) {
                        library.clearCaches()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Clears the daily broadcast cache and the per-card check results that speed up refreshes and daily updates. On-screen content remains until you refresh.")
                }

                VStack(spacing: 18) {
                    Text("Made on Earth by humans")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    HStack(spacing: 5) {
                        Text("T+")
                            .foregroundStyle(.white.opacity(0.38))

                        Text(formattedViewingTime)
                            .foregroundStyle(.white.opacity(0.68))
                    }
                    .font(.callout.weight(.bold).monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Time watched \(formattedViewingTime)")

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
