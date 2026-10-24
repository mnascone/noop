import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for an active live-HR session — shown on the Lock Screen and in the Dynamic Island.
struct NOOPLiveActivity: Widget {
    /// The heart rate to draw: none once iOS has marked the banner stale. Each push is fresh for 30 s
    /// (`LiveActivityController.staleAfter`) and NOOP re-pushes a steady number well inside that, so a stale banner
    /// means the readings stopped — the strap off the wrist, or out of reach — even while NOOP itself is asleep and
    /// cannot say so: iOS redraws the banner at the stale date on its own.
    static func shownBpm(_ context: ActivityViewContext<NOOPActivityAttributes>) -> Int? {
        context.isStale ? nil : context.state.bpm
    }

    /// The most recent reading when there is no live one, under 12 hours old, with when it was read.
    static func lastBpm(_ context: ActivityViewContext<NOOPActivityAttributes>) -> (bpm: Int, at: Date)? {
        guard shownBpm(context) == nil else { return nil }
        let s = context.state
        if let b = s.lastBpm, let at = s.lastBpmAt, Date().timeIntervalSince(at) < 12 * 3600 { return (b, at) }
        // A stale banner from a build without the stamp still has its last number.
        if context.isStale, let b = s.bpm { return (b, .distantPast) }
        return nil
    }

    /// The fields to draw: the chosen order, minus workout-only fields when no workout is running. Never
    /// empty (falls back to heart rate).
    static func fields(_ state: NOOPActivityAttributes.ContentState) -> [LiveBannerField] {
        let chosen = state.fields ?? LiveBannerPrefs.defaultFields
        let shown = chosen.filter { !$0.workoutOnly || state.workoutStart != nil }
        return shown.isEmpty ? [.heartRate] : shown
    }

    /// The Dynamic Island's own field, when it has one that can show now; else the first field.
    static func islandField(_ state: NOOPActivityAttributes.ContentState) -> LiveBannerField {
        if let f = state.islandField, !f.workoutOnly || state.workoutStart != nil { return f }
        return fields(state).first ?? .heartRate
    }

    /// The field's icon colour: the user's pick sent with the state, else the field's own default.
    static func tint(_ f: LiveBannerField, _ state: NOOPActivityAttributes.ContentState) -> Color {
        hexColor(LiveBannerPrefs.colorHex(f, overrides: state.colors ?? [:]))
    }

