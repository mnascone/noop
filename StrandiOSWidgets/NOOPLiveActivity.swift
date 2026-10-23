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

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NOOPActivityAttributes.self) { context in
            // Lock Screen / banner presentation: the first field large, the rest as small stats.
            let fields = Self.fields(context.state)
            HStack(spacing: 14) {
                if let primary = fields.first {
                    Image(systemName: primary.symbol)
                        .font(.title2)
                        .foregroundStyle(primary == .heartRate ? StrandPalette.statusCritical : StrandPalette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.workoutStart != nil
                             ? (context.state.workoutSport ?? primary.label) : primary.label)
                            .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                        FieldValue(field: primary, context: context, large: true)
                    }
                }
                Spacer()
                HStack(spacing: 12) {
                    ForEach(Array(fields.dropFirst()), id: \.self) { f in
                        VStack(alignment: .center, spacing: 2) {
                            Text(f.label).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
                            FieldValue(field: f, context: context, large: false)
                        }
                        .multilineTextAlignment(.center)
                        .fixedSize()
                    }
                }
            }
            .padding()
            .activityBackgroundTint(StrandPalette.surfaceBase)
            .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            let fields = Self.fields(context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if let primary = fields.first {
                        HStack(spacing: 4) {
                            Image(systemName: primary.symbol)
                            FieldValue(field: primary, context: context, large: false)
                        }
                        .foregroundStyle(primary == .heartRate ? StrandPalette.statusCritical : StrandPalette.accent)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 10) {
                        ForEach(Array(fields.dropFirst().prefix(2)), id: \.self) { f in
                            VStack(alignment: .center, spacing: 1) {
                                Text(f.label).font(.caption2).foregroundStyle(.secondary)
                                FieldValue(field: f, context: context, large: false)
                            }
                            .multilineTextAlignment(.center)
                            .fixedSize()
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.workoutSport ?? context.attributes.title)
                        .font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: fields.first?.symbol ?? "heart.fill")
                    .foregroundStyle(fields.first == .heartRate ? StrandPalette.statusCritical : StrandPalette.accent)
            } compactTrailing: {
                FieldValue(field: fields.first ?? .heartRate, context: context, large: false)
            } minimal: {
                Image(systemName: fields.first?.symbol ?? "heart.fill")
                    .foregroundStyle(fields.first == .heartRate ? StrandPalette.statusCritical : StrandPalette.accent)
            }
        }
    }
}

/// One field's value. Timers use the system's self-updating timer text, so they count on the Lock Screen
/// between pushes.
private struct FieldValue: View {
    let field: LiveBannerField
    let context: ActivityViewContext<NOOPActivityAttributes>
    let large: Bool

    var body: some View {
        content
            .font(large ? .system(size: 26, weight: .bold, design: .rounded) : .headline)
            .foregroundStyle(StrandPalette.textPrimary)
            .monospacedDigit()
    }

    @ViewBuilder
    private var content: some View {
        let s = context.state
        switch field {
        case .heartRate:
            if large {
                Text("\(NOOPLiveActivity.shownBpm(context).map(String.init) ?? "–") bpm")
            } else {
                Text(NOOPLiveActivity.shownBpm(context).map(String.init) ?? "–")
            }
        case .charge:
            Text(s.recovery.map { "\($0)%" } ?? "–")
        case .effort:
            Text(s.effort.map(String.init) ?? "–")
        case .rest:
            Text(s.rest.map(String.init) ?? "–")
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
        }
    }
}
