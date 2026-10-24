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
                                        Image(systemName: f.symbol).font(.caption).foregroundStyle(Self.tint(f, context.state))
                                        if labels {
                                            Text(f.label).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
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
                            Image(systemName: primary.symbol)
                                .font(.title2)
                                .foregroundStyle(Self.tint(primary, context.state))
                            VStack(alignment: .leading, spacing: 2) {
                                if labels {
                                    Text(state.title ?? state.workoutSport ?? primary.label)
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
                                        Text(f.label).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
                                    } else {
                                        Image(systemName: f.symbol).font(.caption2).foregroundStyle(Self.tint(f, context.state))
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
                        Image(systemName: island.symbol)
                        FieldValue(field: island, context: context, size: .small)
                    }
                    .foregroundStyle(Self.tint(island, context.state))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 10) {
                        ForEach(Array(others.prefix(2)), id: \.self) { f in
                            VStack(alignment: .center, spacing: 1) {
                                Text(f.label).font(.caption2).foregroundStyle(.secondary)
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
                Image(systemName: island.symbol).foregroundStyle(Self.tint(island, context.state))
            } compactTrailing: {
                FieldValue(field: island, context: context, size: .small)
            } minimal: {
                Image(systemName: island.symbol).foregroundStyle(Self.tint(island, context.state))
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
            if size == .large {
                Text("\(NOOPLiveActivity.shownBpm(context).map(String.init) ?? "–") bpm")
            } else {
                Text(NOOPLiveActivity.shownBpm(context).map(String.init) ?? "–")
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
        }
    }
}
