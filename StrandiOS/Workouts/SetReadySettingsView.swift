import SwiftUI
import StrandDesign
import StrandAnalytics

/// Settings for the lifting "ready for the next set" light and the rest timer.
struct SetReadySettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SetReadyPrefs.enabledKey) private var enabled = true
    @AppStorage(SetReadyPrefs.autoKey) private var auto = true
    @AppStorage(SetReadyPrefs.greenKey) private var green = 110
    @AppStorage(SetReadyPrefs.yellowKey) private var yellow = 125
    @AppStorage(SetReadyPrefs.minRestKey) private var minRest = 45
    @AppStorage(SetReadyPrefs.targetRestKey) private var targetRest = 120
    @AppStorage(SetReadyPrefs.buzzKey) private var buzz = false
    @AppStorage(LiveRepTracker.enabledKey) private var repCounting = false
    @AppStorage(SetReadyPrefs.panelKey) private var showPanel = true

    /// Today's personal thresholds for a typical hard set (75% of heart-rate reserve).
    private var recommended: SetReadiness.Thresholds? {
        guard let b = LiveIntervalTracker.basis(model) else { return nil }
        return SetReadiness.thresholds(config: SetReadiness.Config(), restingBpm: b.resting, setPeakBpm: nil,
                                       age: b.age, hrvRatio: b.hrvRatio)
    }

    private var hrvLine: String? {
        guard let r = LiveIntervalTracker.basis(model)?.hrvRatio else { return nil }
        let pct = Int(((r - 1) * 100).rounded())
        if abs(pct) < 5 { return String(localized: "Last night's HRV was about your usual, so the standard recovery applies.") }
        return pct < 0
            ? String(localized: "Last night's HRV was \(-pct)% under your usual, so it asks for more recovery between sets.")
            : String(localized: "Last night's HRV was \(pct)% over your usual, so it lets you go a little sooner.")
    }

    var body: some View {
        Form {
            Section {
                Toggle("Sets and rest on the workout screen", isOn: $showPanel)
            } footer: {
                Text("During a workout: sets, the rest timer against your target, reps and the ready light. Off hides the panel on the workout screen and in Workouts. The Lock Screen banner fields are set separately.")
            }

            Section {
                Toggle("Ready-for-next-set light", isOn: $enabled)
                Toggle("Buzz the strap when ready", isOn: $buzz).disabled(!enabled)
            } footer: {
                Text("While you rest between lifting sets, a light turns green once your heart rate has come back down enough, yellow when it's close, red while it's still high. Add \"Ready for next set\" to the Lock Screen banner to see it there.")
            }

            Section {
                Picker("Thresholds", selection: $auto) {
                    Text("Personal (from HRV)").tag(true)
                    Text("Custom").tag(false)
                }
                if auto {
                    if let r = recommended {
                        LabeledContent("Green at or under", value: "\(r.greenBpm) bpm")
                        LabeledContent("Yellow at or under", value: "\(r.yellowBpm) bpm")
                    }
                } else {
                    Stepper("Green at or under \(green) bpm", value: $green, in: 70...170)
                    Stepper("Yellow at or under \(yellow) bpm", value: $yellow, in: (green + 1)...190)
                    if let r = recommended {
                        Button("Use today's recommendation (\(r.greenBpm) / \(r.yellowBpm))") {
                            green = r.greenBpm
                            yellow = r.yellowBpm
                        }
                    }
                }
            } header: {
                Text("Heart rate")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Personal thresholds come from how high your heart rate went in the set you just finished: green once most of that rise has come back off. Shown here for a typical hard set. During a workout they follow your actual sets.")
                    if let hrvLine { Text(hrvLine) }
                }
            }

            Section {
                Stepper("Minimum rest \(LiveIntervalTracker.clock(minRest))", value: $minRest, in: 0...300, step: 15)
                Stepper("Target rest \(LiveIntervalTracker.clock(targetRest))", value: $targetRest, in: 30...600, step: 15)
            } header: {
                Text("Rest between sets")
            } footer: {
                Text("The light stays at most yellow until the minimum rest has passed. The rest timer counts down to the target, then counts up past it.")
            }

            Section {
                Toggle("Count reps from wrist motion", isOn: $repCounting)
            } footer: {
                Text("WHOOP 5.0 and MG only. Uses more strap battery while you lift.")
            }
        }
        .navigationTitle("Sets and rest")
        .navigationBarTitleDisplayMode(.inline)
    }
}