    /// The field's icon. Battery fields follow the strap's level, with a bolt while charging.
    static func symbol(_ f: LiveBannerField, _ state: NOOPActivityAttributes.ContentState) -> String {
        guard f == .battery || f == .batteryTime || f == .batteryFull,
              let raw = state.texts?["batteryLevel"] else { return f.symbol }
        let p = raw.split(separator: "|").map(String.init)
        guard let pct = p.first.flatMap(Int.init) else { return f.symbol }
        if p.count > 1, p[1] == "1" { return "battery.100percent.bolt" }
        switch pct {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func hexColor(_ hex: String) -> Color {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x0A84FF
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NOOPActivityAttributes.self) { context in
            let state = context.state
            let fields = Self.fields(state)
            let labels = state.showLabels ?? true
            Group {
                if (state.layout ?? .featured) == .equal {
                    // All fields the same size.
                    VStack(alignment: .leading, spacing: 6) {
                        if labels, let title = state.title ?? state.workoutSport {
                            Text(title).font(.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                        HStack(spacing: 8) {
                            ForEach(fields, id: \.self) { f in
                                VStack(spacing: 3) {
                                    HStack(spacing: 4) {
                                        Image(systemName: Self.symbol(f, context.state)).font(.caption).foregroundStyle(Self.tint(f, context.state))
                                        if labels {
                                            Text(f.bannerLabel).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
                                                .lineLimit(1).minimumScaleFactor(0.7)
                                        }
                                    }
                                    FieldValue(field: f, context: context, size: .medium)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                } else {
                    // The first field big, the rest beside it.
                    HStack(spacing: 14) {
                        if let primary = fields.first {
                            Image(systemName: Self.symbol(primary, context.state))
                                .font(.title2)
                                .foregroundStyle(Self.tint(primary, context.state))
                            VStack(alignment: .leading, spacing: 2) {
                                if labels {
                                    Text(state.title ?? state.workoutSport ?? primary.bannerLabel)
                                        .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                                }
                                FieldValue(field: primary, context: context, size: .large)
                            }
                        }
                        Spacer()
                        HStack(spacing: 12) {
                            ForEach(Array(fields.dropFirst()), id: \.self) { f in
                                VStack(alignment: .center, spacing: 2) {
                                    if labels {
                                        Text(f.bannerLabel).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
                                    } else {
                                        Image(systemName: Self.symbol(f, context.state)).font(.caption2).foregroundStyle(Self.tint(f, context.state))
                                    }
                                    FieldValue(field: f, context: context, size: .small)
                                }
                                .multilineTextAlignment(.center)
                                .fixedSize()
                            }
                        }
                    }
                }
            }
            .padding()
            .activityBackgroundTint(StrandPalette.surfaceBase)
            .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            let state = context.state
            let island = Self.islandField(state)
            let others = Self.fields(state).filter { $0 != island }
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 4) {
                        Image(systemName: Self.symbol(island, context.state))
                        FieldValue(field: island, context: context, size: .small)
                    }
                    .foregroundStyle(Self.tint(island, context.state))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 10) {
                        ForEach(Array(others.prefix(2)), id: \.self) { f in
                            VStack(alignment: .center, spacing: 1) {
                                Text(f.bannerLabel).font(.caption2).foregroundStyle(.secondary)
                                FieldValue(field: f, context: context, size: .small)
                            }
                            .multilineTextAlignment(.center)
                            .fixedSize()
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(state.title ?? state.workoutSport ?? context.attributes.title)
                        .font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: Self.symbol(island, context.state)).foregroundStyle(Self.tint(island, context.state))
            } compactTrailing: {
                FieldValue(field: island, context: context, size: .small)
            } minimal: {
                Image(systemName: Self.symbol(island, context.state)).foregroundStyle(Self.tint(island, context.state))
            }
        }
    }
}

/// One field's value. Timers use the system's self-updating timer text, so they count on the Lock Screen
/// between pushes.
private struct FieldValue: View {
    enum Size { case small, medium, large }

    let field: LiveBannerField
    let context: ActivityViewContext<NOOPActivityAttributes>
    let size: Size

    var body: some View {
        content
            .font(font)
            .foregroundStyle(StrandPalette.textPrimary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var font: Font {
        switch size {
        case .large: return .system(size: 26, weight: .bold, design: .rounded)
        case .medium: return .system(size: 20, weight: .bold, design: .rounded)
        case .small: return .headline
        }
    }

    @ViewBuilder
    private var content: some View {
        let s = context.state
        switch field {
        case .heartRate:
            if let live = NOOPLiveActivity.shownBpm(context) {
                Text(size == .large ? "\(live) bpm" : "\(live)")
            } else if let last = NOOPLiveActivity.lastBpm(context) {
                // Not live: the last number, dimmed, with the time it was read.
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(size == .large ? "\(last.bpm) bpm" : "\(last.bpm)")
                        .opacity(0.6)
                    if size != .small, last.at > .distantPast {
                        Text(last.at, style: .time)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text(size == .large ? "– bpm" : "–")
            }
        case .zone:
            Text(s.zone.map { "Z\($0)" } ?? "–")
        case .charge:
            Text(s.recovery.map { "\($0)%" } ?? "–")
        case .effort:
            Text(s.effort.map(String.init) ?? "–")
        case .rest:
            Text(s.rest.map(String.init) ?? "–")
        case .steps:
            Text(s.steps.map { $0.formatted(.number) } ?? "–")
        case .calories:
            Text(s.calories.map(String.init) ?? "–")
        case .hrv:
            Text(s.hrv.map(String.init) ?? "–")
        case .restingHr:
            Text(s.restingHr.map(String.init) ?? "–")
        case .workoutTime:
            if let start = s.workoutStart {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
            } else {
                Text("–")
            }
        case .restTimer:
            if let since = s.restSince {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
            } else if s.workoutStart != nil {
                Text("Working")
            } else {
                Text("–")
            }
        case .sets:
            Text(s.setCount.map(String.init) ?? "–")
        case .battery, .batteryTime, .sleepTime, .skinTemp, .respiration, .spo2, .workoutEffort, .avgHr,
             .peakHr, .distance, .pace:
            Text(s.texts?[field.rawValue] ?? "–")
        case .batteryFull:
            BatteryGauge(packed: s.texts?[field.rawValue], size: size)
        case .setReady:
            SetReadyLight(raw: s.texts?[field.rawValue], size: size)
        }
    }
}

/// The strap battery as a battery shape filled to its charge, with the time left under it.
/// `packed` is "percent|time left|charging" as the app sends it.
private struct BatteryGauge: View {
    let packed: String?
    let size: FieldValue.Size

    private var parts: (pct: Int?, left: String?, charging: Bool) {
        let p = (packed ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        return (p.first.flatMap(Int.init), p.count > 1 && !p[1].isEmpty ? p[1] : nil, p.count > 2 && p[2] == "1")
    }

    var body: some View {
        let v = parts
        let w: CGFloat = size == .small ? 26 : (size == .medium ? 34 : 42)
        let h: CGFloat = w * 0.48
        let frac = CGFloat(min(100, max(0, v.pct ?? 0))) / 100
        let fill: Color = (v.pct ?? 0) <= 15 ? .red : ((v.pct ?? 0) <= 35 ? .yellow : .green)
        VStack(spacing: 2) {
            HStack(spacing: 1.5) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: h * 0.28, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.45), lineWidth: 1.3)
                    RoundedRectangle(cornerRadius: h * 0.18, style: .continuous)
                        .fill(fill)
                        .frame(width: max(2, (w - 5) * frac))
                        .padding(2.5)
                    if v.charging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: h * 0.62, weight: .bold))
                            .foregroundStyle(Color.primary)
                            .frame(maxWidth: .infinity)
                    } else if size != .small, let pct = v.pct {
                        Text("\(pct)")
                            .font(.system(size: h * 0.6, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.primary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: w, height: h)
                RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.45))
                    .frame(width: 2, height: h * 0.38)
            }
            if size != .small {
                Text(v.left ?? (v.pct.map { "\($0)%" } ?? "–"))
                    .font(.system(size: size == .large ? 13 : 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Battery \(v.pct.map { "\($0) percent" } ?? "unknown")\(v.left.map { ", \($0) left" } ?? "")"))
    }
}

/// Lifting: a coloured light for starting the next set. `raw` is "green", "yellow" or "red".
private struct SetReadyLight: View {
    let raw: String?
    let size: FieldValue.Size

    var body: some View {
        let (color, word): (Color, String) = {
            switch raw {
            case "green": return (.green, "Go")
            case "yellow": return (.yellow, "Soon")
            case "red": return (.red, "Rest")
            case "working": return (.secondary, "Lifting")
            default: return (.secondary, "–")
            }
        }()
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: size == .small ? 9 : 12, height: size == .small ? 9 : 12)
                .shadow(color: color.opacity(0.7), radius: 3)
            Text(word)
        }
    }
}
