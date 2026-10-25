import SwiftUI
import StrandDesign
import WhoopStore

/// The top of the Stress screen: the same reading as the Today ring, what it's based on, and a button to
/// take a fresh measurement. The day's score below it stays the daily number.
struct StressRightNowCard: View {
    @ObservedObject private var stress = StressNow.shared
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    var body: some View {
        NoopCard(tint: StressRamp.calm) {
            TimelineView(.periodic(from: .now, by: stress.measureEnd != nil ? 1 : 10)) { ctx in
                // This morning's score has its own card below; up here it's either now or nothing.
                let r = stress.reading().flatMap { $0.kind == .today ? nil : $0 }
                HStack(alignment: .center, spacing: NoopMetrics.space4) {
                    StressRing(reading: r, diameter: 76)
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text("Right now").strandOverline()
                        Text(headline(r))
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(Self.explain(r))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let note = Self.differsNote(r, daily: stress.daily) {
                            Text(note)
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        measureButton(now: ctx.date)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear {
            stress.attach(model: model)
            // Opening Stress is asking how you are now: measure straight away when nothing current exists.
            if live.connected, stress.measureEnd == nil,
               stress.reading().map({ $0.kind == .today }) ?? true {
                stress.start()
            }
        }
    }

    private func headline(_ r: StressNow.Reading?) -> String {
        guard let r else {
            return stress.measureEnd != nil ? String(localized: "Measuring…") : String(localized: "Not measured yet")
        }
        if r.active { return String(localized: "Active · \(StressNow.label(r.kind))") }
        let band = StressNow.band(r.value).title.capitalized
        return "\(band) · \(StressNow.label(r.kind))"
    }

    static func explain(_ r: StressNow.Reading?) -> String {
        guard let r else {
            return String(localized: "Measure to see how your nervous system is doing now. It takes about 30 seconds.")
        }
        if r.active {
            return String(localized: "Your heart rate is up from moving, where HRV can't tell stress apart from effort. Measure again once you're still.")
        }
        switch r.kind {
        case .live:
            return String(localized: "Your heart rate and beat-to-beat intervals over the last couple of minutes, scored like the hours below, against today's calm hours.")
        case .estimate:
            return String(localized: "From heart rate while beats for the HRV reading arrive. Firms up in a few seconds.")
        case .measured:
            return String(localized: "Your last measurement. Measure again any time.")
        case .today:
            return String(localized: "Measure to see how your nervous system is doing now.")
        }
    }

    /// When now and this morning's score sit in different bands, say why both can be true.
    static func differsNote(_ r: StressNow.Reading?, daily: Double?) -> String? {
        guard let r, !r.active, r.kind != .today, let d = daily,
              StressNow.band(r.value) != StressNow.band(d) else { return nil }
        let morning = StressNow.band(d).title.capitalized
        let now = StressNow.band(r.value).title.capitalized
        return String(localized: "This morning's score below is \(morning): it's set once from last night. \(now) here is your heart rate and HRV now against today's calm hours.")
    }

    @ViewBuilder
    private func measureButton(now: Date) -> some View {
        if let end = stress.measureEnd {
            let left = max(0, Int(end.timeIntervalSince(now).rounded()))
            pill(String(localized: "Stop · \(left)s"), icon: "stop.fill", filled: false) { stress.finish() }
        } else if live.connected {
            pill(String(localized: "Measure now"), icon: "waveform.path.ecg", filled: true) { stress.start() }
        } else {
            Text("Connect your strap to measure.")
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
