import SwiftUI
import CoreLocation
import StrandDesign
import StrandAnalytics

/// Places, automatic vs ask, and the way into set and interval detection settings.
struct AutoTrackingSettingsView: View {
    @ObservedObject private var tracker = AutoWorkoutTracker.shared
    @AppStorage(AutoTrackingPrefs.placesEnabledKey) private var placesEnabled = false
    @AppStorage(AutoTrackingPrefs.walkEnabledKey) private var walkEnabled = false
    @AppStorage(AutoTrackingPrefs.placesModeKey) private var placesModeRaw = AutoTrackingPrefs.Mode.auto.rawValue
    @AppStorage(AutoTrackingPrefs.walkModeKey) private var walkModeRaw = AutoTrackingPrefs.Mode.auto.rawValue
    @AppStorage(LiveRepTracker.enabledKey) private var repCounting = false

    var body: some View {
        Form {
            Section {
                Toggle("Track workouts at my places", isOn: $placesEnabled)
                    .onChange(of: placesEnabled) { _, on in changed(on) }
                if placesEnabled {
                    modePicker($placesModeRaw)
                }
                ForEach(tracker.places) { p in
                    NavigationLink {
                        PlaceEditorView(place: p)
                    } label: {
                        placeRow(p)
                    }
                }
                NavigationLink {
                    PlaceEditorView(place: nil)
                } label: {
                    Label("Add a place", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Places")
            } footer: {
                Text(placesEnabled
                     ? "At a place, live heart rate turns on. Once it stays up for a few minutes the workout starts, dated back to when it rose. It ends when you leave, at the moment your heart rate last dropped."
                     : "Pin your gym, rink or track. Each one gets its own sport and start/stop rules.")
            }

            Section {
                Toggle("Track walks and runs", isOn: $walkEnabled)
                    .onChange(of: walkEnabled) { _, on in changed(on) }
                if walkEnabled {
                    modePicker($walkModeRaw)
                }
            } header: {
                Text("Walks and runs")
            } footer: {
                Text("Your iPhone notices walking or running. A brisk walk of 5 minutes (a run of 3) starts a workout from when you set off. Stopping for 2 minutes or getting in a car ends it. Keep your phone on you. A walk that starts while NOOP is asleep in the background gets picked up late.")
            }

            Section {
                NavigationLink {
                    DetectionSettingsView(sport: "Strength", mode: .lifting, preview: nil)
                } label: {
                    Label("Detection settings", systemImage: "slider.horizontal.3")
                }
            } header: {
                Text("Set and interval detection")
            } footer: {
                Text("Sets and rests are found on their own from heart rate, wrist motion and reps, for Strength, Weightlifting, Bodybuilding, Powerlifting and Calisthenics, and intervals for Assault bike, Sprints, HIIT, CrossFit, Spinning and machines. Correct them in Edit sets, during or after a workout, and detection learns from it for the next one. Nothing here needs changing for everyday use.")
            }

            Section {
                NavigationLink("Ready-for-next-set light and rest timer") { SetReadySettingsView() }
            } header: {
                Text("Lifting")
            }

            Section {
                Toggle("Count reps from wrist motion", isOn: $repCounting)
            } header: {
                Text("Reps (experimental)")
            } footer: {
                Text("WHOOP 5.0 and MG only. During a lifting workout the strap streams its motion sensors, and NOOP counts reps in each set and splits sets where you stop moving. Works when your wrist moves with the weight (presses, curls, rows, pull-ups, bar squats and deadlifts), not when your hands stay still (leg press, leg extension). Uses more strap battery while you lift, and stops when the workout ends.")
            }

            if placesEnabled || walkEnabled {
                Section("Status") {
                    statusRow
                    if tracker.holdingRealtime {
                        Label("Live heart rate is on right now", systemImage: "heart.fill")
                    }
                }
            }
        }
        .navigationTitle("Auto-tracking")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func modePicker(_ binding: Binding<String>) -> some View {
        Picker("When it's sure", selection: binding) {
            Text("Start and stop on its own").tag(AutoTrackingPrefs.Mode.auto.rawValue)
            Text("Ask me first").tag(AutoTrackingPrefs.Mode.ask.rawValue)
        }
        .onChange(of: binding.wrappedValue) { _, _ in tracker.applySettings() }
    }

    private func placeRow(_ p: WorkoutPlace) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: WorkoutTypeIconography.systemSymbolName(for: p.sport))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(p.name)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(p.sport) · starts at +\(p.marginBPM) bpm · stops after \(p.quietEndMin) min low")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if tracker.currentPlaceId == p.id {
                Spacer()
                Text("Here now")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.accent)
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch tracker.locationAuth {
        case .authorizedAlways:
            Label("Location: Always", systemImage: "checkmark.circle")
        case .authorizedWhenInUse:
            Label("Location is set to While Using. Set it to Always in iOS Settings > NOOP > Location, or arrivals and background walks get missed.",
                  systemImage: "exclamationmark.triangle")
        case .denied, .restricted:
            Label("Location is off for NOOP. Places can't work until it's on in iOS Settings > NOOP > Location.",
                  systemImage: "xmark.octagon")
        default:
            Label("Location permission not asked yet.", systemImage: "questionmark.circle")
        }
    }

    private func changed(_ on: Bool) {
        if on { tracker.requestPermissions() }
        tracker.applySettings()
    }
}
