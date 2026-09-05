import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var library: BroadcastLibrary
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.televisionDisplayMetrics) private var televisionMetrics
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

            ScrollView {
                VStack(alignment: .leading, spacing: televisionMetrics.scaled(34)) {
                    if library.showsSpaceXLogos {
                        VStack(alignment: .leading, spacing: televisionMetrics.scaled(22)) {
                            Text("X API")
                                .televisionFont(.title2.weight(.semibold), style: .title2, weight: .semibold)

                            SecureField("Bearer Token", text: $library.xAPIBearerToken)
                                .televisionFont(.body, style: .body, weight: .medium)
                                .textContentType(.password)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .padding(.horizontal, televisionMetrics.scaled(18))
                                .padding(.vertical, televisionMetrics.scaled(14))
                                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(.white.opacity(tokenFocused ? 0.65 : 0.14), lineWidth: tokenFocused ? 3 : 1)
                                }
                                .focused($tokenFocused)

                            Toggle("Use your Bearer Token", isOn: $library.usesXAPIBearerToken)
                                .televisionFont(.body.weight(.medium), style: .body, weight: .medium)

//                    Button {
//                        Task { await library.refresh() }
//                    } label: {
//                        Label("Refresh Broadcasts", systemImage: "arrow.clockwise")
//                            .font(.title3.weight(.semibold))
//                    }

                            Text(library.usesXAPIBearerToken ? "Using your token for X API timeline discovery." : "Using X API cache for timeline discovery.")
                                .televisionFont(.callout, style: .callout, weight: .medium)
                                .foregroundStyle(.secondary)
                        }
                        .padding(televisionMetrics.scaled(28))
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading, spacing: televisionMetrics.scaled(18)) {
                        Text("Settings")
                            .televisionFont(.title2.weight(.semibold), style: .title2, weight: .semibold)

                        Toggle("Show next launch countdown", isOn: $library.showsNextLaunchCountdown)
                            .televisionFont(.body.weight(.medium), style: .body, weight: .medium)

                        Toggle("Show card filters", isOn: $library.showsCardFilters)
                            .televisionFont(.body.weight(.medium), style: .body, weight: .medium)

                        Toggle("Prefer MP4 playback", isOn: $library.prefersMP4Playback)
                            .televisionFont(.body.weight(.medium), style: .body, weight: .medium)
                            .onChange(of: library.prefersMP4Playback) {
                                Task { await library.refresh() }
                            }

                        Toggle("Show player debug overlay", isOn: $library.showsPlayerDebugOverlay)
                            .televisionFont(.body.weight(.medium), style: .body, weight: .medium)

                        Button("Delete Caches", role: .destructive) {
                            showingDeleteConfirm = true
                        }
                        .televisionFont(.body.weight(.medium), style: .body, weight: .medium)
                    }
                    .padding(televisionMetrics.scaled(28))
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

                    VStack(spacing: televisionMetrics.scaled(18)) {
                        Text("Made on Earth by humans")
                            .televisionFont(.callout, style: .callout, weight: .medium)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)

                        HStack(spacing: televisionMetrics.scaled(5)) {
                            Text("T+")
                                .foregroundStyle(.white.opacity(0.38))

                            Text(formattedViewingTime)
                                .foregroundStyle(.white.opacity(0.68))
                        }
                        .televisionFont(
                            .callout.weight(.bold).monospacedDigit(),
                            style: .callout,
                            weight: .bold,
                            design: .monospaced
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Time watched \(formattedViewingTime)")

                        if !versionText.isEmpty {
                            Text(versionText)
                                .televisionFont(.callout, style: .callout, weight: .medium)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .opacity(0.6)
                        }
                    }
                    .padding(televisionMetrics.scaled(28))
                }
                .frame(maxWidth: televisionMetrics.scaled(920), alignment: .topLeading)
                .padding(
                    .horizontal,
                    televisionMetrics.isEnabled
                        ? televisionMetrics.scaled(84)
                        : (horizontalSizeClass == .compact ? 24 : 84)
                )
                .padding(.vertical, televisionMetrics.scaled(54))
            }
        }
        // .navigationTitle("Settings")
    }
}
