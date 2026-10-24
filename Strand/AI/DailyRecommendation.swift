import Foundation
import Combine
import SwiftUI
import StrandAnalytics

/// Today's recommendation for the Today card: the AI coach's call when it's set up, the rule-based one
/// otherwise. One request per day and set of inputs, cached across launches, so opening Today doesn't
/// spend a call every time.
@MainActor
final class DailyRecommendation: ObservableObject {
    static let shared = DailyRecommendation()

    struct Inputs: Equatable {
        var day: String
        /// Charge rounded to the nearest 5, so small rescoring wobbles don't re-ask.
        var chargeBucket: Int?
        var restDays: Int
        var trainingStreak: Int
        var trainedToday: Bool
        /// Today's check-in ("off:sore"), "-" when none. Part of the key, so a check-in asks again.
        var feel: String = "-"

        var cacheKey: String {
            "\(day)|\(chargeBucket.map(String.init) ?? "-")|\(restDays)|\(trainingStreak)|\(trainedToday)|\(feel)"
        }
    }

    /// The AI text for the current inputs, nil while loading or when the coach isn't available.
    @Published private(set) var aiText: String?
    @Published private(set) var loading = false
    /// Whether the coach can answer at all (on, set up, data sharing allowed).
    @Published private(set) var available = false
    /// Bumped by `forceRefresh()`; the loader re-asks when it changes.
    @Published private(set) var refreshToken = 0

    private static let cacheKey = "noop.dailyRecommendation.cache"
    private var inFlightKey: String?
    /// The inputs most recently asked about. A reply for older inputs is dropped.
    private var requestedKey: String?

    private init() {}

    /// The coach writes Markdown. Render **bold** and *italics* inline, and drop heading marks and list
    /// bullets so the card reads as plain sentences.
    static func styled(_ text: String) -> AttributedString {
        let cleaned = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var l = line.trimmingCharacters(in: .whitespaces)
                while l.hasPrefix("#") { l.removeFirst() }
                if l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("• ") { l.removeFirst(2) }
                return l.trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: cleaned, options: options)) ?? AttributedString(cleaned)
    }

    /// Drop today's cached answer and ask the coach again (the refresh button on Today).
    func forceRefresh() {
        guard !loading else { return }
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        aiText = nil
        refreshToken += 1
    }

    /// Ask the coach once for these inputs. A cached answer for the same inputs is reused.
    func refresh(_ inputs: Inputs, charge: Double?, ruleAdvice: String?, coach: AICoachEngine) async {
        let key = inputs.cacheKey
        requestedKey = key
        if available != coach.canRecommend { available = coach.canRecommend }
        if let cached = UserDefaults.standard.dictionary(forKey: Self.cacheKey),
           cached["key"] as? String == key, let text = cached["text"] as? String {
            aiText = text
            return
        }
        if aiText != nil { aiText = nil }
        guard coach.canRecommend, inFlightKey != key else { return }
        inFlightKey = key
        loading = true
        defer { loading = false; inFlightKey = nil }

        var extra = ["TODAY FOR THE RECOMMENDATION:"]
        extra.append("  Charge today: \(charge.map { "\(Int($0.rounded()))%" } ?? "not scored yet")")
        extra.append("  Rest days in the last 7 finished days: \(inputs.restDays)")
        extra.append("  Days in a row with training: \(inputs.trainingStreak)")
        extra.append("  Already trained today: \(inputs.trainedToday ? "yes" : "no")")
        if let ruleAdvice { extra.append("  Rule-based read: \(ruleAdvice)") }
        if let t = FeelStore.shared.today, t.feel != .asScored {
            extra.append("  How I say I feel today (my own report, not measured): \(FeelStore.describe(t))")
            if let hint = FeelCheckIn.advice(charge: charge, feel: t.feel, reasons: t.reasons) {
                extra.append("  Feel-adjusted rule: \(hint)")
            }
        }

        guard let text = await coach.generateDailyRecommendation(extra: extra.joined(separator: "\n")) else { return }
        UserDefaults.standard.set(["key": key, "text": text], forKey: Self.cacheKey)
        if requestedKey == key { aiText = text }
    }
}

/// Kicks off the recommendation for the given inputs. Lives in its own tiny view so only it observes the
/// coach (whose chat streams would otherwise re-render the whole Today screen).
struct DailyRecommendationLoader: View {
    let inputs: DailyRecommendation.Inputs
    let charge: Double?
    let ruleAdvice: String?
    @EnvironmentObject private var coach: AICoachEngine
    @ObservedObject private var rec = DailyRecommendation.shared

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: "\(inputs.cacheKey)|\(coach.provider.rawValue)|\(coach.isConfigured)|\(coach.dataConsent)|\(rec.refreshToken)") {
                await DailyRecommendation.shared.refresh(inputs, charge: charge, ruleAdvice: ruleAdvice, coach: coach)
            }
    }
}
