import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The top of the Stress screen: the stress level now, the same reading as the Today ring, today's
/// average beside it, and a button to measure the next minute.
struct StressRightNowCard: View {
    @ObservedObject private var stress = StressNow.shared
    @ObservedObject private var service = StressLevelService.shared
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    var body: some View {
        NoopCard(tint: StressRamp.calm) {
            TimelineView(.periodic(from: .now, by: stress.measureEnd != nil ? 1 : 10)) { ctx in
                let r = stress.reading()
                HStack(alignment: .center, spacing: NoopMetrics.space4) {
                    StressRing(reading: r, diameter: 84)
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text("Stress level").strandOverline()
                        Text(headline(r))
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        if let a = service.today?.summary.awakeAverage {
                            Text(String(localized: "Today \(a) avg"))
                                .font(StrandFont.caption.weight(.semibold))
                                .foregroundStyle(StressLevel.Band(level: a).color)
                        }
                        measureButton(now: ctx.date)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear { stress.attach(model: model) }
    }

    private func headline(_ r: StressNow.Reading?) -> String {
        guard let r else {
            return stress.measureEnd != nil ? String(localized: "Measuring…") : String(localized: "No reading yet")
        }
        if r.active { return String(localized: "Active · \(StressNow.label(r.kind))") }
        let band = StressNow.band(r.value).title.capitalized
        return "\(band) · \(StressNow.label(r.kind))"
    }

    static func explain(_ r: StressNow.Reading?) -> String {
        guard let r else {
            return String(localized: "A value is worked out every 3 minutes while you're still, once the strap's heart rate has synced. Measure to see now.")
        }
        if r.active {
            return String(localized: "You're moving, so this stretch counts as activity, not stress, as Garmin does it.")
        }
        switch r.kind {
        case .live:
            return String(localized: "The last 3 minutes of heart rate and beat-to-beat intervals, scored like every stored value.")
        case .estimate:
            return String(localized: "From heart rate while beats for the HRV part arrive.")
        case .measured:
            return String(localized: "Your last measurement. Measure again any time.")
        case .recent:
            return String(localized: "The latest 3-minute value from your strap.")
        case .earlier:
            return String(localized: "Your latest value today. The strap's newer heart rate hasn't synced yet, or you were moving.")
        }
    }

    @ViewBuilder
    private func measureButton(now: Date) -> some View {
        if let end = stress.measureEnd {
            let left = max(0, Int(end.timeIntervalSince(now).rounded()))
            pill(String(localized: "Stop · \(left)s"), icon: "stop.fill", filled: false) { stress.finish() }
        } else if live.connected {
            pill(String(localized: "Measure now"), icon: "waveform.path.ecg", filled: true) { stress.start() }
        } else {
            Text("Strap not connected")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func pill(_ title: String, icon: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).monospacedDigit()
            }
            .font(StrandFont.footnote.weight(.semibold))
            .foregroundStyle(filled ? Color.white : StrandPalette.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(filled ? StrandPalette.accent : StrandPalette.accent.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
