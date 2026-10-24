import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

/// Battery and Devices behind one switch, opened from the battery button on Today.
struct BatteryDevicesView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case battery, devices
        var id: String { rawValue }
        var title: LocalizedStringKey { self == .battery ? "Battery" : "Devices" }
    }

    @State var tab: Tab

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.top, NoopMetrics.space2)
            .padding(.bottom, NoopMetrics.space1)
            ZStack {
                if tab == .battery { BatteryCenterView() } else { DevicesView() }
            }
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }
}

/// Strap battery: level over time, what drains it, and switches to make it last longer.
struct BatteryCenterView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @ObservedObject private var log = BatteryLog.shared

    @AppStorage(PuffinExperiment.keepRealtimeForDataKey) private var continuousHrv = false
    @AppStorage(LiveRepTracker.enabledKey) private var repCounting = false
    @AppStorage(UnitPrefs.liveActivityKey) private var banner = true
    @AppStorage(AutoTrackingPrefs.placesEnabledKey) private var places = false
    @AppStorage(AutoTrackingPrefs.walkEnabledKey) private var walks = false
    @AppStorage("enableRawCapture") private var rawCapture = false
    @AppStorage(SetReadyPrefs.buzzKey) private var setBuzz = false

    @State private var range = 7

    private var analysis: BatteryDrainAnalysis.Result {
        let cutoff = Date().timeIntervalSince1970 - Double(range) * 86_400
        return BatteryDrainAnalysis.analyze(log.samples.filter { $0.ts >= cutoff }) {
            Repository.localDayKey(Date(timeIntervalSince1970: $0))
        }
    }

    var body: some View {
        let a = analysis
        ScreenScaffold(title: "Battery", topBackground: liquidScaffoldSky()) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                nowCard(a)
                historyCard(a)
                effectorsCard(a)
                conserveCard
            }
        }
    }

    // MARK: Now

    private func nowCard(_ a: BatteryDrainAnalysis.Result) -> some View {
        NoopCard {
            HStack(spacing: NoopMetrics.space4) {
                BigBattery(pct: live.batteryPct, charging: live.charging == true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(live.batteryPct.map { "\(Int($0.rounded()))%" } ?? "–")
                        .font(StrandFont.number(34))
                        .foregroundStyle(StrandPalette.textPrimary)
                    if live.charging == true {
                        Text("Charging").font(StrandFont.subhead).foregroundStyle(StrandPalette.statusPositive)
                    } else if let est = live.batteryEstimate {
                        Text(String(localized: "About \(Self.left(est.remainingHours)) left"))
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                    if let r = a.ratePerHour {
                        Text(String(format: String(localized: "Using %.1f%% a day lately"), r * 24))
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    static func left(_ hours: Double) -> String {
        hours < 48 ? String(localized: "\(Int(hours.rounded())) hours")
            : String(format: String(localized: "%.1f days"), hours / 24)
    }

    // MARK: History

    private func historyCard(_ a: BatteryDrainAnalysis.Result) -> some View {
        let cutoff = Date().timeIntervalSince1970 - Double(range) * 86_400
        let points = log.samples.filter { $0.ts >= cutoff }
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack {
                    Text("Battery over time").strandOverline()
                    Spacer()
                    Picker("Range", selection: $range) {
                        Text("2D").tag(2)
                        Text("7D").tag(7)
                        Text("14D").tag(14)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }
                if points.count >= 2 {
                    Chart(points, id: \.ts) { p in
                        AreaMark(x: .value("Time", Date(timeIntervalSince1970: p.ts)), y: .value("Battery", p.pct))
                            .foregroundStyle(LinearGradient(colors: [StrandPalette.statusPositive.opacity(0.35), .clear],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", Date(timeIntervalSince1970: p.ts)), y: .value("Battery", p.pct))
                            .foregroundStyle(StrandPalette.statusPositive)
                            .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis {
                        AxisMarks(values: [0, 50, 100]) { v in
                            AxisGridLine()
                            AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") }
                        }
                    }
                    .frame(height: 140)
                } else {
                    Text("NOOP starts logging the strap's battery now. The chart fills in over the next few hours.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let days = a.dailyUse.suffix(range)
                if days.count >= 2 {
                    Text("Used per day").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    Chart(Array(days.enumerated()), id: \.offset) { _, d in
                        BarMark(x: .value("Day", Self.short(d.day)), y: .value("Used", d.pct))
                            .foregroundStyle(StrandPalette.accent.gradient)
                            .cornerRadius(3)
                            .annotation(position: .top) {
                                Text("\(Int(d.pct.rounded()))").font(.system(size: 9)).foregroundStyle(StrandPalette.textTertiary)
                            }
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 90)
                }
            }
        }
    }

    private static func short(_ key: String) -> String {
        let p = key.split(separator: "-")
        return p.count == 3 ? "\(Int(p[1]) ?? 0)/\(Int(p[2]) ?? 0)" : key
    }

    // MARK: Effectors

    private func effectorsCard(_ a: BatteryDrainAnalysis.Result) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("What drains it").strandOverline()
                let costs = a.costs.filter { $0.extraPerHour > 0.02 }
                if let base = a.ratePerHour, !costs.isEmpty {
                    let top = costs.map(\.extraPerHour).max() ?? 1
                    ForEach(costs, id: \.feature) { c in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(Self.name(c.feature)).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                Text(String(format: String(localized: "+%.1f%% a day"), c.extraPerHour * 24))
                                    .font(StrandFont.captionNumber.weight(.semibold))
                                    .foregroundStyle(c.extraPerHour >= base * 0.5 ? StrandPalette.recovery030 : StrandPalette.textSecondary)
                            }
                            GeometryReader { g in
                                Capsule().fill(StrandPalette.recovery030.opacity(0.75))
                                    .frame(width: max(4, g.size.width * c.extraPerHour / top))
                            }
                            .frame(height: 5)
                            Text(String(format: String(localized: "On for %.0f h. %.2f%%/h on, %.2f%%/h off."),
                                        c.hoursOn, c.rateOn, c.rateOff))
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    Text("Compares drain while each feature was on against while it was off. Features that run together (like a workout and its live heart rate) share the cost.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Not enough yet. Each feature needs at least an hour both on and off while the strap is off the charger before NOOP can compare.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func name(_ f: BatteryDrainAnalysis.Feature) -> String {
        switch f {
        case .liveHeartRate: return String(localized: "Live heart rate stream")
        case .motionStream: return String(localized: "Rep counting (motion stream)")
        case .workout: return String(localized: "Workouts")
        case .continuousHrv: return String(localized: "Continuous HRV capture")
        case .rawCapture: return String(localized: "Raw data capture")
        case .lockScreenBanner: return String(localized: "Lock Screen banner")
        }
    }

    // MARK: Conserve

    private var conserveCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Save battery").strandOverline()
                Text("Switch off what you don't need. Each one keeps the strap's radio or sensors busy.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                toggle("Continuous HRV capture", "Streams heart rate around the clock. The biggest drain.", $continuousHrv)
                    .onChange(of: continuousHrv) { _, on in model.ble.setKeepRealtimeForData(on) }
                toggle("Auto-track at my places", "Turns on live heart rate when you arrive.", $places)
                toggle("Auto-track walks and runs", "Turns on live heart rate when you set off.", $walks)
                toggle("Count reps from wrist motion", "Streams motion during lifting. WHOOP 5.0 and MG.", $repCounting)
                toggle("Lock Screen banner", "Keeps live heart rate flowing to the banner.", $banner)
                toggle("Buzz when ready for next set", "One buzz per rest.", $setBuzz)
                if rawCapture {
                    toggle("Raw data capture", "Diagnostics only.", $rawCapture)
                }
            }
        }
    }

    private func toggle(_ title: LocalizedStringKey, _ note: LocalizedStringKey, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text(note).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(StrandPalette.accent)
    }
}

/// A large battery shape filled to the level.
private struct BigBattery: View {
    let pct: Double?
    let charging: Bool

    var body: some View {
        let frac = CGFloat(min(100, max(0, pct ?? 0))) / 100
        let fill: Color = (pct ?? 0) <= 15 ? StrandPalette.recovery000
            : ((pct ?? 0) <= 35 ? StrandPalette.recovery055 : StrandPalette.statusPositive)
        HStack(spacing: 3) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(StrandPalette.textSecondary.opacity(0.6), lineWidth: 2.5)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill.gradient)
                    .frame(width: max(4, 70 * frac))
                    .padding(5)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 80, height: 40)
            RoundedRectangle(cornerRadius: 2).fill(StrandPalette.textSecondary.opacity(0.6))
                .frame(width: 4, height: 14)
        }
        .accessibilityHidden(true)
    }
}
