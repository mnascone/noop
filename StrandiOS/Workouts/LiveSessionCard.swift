import SwiftUI
import StrandDesign
import StrandAnalytics

/// Live Session (the "silent guardian") entry, shown in the Workouts tab only while a workout runs. Its own
/// view so watching `AppModel` re-renders this card, not the whole tab.
struct LiveSessionCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(LiveSessionPrefs.betaKey) private var liveSessionsBeta = true
    @AppStorage(HapticPrefs.liveSession) private var buzzesOn = true
    @State private var showHow = false
    @State private var showSession = false

    /// Today's target range, the same numbers the session will use.
    private var band: LiveSessionEngine.Band {
        let resting = repo.today?.restingHr ?? repo.days.last(where: { $0.restingHr != nil })?.restingHr ?? 60
        return LiveSessionEngine.band(config: .init(restingHR: Double(resting), hrMax: Double(profile.hrMax),
                                                    charge: repo.today?.recovery))
    }

    var body: some View {
        if liveSessionsBeta, model.activeWorkout != nil {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack(spacing: NoopMetrics.space2) {
                        Image(systemName: "shield.lefthalf.filled")
                            .foregroundStyle(StrandPalette.metricCyan)
                            .accessibilityHidden(true)
                        Text("Live Session")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("BETA")
                            .font(StrandFont.overlineScaled(8.5)).tracking(1.2)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(StrandPalette.surfaceInset))
                        Spacer()
                    }
                    Text(buzzesOn
                         ? "Keeps this workout at the right effort for today's Charge. Your strap buzzes when you drift off target and stays quiet when you're on it."
                         : "Keeps this workout at the right effort for today's Charge. Strap buzzes are off in Settings, so it only shows on the phone.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    let b = band
                    Text("Today's target: \(Int(b.floorBpm.rounded()))–\(Int(b.ceilingBpm.rounded())) bpm")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showHow.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showHow ? "Hide how it works" : "How it works")
                            Image(systemName: showHow ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)

                    if showHow { howItWorks }

                    NoopButton("Start Live Session", systemImage: "shield.lefthalf.filled", kind: .primary,
                               fullWidth: true) {
                        showSession = true
                    }
                }
            }
            .fullScreenCover(isPresented: $showSession) {
                LiveSessionView(onClose: { showSession = false })
            }
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            bullet("The target comes from today's Charge. High Charge raises the ceiling, low Charge lowers it.")
            bullet("Two short buzzes: you've been under the range for a while. Pick it up.")
            bullet("Three long buzzes: you jumped over the range. Back off. A slow drift over it gets no buzz, only a sharp climb does.")
            bullet("It waits 25 seconds out of range before buzzing, skips the first minute while your heart rate catches up, and won't repeat the same buzz within 50 seconds.")
            bullet("If the strap stops sending heart rate it pauses, and after 10 minutes with nothing it ends on its own.")
            bullet("The screen shows one ring. Teal is on target, dim is too easy, hot is too hard. Hold the ring to see your heart rate.")
            bullet("It runs alongside your workout. Ending the session doesn't end the workout.")
        }
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(StrandPalette.textTertiary)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
