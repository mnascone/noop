import SwiftUI
import StrandDesign

/// The Workouts tab: what's happening now, auto-tracking, and the full history.
struct WorkoutsHubView: View {
    @ObservedObject private var tracker = AutoWorkoutTracker.shared
    @AppStorage(AutoTrackingPrefs.placesEnabledKey) private var placesEnabled = false
    @AppStorage(AutoTrackingPrefs.walkEnabledKey) private var walkEnabled = false

    var body: some View {
        ScreenScaffold(title: "Workouts") {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                WorkoutStartControl()
                LiveIntervalCard()
                autoTrackingCard
                historyCard
            }
        }
    }

    private var autoTrackingCard: some View {
        NavigationLink {
            AutoTrackingSettingsView()
        } label: {
            NoopCard {
                HStack(spacing: NoopMetrics.space3) {
                    Image(systemName: "location.circle.fill")
                        .font(.title2)
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                        Text("Auto-tracking")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(statusLine)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var statusLine: String {
        guard placesEnabled || walkEnabled else {
            return String(localized: "Off. Pin your gym or rink and workouts start and stop on their own.")
        }
        var parts: [String] = []
        if placesEnabled {
            let n = tracker.places.count
            parts.append(n == 1 ? String(localized: "1 place") : String(localized: "\(n) places"))
        }
        if walkEnabled { parts.append(String(localized: "walks and runs")) }
        var line = String(localized: "On: \(parts.joined(separator: ", ")).")
        if let here = tracker.place(id: tracker.currentPlaceId) {
            line += " " + String(localized: "You're at \(here.name).")
        }
        return line
    }

    private var historyCard: some View {
        NavigationLink(value: TabRoute.workouts) {
            NoopCard {
                HStack(spacing: NoopMetrics.space3) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.title2)
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                        Text("All workouts")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("See, edit, rename or delete any workout.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
