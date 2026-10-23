import SwiftUI
import CoreLocation
import StrandDesign

/// Settings rows for live workout suggestions (gym geofence + walk detection). Embedded in the shared
/// SettingsView under `#if os(iOS)`. Design tokens only.
struct LiveWorkoutSuggestionsSettings: View {

    @ObservedObject private var suggestions = LiveWorkoutSuggestions.shared
    @AppStorage(LiveWorkoutSuggestionPrefs.gymEnabledKey) private var gymEnabled = false
    @AppStorage(LiveWorkoutSuggestionPrefs.walkEnabledKey) private var walkEnabled = false
    @AppStorage(LiveWorkoutSuggestionPrefs.gymSportKey) private var gymSport = LiveWorkoutSuggestionPrefs.defaultGymSport

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Toggle(isOn: $gymEnabled) {
                Text("Gym start and end suggestions")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(StrandPalette.accent)
            .accessibilityHint("Notifies you to start a workout when your heart rate rises at the gym, and to end it when you leave")
            .onChange(of: gymEnabled) { _, on in
                if on { suggestions.requestPermissions() }
                suggestions.applySettings()
            }

            caption("When you arrive at your gym, NOOP turns on live heart rate. If it stays raised for a few minutes, you get a notification to start a workout from when it began. Leaving the gym, or heart rate near resting for 10 minutes, suggests ending it. Needs location set to Always.")

            if gymEnabled {
                gymPlaceRows
                HStack {
                    Text("Workout type")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Picker("Workout type", selection: $gymSport) {
                        ForEach(WorkoutCatalog.all.map(\.name), id: \.self) { name in
                            Text(LocalizedStringKey(name)).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                }
            }

            Toggle(isOn: $walkEnabled) {
                Text("Walk and run start and end suggestions")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(StrandPalette.accent)
            .accessibilityHint("Notifies you to start a walk or run when your iPhone detects one and your heart rate is up")
            .onChange(of: walkEnabled) { _, on in
                if on { suggestions.requestPermissions() }
                suggestions.applySettings()
            }

            caption("After a minute of walking or running, NOOP turns on live heart rate. A brisk walk of 5 minutes (a run of 3) offers to start a workout from when you set off. Stopping for 2 minutes, or getting in a car, offers to end it. Your iPhone must be on you. A walk that starts while NOOP is asleep in the background is noticed late.")

            if gymEnabled || walkEnabled {
                permissionNote
                if suggestions.holdingRealtime {
                    caption("Live heart rate is on for a suggestion right now. This uses more strap battery while it lasts.")
                }
            }
        }
    }

    @ViewBuilder
    private var gymPlaceRows: some View {
        if let gym = suggestions.gym {
            HStack {
                Group {
                    if suggestions.inGym { Text("Gym set. You're there now.") } else { Text("Gym set.") }
                }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Button("Clear") { suggestions.clearGym() }
                    .buttonStyle(.bordered)
            }
            Stepper(value: Binding(get: { gym.radiusM },
                                   set: { suggestions.setGymRadius($0) }),
                    in: LiveWorkoutSuggestionPrefs.minRadiusM...LiveWorkoutSuggestionPrefs.maxRadiusM,
                    step: 50) {
                Text("Radius \(Int(gym.radiusM)) m")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
        Button {
            suggestions.captureGymHere()
        } label: {
            Label(suggestions.gym == nil ? "Set gym to my current location" : "Move gym to my current location",
                  systemImage: "mappin.and.ellipse")
        }
        .buttonStyle(.borderedProminent)
        .tint(StrandPalette.accent)
        .disabled(suggestions.capturingGym)
        if suggestions.capturingGym {
            caption("Getting your location…")
        } else if let err = suggestions.captureError {
            captionVerbatim(err)
        } else if suggestions.gym == nil {
            caption("Tap this while you're at the gym.")
        }
    }

    @ViewBuilder
    private var permissionNote: some View {
        switch suggestions.locationAuth {
        case .authorizedAlways:
            EmptyView()
        case .authorizedWhenInUse:
            caption("Location is set to While Using. Arrivals, departures and background walks are only noticed with Always. Change it in iOS Settings > NOOP > Location.")
        case .denied, .restricted:
            caption("Location is off for NOOP, so gym arrivals can't be detected. Change it in iOS Settings > NOOP > Location.")
        default:
            EmptyView()
        }
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func captionVerbatim(_ text: String) -> some View {
        Text(verbatim: text)
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
