import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// "I feel different from my score": a one-tap check-in for Today, with an optional reason.
///
/// One compact row: How do you feel? As scored / Better / Off. Picking Better or Off shows the reasons
/// as small chips (optional). Once answered it folds to one line naming both readings side by side,
/// Charge as measured and how you feel, so neither is passed off as the other. The day after a check-in
/// that differed from the score, and with training logged, it asks once whether that was the right call.
struct FeelCheckInContent: View {
    let charge: Double?
    @ObservedObject private var store = FeelStore.shared
    @EnvironmentObject private var repo: Repository
    @State private var editing = false
    @State private var sportsByDay: [String: [String]] = [:]

    private var today: FeelCheckIn.Entry? { store.today }
    private var trainedDays: Set<String> {
        Set(repo.days.filter { ($0.exerciseCount ?? 0) > 0 }.map(\.day)).union(sportsByDay.keys)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pending = store.pendingFollowUp(trainedDays: trainedDays) {
                followUp(pending)
            } else if let t = today, !editing {
                answered(t)
            } else {
                prompt
                if let t = today, t.feel != .asScored { reasons(for: t) }
            }
            if let p = FeelCheckIn.patterns(store.entries, sportsByDay: sportsByDay).first {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "repeat").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    Text(FeelStore.patternLine(p))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.entries)
        .task(id: repo.refreshSeq) { await loadSports() }
    }

    /// The one-tap row. On a narrow screen the question sits above the three choices.
    private var prompt: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                question
                Spacer(minLength: 4)
                choices
            }
            VStack(alignment: .leading, spacing: 6) {
                question
                choices
            }
        }
    }

    private var question: some View {
        Text("How do you feel?")
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .fixedSize()
    }

    private var choices: some View {
        HStack(spacing: 6) {
            chip(String(localized: "As scored"), "checkmark", selected: today?.feel == .asScored) {
                store.set(.asScored); editing = false
            }
            chip(String(localized: "Better"), "arrow.up", selected: today?.feel == .better) {
                store.set(.better); editing = true
            }
            chip(String(localized: "Off"), "arrow.down", selected: today?.feel == .off) {
                store.set(.off); editing = true
            }
        }
        .fixedSize()
    }

    /// The optional second tap: why. Wraps "Done" to its own line when the chips need the width.
    private func reasons(for t: FeelCheckIn.Entry) -> some View {
        let options = t.feel == .off ? FeelCheckIn.Reason.offReasons : FeelCheckIn.Reason.betterReasons
        let chips = HStack(spacing: 6) {
            ForEach(options, id: \.self) { r in
                chip(FeelStore.word(r), nil, selected: t.reasons.contains(r), small: true) { store.toggle(r) }
            }
        }
        .fixedSize()
        let done = Button("Done") { editing = false }
            .font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(StrandPalette.accent)
            .buttonStyle(.plain)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                chips
                Spacer(minLength: 4)
                done
            }
            VStack(alignment: .leading, spacing: 6) {
                chips
                done
            }
        }
    }

    /// Folded: both readings, side by side, and a way to change it.
    private func answered(_ t: FeelCheckIn.Entry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: t.feel == .off ? "arrow.down.circle.fill"
                  : (t.feel == .better ? "arrow.up.circle.fill" : "checkmark.circle.fill"))
                .foregroundStyle(t.feel == .off ? StrandPalette.recovery030
                                 : (t.feel == .better ? StrandPalette.statusPositive : StrandPalette.textTertiary))
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "You feel \(FeelStore.describe(t))"))
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(charge.map { String(localized: "Charge \(Int($0.rounded()))% as measured. Today's advice uses both.") }
                     ?? String(localized: "Today's advice takes it into account."))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 4)
            Button("Change") { editing = true }
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.accent)
                .buttonStyle(.plain)
        }
    }

    /// Asked once, the day after.
    private func followUp(_ e: FeelCheckIn.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Yesterday you felt \(FeelStore.describe(e)). Was the training you did the right call?"))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                chip(String(localized: "Yes"), "hand.thumbsup", selected: false) {
                    store.answerFollowUp(day: e.day, rightCall: true)
                }
                chip(String(localized: "No"), "hand.thumbsdown", selected: false) {
                    store.answerFollowUp(day: e.day, rightCall: false)
                }
                Spacer()
                Button("Skip") { store.answerFollowUp(day: e.day, rightCall: nil) }
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .buttonStyle(.plain)
            }
        }
    }

    private func chip(_ title: String, _ icon: String?, selected: Bool, small: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
                Text(title).lineLimit(1)
            }
            .font((small ? StrandFont.caption : StrandFont.footnote).weight(.semibold))
            .foregroundStyle(selected ? Color.white : StrandPalette.textSecondary)
            .padding(.horizontal, small ? 8 : 10)
            .padding(.vertical, small ? 4 : 6)
            .background(Capsule().fill(selected ? StrandPalette.accent : StrandPalette.surfaceInset))
            .overlay(Capsule().strokeBorder(StrandPalette.hairline, lineWidth: selected ? 0 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Sports by day for the last 120 days, for the patterns.
    private func loadSports() async {
        let rows = await repo.workoutRows(days: 120)
        var out: [String: [String]] = [:]
        for w in rows {
            out[Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(w.startTs))), default: []].append(w.sport)
        }
        sportsByDay = out
    }
}
