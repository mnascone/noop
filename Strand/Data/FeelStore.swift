import Foundation
import Combine
import StrandAnalytics

/// Your own daily check-ins ("I feel different from my score"), kept on this device. One per day, the
/// latest answer wins. Charge is never changed by them: they only steer the day's advice and the coach.
@MainActor
final class FeelStore: ObservableObject {
    static let shared = FeelStore()
    static let storeKey = "noop.feel.entries.v1"
    static let keepDays = 180

    @Published private(set) var entries: [FeelCheckIn.Entry] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let decoded = try? JSONDecoder().decode([FeelCheckIn.Entry].self, from: data) {
            entries = decoded
        }
    }

    var todayKey: String { Repository.localDayKey(Date()) }

    func entry(for day: String) -> FeelCheckIn.Entry? { entries.last { $0.day == day } }

    var today: FeelCheckIn.Entry? { entry(for: todayKey) }

    /// Record today's check-in. Changing the feeling clears reasons that no longer fit it.
    func set(_ feel: FeelCheckIn.Feel, reasons: [FeelCheckIn.Reason]? = nil) {
        let day = todayKey
        let ts = Int(Date().timeIntervalSince1970)
        var e = entry(for: day) ?? FeelCheckIn.Entry(day: day, feel: feel, ts: ts)
        if e.feel != feel { e.reasons = [] }
        e.feel = feel
        e.ts = ts
        if let reasons { e.reasons = reasons }
        let allowed: [FeelCheckIn.Reason] = feel == .off ? FeelCheckIn.Reason.offReasons
            : (feel == .better ? FeelCheckIn.Reason.betterReasons : [])
        e.reasons = e.reasons.filter { allowed.contains($0) }
        replace(e)
    }

    func toggle(_ reason: FeelCheckIn.Reason) {
        guard var e = today else { return }
        if let i = e.reasons.firstIndex(of: reason) { e.reasons.remove(at: i) } else { e.reasons.append(reason) }
        replace(e)
    }

    /// Undo today's check-in.
    func clearToday() {
        entries.removeAll { $0.day == todayKey }
        save()
    }

    /// Yesterday's check-in that differed from the score and hasn't had its follow-up, when yesterday had
    /// training. Asked once: answering or dismissing settles it.
    func pendingFollowUp(trainedDays: Set<String>) -> FeelCheckIn.Entry? {
        guard let y = FeelCheckIn.previousDay(todayKey), let e = entry(for: y),
              e.feel != .asScored, e.rightCall == nil, trainedDays.contains(y),
              !UserDefaults.standard.bool(forKey: "noop.feel.followUpDismissed.\(y)") else { return nil }
        return e
    }

    func answerFollowUp(day: String, rightCall: Bool?) {
        if let rightCall, var e = entry(for: day) {
            e.rightCall = rightCall
            replace(e)
        } else {
            UserDefaults.standard.set(true, forKey: "noop.feel.followUpDismissed.\(day)")
            objectWillChange.send()
        }
    }

    private func replace(_ e: FeelCheckIn.Entry) {
        entries.removeAll { $0.day == e.day }
        entries.append(e)
        entries.sort { $0.day < $1.day }
        if entries.count > Self.keepDays { entries.removeFirst(entries.count - Self.keepDays) }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
    }

    // MARK: - Words

    static func word(_ f: FeelCheckIn.Feel) -> String {
        switch f {
        case .asScored: return String(localized: "as scored")
        case .better: return String(localized: "better")
        case .off: return String(localized: "off")
        }
    }

    static func word(_ r: FeelCheckIn.Reason) -> String {
        switch r {
        case .sore: return String(localized: "Sore")
        case .lowEnergy: return String(localized: "Low energy")
        case .unwell: return String(localized: "Unwell")
        case .stressed: return String(localized: "Stressed")
        case .fresh: return String(localized: "Fresh")
        case .motivated: return String(localized: "Motivated")
        }
    }

    /// "off (sore, low energy)" for the coach and the advice line.
    static func describe(_ e: FeelCheckIn.Entry) -> String {
        let r = e.reasons.map { word($0).lowercased() }
        return word(e.feel) + (r.isEmpty ? "" : " (" + r.joined(separator: ", ") + ")")
    }

    /// The cache key part of the day's advice, so a new check-in asks the coach again.
    var todayKeyPart: String {
        guard let t = today else { return "-" }
        return t.feel.rawValue + ":" + t.reasons.map(\.rawValue).joined(separator: ",")
    }

    static func patternLine(_ p: FeelCheckIn.Pattern) -> String {
        String(localized: "You've reported feeling \(word(p.reason).lowercased()) the day after \(p.sport) \(p.times) of \(p.outOf) times.")
    }

    /// The coach's view: the last 14 days of check-ins, labelled as self-reported, plus any patterns.
    func coachBlock(sportsByDay: [String: [String]]) -> String? {
        let recent = entries.suffix(14)
        guard !recent.isEmpty else { return nil }
        var lines = ["How I said I felt (my own report, NOT measured by the strap; Charge stays as measured):"]
        for e in recent {
            var l = "  \(e.day): \(Self.describe(e))"
            if let rc = e.rightCall { l += rc ? ", later said the day's training was the right call" : ", later said the day's training was not the right call" }
            lines.append(l)
        }
        for p in FeelCheckIn.patterns(entries, sportsByDay: sportsByDay).prefix(3) {
            lines.append("  Pattern: " + Self.patternLine(p))
        }
        return lines.joined(separator: "\n")
    }
}
